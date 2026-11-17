import Foundation
import XCTest
@testable import GalNook

final class ProfileTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalNookProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    @MainActor
    func testDisplayNameIsTrimmedLimitedAndPersisted() async throws {
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.displayName, "本地用户")

        let longName = String(repeating: "界", count: 30)
        try await store.updateDisplayName("  \(longName)\n")
        XCTAssertEqual(store.displayName, String(longName.prefix(24)))

        let restored = makeStore()
        await restored.load()
        XCTAssertEqual(restored.displayName, String(longName.prefix(24)))

        try await restored.updateDisplayName(" \n ")
        XCTAssertEqual(restored.displayName, "本地用户")
        try await restored.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL().path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryRoot.appendingPathComponent(".profile.json.tmp").path
        ))
    }

    @MainActor
    func testRecordEditingFilteringFavoriteAndDeletion() async throws {
        let store = makeStore()
        let first = makeWork(1)
        let second = makeWork(2)

        try await store.saveRecord(WorkRecord(
            work: first,
            state: .playing,
            score: 7,
            favorite: true
        ))
        XCTAssertEqual(store.record(for: first)?.state, .playing)
        XCTAssertEqual(store.record(for: first)?.score, 7)
        XCTAssertTrue(store.record(for: first)?.favorite == true)

        try await store.updateRecord(for: first, state: .played, score: nil, favorite: false)
        try await store.updateRecord(for: second, state: .abandoned, score: 0, favorite: false)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.record(for: first)?.state, .played)
        XCTAssertNil(store.record(for: first)?.score)
        XCTAssertEqual(store.records(state: .played).map(\.id), [first.id])
        XCTAssertEqual(store.records(state: .abandoned).map(\.id), [second.id])
        XCTAssertTrue(store.records(state: .unmarked).isEmpty)
        XCTAssertEqual(store.playedCount, 1)

        try await store.setFavorite(true, for: first)
        XCTAssertEqual(store.favoriteRecordCount, 1)
        XCTAssertEqual(store.record(for: first)?.state, .played)

        do {
            try await store.saveRecord(WorkRecord(work: first, score: 11))
            XCTFail("评分超过 10 时应拒绝保存")
        } catch {
            XCTAssertEqual(error as? ProfileStoreError, .invalidScore)
        }
        XCTAssertEqual(store.records.count, 2, "无效编辑不能污染内存记录")

        try await store.deleteRecord(for: second)
        XCTAssertNil(store.record(for: second))
        XCTAssertEqual(store.records.count, 1)
    }

    @MainActor
    func testReviewCreateEditOrderingAndDelete() async throws {
        let store = makeStore()
        let work = makeWork(1)
        let otherWork = makeWork(2)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)
        let oldReview = WorkReview(
            work: work,
            score: 8,
            content: "旧评论",
            spoiler: true,
            createdAt: oldDate
        )
        let newReview = WorkReview(
            work: work,
            score: nil,
            content: "新评论",
            createdAt: newDate
        )
        try await store.saveReview(oldReview)
        try await store.saveReview(newReview)
        try await store.saveReview(WorkReview(work: otherWork, content: "另一部作品"))

        XCTAssertEqual(store.reviewCount, 3)
        XCTAssertEqual(store.reviews(for: work).map(\.id), [newReview.id, oldReview.id])
        XCTAssertEqual(store.reviews(forWorkID: otherWork.id).count, 1)

        let edited = WorkReview(
            id: oldReview.id,
            work: work,
            score: 10,
            content: "  修改后的完整评论  ",
            spoiler: false,
            createdAt: oldDate
        )
        try await store.saveReview(edited)
        XCTAssertEqual(store.reviewCount, 3)
        XCTAssertEqual(store.reviews(for: work).last?.content, "  修改后的完整评论  ")
        XCTAssertEqual(store.reviews(for: work).last?.score, 10)
        XCTAssertEqual(store.reviews(for: work).last?.createdAt, oldDate)

        do {
            try await store.saveReview(WorkReview(work: work, content: " \n "))
            XCTFail("空评论应拒绝保存")
        } catch {
            XCTAssertEqual(error as? ProfileStoreError, .emptyReview)
        }
        XCTAssertEqual(store.reviewCount, 3)

        try await store.deleteReview(newReview)
        XCTAssertNil(store.reviews.first { $0.id == newReview.id })
        XCTAssertEqual(store.reviewCount, 2)
    }

    @MainActor
    func testRecordsAreLimitedToNewestTwoHundredOnImport() async throws {
        let store = makeStore()
        let records = (0..<205).map { index in
            WorkRecord(
                work: makeWork(index),
                state: index.isMultiple(of: 2) ? .played : .playing,
                score: index % 11,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let backup = ProfileBackup(records: records)

        try await store.importBackup(data: try encode(backup))

        XCTAssertEqual(store.records.count, 200)
        XCTAssertEqual(store.records.first?.work.id, makeWork(204).id)
        XCTAssertEqual(store.records.last?.work.id, makeWork(5).id)
        XCTAssertNil(store.record(for: makeWork(0)))
        XCTAssertEqual(store.playedCount, 100)
    }

    @MainActor
    func testAvatarAndAllEditorsSurviveStoreReload() async throws {
        let store = makeStore()
        let work = makeWork(9)
        let avatar = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        try await store.updateDisplayName("保存测试")
        try await store.updateAvatar(data: avatar)
        try await store.saveRecord(WorkRecord(
            work: work,
            state: .played,
            score: 9,
            favorite: true
        ))
        try await store.saveReview(WorkReview(
            work: work,
            score: 9,
            content: "重载后仍应存在",
            spoiler: true
        ))
        let oldAvatarURL = try XCTUnwrap(store.avatarURL)
        XCTAssertTrue(oldAvatarURL.path.contains("ProfileAvatar"))
        XCTAssertEqual(try Data(contentsOf: oldAvatarURL), avatar)

        let restored = makeStore()
        await restored.load()
        XCTAssertEqual(restored.displayName, "保存测试")
        XCTAssertEqual(restored.avatarData(), avatar)
        XCTAssertEqual(restored.record(for: work)?.state, .played)
        XCTAssertEqual(restored.record(for: work)?.score, 9)
        XCTAssertEqual(restored.record(for: work)?.favorite, true)
        XCTAssertEqual(restored.reviews(for: work).single?.content, "重载后仍应存在")
        XCTAssertEqual(restored.reviews(for: work).single?.spoiler, true)

        try await restored.removeAvatar()
        XCTAssertNil(restored.avatarFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAvatarURL.path))
        let withoutAvatar = makeStore()
        await withoutAvatar.load()
        XCTAssertNil(withoutAvatar.avatarData())
    }

    @MainActor
    func testSelfContainedJSONBackupRoundTripThroughFile() async throws {
        let source = makeStore(name: "source")
        let target = makeStore(name: "target")
        let work = makeWork(3)
        let avatar = Data("complete-image-data".utf8)
        let review = WorkReview(
            work: work,
            score: 6,
            content: "备份评论",
            spoiler: true,
            createdAt: Date(timeIntervalSince1970: 3_000)
        )
        try await source.updateDisplayName("备份用户")
        try await source.updateAvatar(data: avatar)
        try await source.saveRecord(WorkRecord(
            work: work,
            state: .abandoned,
            score: 5,
            favorite: true,
            updatedAt: Date(timeIntervalSince1970: 4_000)
        ))
        try await source.saveReview(review)

        let data = try source.exportBackup()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["exportedAt"])
        let avatarObject = try XCTUnwrap(object["avatar"] as? [String: Any])
        XCTAssertEqual(avatarObject["data"] as? String, avatar.base64EncodedString())
        XCTAssertEqual((object["records"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["reviews"] as? [[String: Any]])?.count, 1)

        let sourceAvatarURL = try XCTUnwrap(source.avatarURL)
        try FileManager.default.removeItem(at: sourceAvatarURL)
        let backupURL = temporaryRoot.appendingPathComponent("backup.json")
        try data.write(to: backupURL)
        try await target.importBackup(from: backupURL)

        XCTAssertEqual(target.displayName, "备份用户")
        XCTAssertEqual(target.avatarData(), avatar)
        XCTAssertEqual(target.record(for: work)?.state, .abandoned)
        XCTAssertEqual(target.record(for: work)?.favorite, true)
        XCTAssertEqual(target.reviews(for: work).map(\.id), [review.id])
        XCTAssertEqual(target.reviews(for: work).single?.content, "备份评论")
        XCTAssertNotEqual(target.avatarURL?.lastPathComponent, sourceAvatarURL.lastPathComponent)

        let reloaded = makeStore(name: "target")
        await reloaded.load()
        XCTAssertEqual(reloaded.avatarData(), avatar)
        XCTAssertEqual(reloaded.reviewCount, 1)
    }

    @MainActor
    func testFirstMutationLoadsExistingDiskDataBeforeSaving() async throws {
        let existingWork = makeWork(1)
        let newWork = makeWork(2)
        let initial = makeStore()
        try await initial.updateDisplayName("已有用户")
        try await initial.saveRecord(WorkRecord(work: existingWork, state: .played, score: 8))
        try await initial.saveReview(WorkReview(work: existingWork, content: "已有评论"))

        // Simulates opening RecordEditorView from a detail page before ProfileView loads.
        let detailPageStore = makeStore()
        XCTAssertFalse(detailPageStore.isLoaded)
        try await detailPageStore.saveRecord(WorkRecord(work: newWork, state: .playing, score: 4))

        XCTAssertTrue(detailPageStore.isLoaded)
        XCTAssertEqual(detailPageStore.displayName, "已有用户")
        XCTAssertEqual(detailPageStore.records.count, 2)
        XCTAssertEqual(detailPageStore.reviewCount, 1)
        XCTAssertNotNil(detailPageStore.record(for: existingWork))
        XCTAssertNotNil(detailPageStore.record(for: newWork))

        let restored = makeStore()
        await restored.load()
        XCTAssertEqual(restored.displayName, "已有用户")
        XCTAssertEqual(restored.records.count, 2)
        XCTAssertEqual(restored.reviewCount, 1)
    }

    @MainActor
    func testInvalidBackupDoesNotReplaceCurrentData() async throws {
        let store = makeStore()
        try await store.updateDisplayName("保留我")
        let invalidRecord = WorkRecord(work: makeWork(1), score: -1)
        let invalidBackup = ProfileBackup(displayName: "不应导入", records: [invalidRecord])

        do {
            try await store.importBackup(data: try encode(invalidBackup))
            XCTFail("非法评分备份应被拒绝")
        } catch {
            XCTAssertEqual(error as? ProfileStoreError, .invalidScore)
        }
        XCTAssertEqual(store.displayName, "保留我")
        XCTAssertTrue(store.records.isEmpty)

        do {
            try await store.importBackup(data: Data("not-json".utf8))
            XCTFail("非 JSON 数据应被拒绝")
        } catch {
            guard let profileError = error as? ProfileStoreError else {
                XCTFail("错误类型应为 ProfileStoreError，实际为 \(error)")
                return
            }
            guard case .invalidBackup = profileError else {
                XCTFail("错误类型应为 invalidBackup，实际为 \(error)")
                return
            }
        }

        do {
            let future = ProfileBackup(schemaVersion: 99, displayName: "未来")
            try await store.importBackup(data: try encode(future))
            XCTFail("未知备份版本应被拒绝")
        } catch {
            XCTAssertEqual(error as? ProfileStoreError, .unsupportedBackupVersion(99))
        }
        XCTAssertEqual(store.displayName, "保留我")
    }

    @MainActor
    private func makeStore(name: String = "profile") -> ProfileStore {
        ProfileStore(
            fileURL: temporaryRoot.appendingPathComponent("\(name).json"),
            avatarDirectory: temporaryRoot
                .appendingPathComponent("\(name)-support", isDirectory: true)
                .appendingPathComponent("ProfileAvatar", isDirectory: true)
        )
    }

    private func profileURL() -> URL {
        temporaryRoot.appendingPathComponent("profile.json")
    }

    private func makeWork(_ index: Int) -> WorkSummary {
        WorkSummary(
            source: .local,
            sourceID: "work-\(index)",
            title: "作品 \(index)",
            originalTitle: "Original \(index)",
            coverURL: URL(string: "https://example.com/covers/\(index).jpg"),
            developerNames: ["测试社团"]
        )
    }

    private func encode(_ backup: ProfileBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
