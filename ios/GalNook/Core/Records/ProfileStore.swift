import Combine
import Foundation

public enum ProfileStoreError: LocalizedError, Equatable {
    case invalidScore
    case emptyReview
    case avatarUnavailable
    case invalidBackup(String)
    case unsupportedBackupVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidScore:
            "评分必须是 0 到 10 的整数，或不评分。"
        case .emptyReview:
            "评论内容不能为空。"
        case .avatarUnavailable:
            "无法读取头像，请重新选择图片。"
        case .invalidBackup(let reason):
            "备份无效：\(reason)"
        case .unsupportedBackupVersion(let version):
            "不支持版本为 \(version) 的备份。"
        }
    }
}

@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()
    public static let defaultDisplayName = "本地用户"
    public static let displayNameLimit = 24
    public static let recordLimit = 200
    public static let currentSchemaVersion = 1

    @Published public private(set) var displayName: String
    @Published public private(set) var records: [WorkRecord]
    @Published public private(set) var reviews: [WorkReview]
    @Published public private(set) var isLoaded = false
    /// Changes after every avatar write/removal so SwiftUI can reload the same view hierarchy.
    @Published public private(set) var avatarRevision = UUID()

    private let jsonStore: JSONStore<ProfileSnapshot>
    private let avatarDirectory: URL
    private var loadingTask: Task<ProfileSnapshot, Never>?
    public private(set) var avatarFileName: String?

    public init(
        fileURL: URL = AppFileLocations.applicationSupport.appendingPathComponent("profile.json"),
        avatarDirectory: URL? = nil
    ) {
        let initial = ProfileSnapshot()
        self.jsonStore = JSONStore(fileURL: fileURL, defaultValue: initial)
        self.avatarDirectory = avatarDirectory
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("ProfileAvatar", isDirectory: true)
        self.displayName = initial.displayName
        self.avatarFileName = initial.avatarFileName
        self.records = initial.records
        self.reviews = initial.reviews
    }

    public var avatarURL: URL? {
        guard let avatarFileName else { return nil }
        return avatarDirectory.appendingPathComponent(avatarFileName)
    }

    public var playedCount: Int {
        records.filter { $0.state == .played }.count
    }

    public var favoriteRecordCount: Int {
        records.filter { $0.favorite }.count
    }

    public var reviewCount: Int { reviews.count }

    public var snapshot: ProfileSnapshot {
        ProfileSnapshot(
            displayName: displayName,
            avatarFileName: avatarFileName,
            records: records,
            reviews: reviews
        )
    }

    public func load() async {
        let task: Task<ProfileSnapshot, Never>
        if let loadingTask {
            task = loadingTask
        } else {
            task = Task { [jsonStore] in await jsonStore.load() }
            loadingTask = task
        }
        let restored = await task.value
        apply(Self.sanitized(restored))
        isLoaded = true
        loadingTask = nil
        avatarRevision = UUID()
    }

    public func loadIfNeeded() async {
        guard !isLoaded else { return }
        await load()
    }

    public func save() async throws {
        await loadIfNeeded()
        try await jsonStore.save(snapshot)
    }

    public func record(for work: WorkSummary) -> WorkRecord? {
        record(forWorkID: work.id)
    }

    public func record(forWorkID workID: String) -> WorkRecord? {
        records.first { $0.work.id == workID }
    }

    public func records(state: WorkRecordState?) -> [WorkRecord] {
        guard let state else { return records }
        return records.filter { $0.state == state }
    }

    public func reviews(for work: WorkSummary) -> [WorkReview] {
        reviews(forWorkID: work.id)
    }

    public func reviews(forWorkID workID: String) -> [WorkReview] {
        reviews
            .filter { $0.work.id == workID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func updateDisplayName(_ name: String) async throws {
        await loadIfNeeded()
        var next = snapshot
        next.displayName = Self.normalizedDisplayName(name)
        try await commit(next)
    }

    @discardableResult
    public func saveRecord(_ record: WorkRecord) async throws -> WorkRecord {
        await loadIfNeeded()
        try Self.validate(score: record.score)
        var next = snapshot
        next.records.removeAll { $0.work.id == record.work.id }
        next.records.insert(record, at: 0)
        next.records = Array(next.records.prefix(Self.recordLimit))
        try await commit(next)
        return record
    }

    public func updateRecord(
        for work: WorkSummary,
        state: WorkRecordState,
        score: Int? = nil,
        favorite: Bool = false
    ) async throws {
        let record = WorkRecord(
            work: work,
            state: state,
            score: score,
            favorite: favorite,
            updatedAt: Date()
        )
        try await saveRecord(record)
    }

    public func setFavorite(_ favorite: Bool, for work: WorkSummary) async throws {
        await loadIfNeeded()
        let current = record(for: work)
        try await saveRecord(WorkRecord(
            work: work,
            state: current?.state ?? .unmarked,
            score: current?.score,
            favorite: favorite,
            updatedAt: Date()
        ))
    }

    public func deleteRecord(for work: WorkSummary) async throws {
        try await deleteRecord(forWorkID: work.id)
    }

    public func deleteRecord(forWorkID workID: String) async throws {
        await loadIfNeeded()
        var next = snapshot
        next.records.removeAll { $0.work.id == workID }
        try await commit(next)
    }

    @discardableResult
    public func saveReview(_ review: WorkReview) async throws -> WorkReview {
        await loadIfNeeded()
        try Self.validate(score: review.score)
        guard !review.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileStoreError.emptyReview
        }
        var next = snapshot
        next.reviews.removeAll { $0.id == review.id }
        next.reviews.append(review)
        next.reviews.sort { $0.createdAt > $1.createdAt }
        try await commit(next)
        return review
    }

    public func deleteReview(_ review: WorkReview) async throws {
        try await deleteReview(id: review.id)
    }

    public func deleteReview(id: UUID) async throws {
        await loadIfNeeded()
        var next = snapshot
        next.reviews.removeAll { $0.id == id }
        try await commit(next)
    }

    public func updateAvatar(data: Data) async throws {
        await loadIfNeeded()
        guard !data.isEmpty else { throw ProfileStoreError.avatarUnavailable }
        let fileName = "avatar-\(UUID().uuidString)"
        let destination = avatarDirectory.appendingPathComponent(fileName)
        try writeAvatar(data, to: destination)

        var next = snapshot
        next.avatarFileName = fileName
        do {
            try await jsonStore.save(next)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        removeAvatarFile(named: avatarFileName)
        displayName = next.displayName
        records = next.records
        reviews = next.reviews
        avatarFileName = fileName
        avatarRevision = UUID()
    }

    public func removeAvatar() async throws {
        await loadIfNeeded()
        var next = snapshot
        next.avatarFileName = nil
        try await jsonStore.save(next)
        removeAvatarFile(named: avatarFileName)
        displayName = next.displayName
        records = next.records
        reviews = next.reviews
        avatarFileName = nil
        avatarRevision = UUID()
    }

    public func avatarData() -> Data? {
        guard let avatarURL else { return nil }
        return try? Data(contentsOf: avatarURL)
    }

    public func backup() throws -> ProfileBackup {
        let avatar: ProfileAvatarBackup?
        if let avatarFileName {
            guard let data = avatarData() else { throw ProfileStoreError.avatarUnavailable }
            avatar = ProfileAvatarBackup(fileName: avatarFileName, data: data)
        } else {
            avatar = nil
        }
        return ProfileBackup(
            displayName: displayName,
            avatar: avatar,
            records: records,
            reviews: reviews
        )
    }

    public func exportBackup() throws -> Data {
        let encoder = Self.makeEncoder()
        return try encoder.encode(try backup())
    }

    public func importBackup(from url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        try await importBackup(data: Data(contentsOf: url))
    }

    public func importBackup(data: Data) async throws {
        await loadIfNeeded()
        let backup: ProfileBackup
        do {
            backup = try Self.makeDecoder().decode(ProfileBackup.self, from: data)
        } catch {
            throw ProfileStoreError.invalidBackup(error.localizedDescription)
        }
        guard backup.schemaVersion == Self.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedBackupVersion(backup.schemaVersion)
        }
        try Self.validate(records: backup.records, reviews: backup.reviews)

        let oldAvatarFileName = avatarFileName
        var newAvatarFileName: String?
        if let avatar = backup.avatar {
            guard !avatar.data.isEmpty else { throw ProfileStoreError.avatarUnavailable }
            let fileName = "avatar-\(UUID().uuidString)"
            newAvatarFileName = fileName
            try writeAvatar(avatar.data, to: avatarDirectory.appendingPathComponent(fileName))
        }

        var next = ProfileSnapshot(
            displayName: backup.displayName,
            avatarFileName: newAvatarFileName,
            records: backup.records,
            reviews: backup.reviews
        )
        next = Self.sanitized(next)
        do {
            try await jsonStore.save(next)
        } catch {
            if let newAvatarFileName { removeAvatarFile(named: newAvatarFileName) }
            throw error
        }
        removeAvatarFile(named: oldAvatarFileName)
        apply(next)
        avatarRevision = UUID()
    }

    private func commit(_ next: ProfileSnapshot) async throws {
        let cleaned = Self.sanitized(next)
        try await jsonStore.save(cleaned)
        apply(cleaned)
    }

    private func apply(_ snapshot: ProfileSnapshot) {
        displayName = snapshot.displayName
        avatarFileName = snapshot.avatarFileName
        records = snapshot.records
        reviews = snapshot.reviews
    }

    private func writeAvatar(_ data: Data, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private func removeAvatarFile(named fileName: String?) {
        guard let fileName,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent else { return }
        try? FileManager.default.removeItem(at: avatarDirectory.appendingPathComponent(fileName))
    }

    private static func normalizedDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDisplayName }
        return String(trimmed.prefix(displayNameLimit))
    }

    private static func sanitized(_ snapshot: ProfileSnapshot) -> ProfileSnapshot {
        var seenWorkIDs = Set<String>()
        let uniqueRecords = snapshot.records
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seenWorkIDs.insert($0.work.id).inserted }
        var seenReviewIDs = Set<UUID>()
        let uniqueReviews = snapshot.reviews
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seenReviewIDs.insert($0.id).inserted }
        let safeAvatarName = snapshot.avatarFileName.flatMap { name -> String? in
            guard !name.isEmpty,
                  name == URL(fileURLWithPath: name).lastPathComponent,
                  name != ".", name != ".." else { return nil }
            return name
        }
        return ProfileSnapshot(
            displayName: normalizedDisplayName(snapshot.displayName),
            avatarFileName: safeAvatarName,
            records: Array(uniqueRecords.prefix(recordLimit)),
            reviews: uniqueReviews
        )
    }

    private static func validate(records: [WorkRecord], reviews: [WorkReview]) throws {
        for record in records { try validate(score: record.score) }
        for review in reviews {
            try validate(score: review.score)
            guard !review.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileStoreError.emptyReview
            }
        }
    }

    private static func validate(score: Int?) throws {
        if let score, !(0...10).contains(score) {
            throw ProfileStoreError.invalidScore
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
