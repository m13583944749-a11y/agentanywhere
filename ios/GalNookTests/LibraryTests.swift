import XCTest
@testable import GalNook

final class LibraryTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalNookLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testKirikiriFindsActualRootInsideSingleArchiveWrapper() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Wrapper/Actual Game/data.xp3", in: library, contents: "archive")
        try makeFile("Wrapper/Actual Game/Game.exe", in: library, contents: "launcher")
        try makeFile("__MACOSX/Wrapper/Actual Game/._data.xp3", in: library, contents: "junk")

        let results = try GameLibraryScanner().scan(directory: library)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].engine, .kirikiri)
        XCTAssertEqual(results[0].rootRelativePath, "Wrapper/Actual Game")
        XCTAssertEqual(results[0].launchRelativePath, "Game.exe")
        XCTAssertTrue(results[0].evidence.contains { $0.contains("data.xp3") })
        XCTAssertFalse(results[0].evidence.contains { $0.contains("__MACOSX") })
    }

    func testKirikiriAcceptsNamedXP3AsMobileLaunchCandidate() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Mobile/启动游戏.xp3", in: library)
        let result = try GameLibraryScanner().detect(at: library)
        XCTAssertEqual(result.engine, .kirikiri)
        XCTAssertEqual(result.rootRelativePath, "Mobile")
        XCTAssertEqual(result.launchRelativePath, "启动游戏.xp3")
    }

    func testOnscripterRecognizesEveryDocumentedMarker() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        for (folder, marker) in [("A", "nscript.dat"), ("B", "0.txt"), ("C", "arc.nsa")] {
            try makeFile("\(folder)/\(marker)", in: library)
        }

        let results = try GameLibraryScanner().scan(directory: library)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.engine == .onscripter })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: results.map { ($0.rootRelativePath, $0.launchRelativePath ?? "") }),
            ["A": "nscript.dat", "B": "0.txt", "C": "arc.nsa"]
        )
    }

    func testRenpyRequiresBothGameFilesAndRuntime() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Complete/game/script.rpyc", in: library)
        try makeFile("Complete/game/archive.rpa", in: library)
        try makeFile("Complete/renpy/common.rpyc", in: library)
        try makeFile("Incomplete/game/archive.rpa", in: library)

        let results = try GameLibraryScanner().scan(directory: library)
        let complete = try XCTUnwrap(results.first { $0.rootRelativePath == "Complete" })
        let incomplete = try XCTUnwrap(results.first { $0.rootRelativePath == "Incomplete" })
        XCTAssertEqual(complete.engine, .renpy)
        XCTAssertEqual(complete.launchRelativePath, "game/archive.rpa")
        XCTAssertEqual(incomplete.engine, .unknown)
    }

    func testOtherEnginesAndUnknownHaveStableEvidenceAndLaunchers() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Artemis/data.pfs", in: library)
        try makeFile("Artemis/Game.exe", in: library)

        try makeFile("Tyrano/index.html", in: library, contents: "<html></html>")
        try makeFile("Tyrano/data/scenario/first.ks", in: library)
        try makeFile("Tyrano/tyrano/tyrano.js", in: library)

        try makeFile("Unity/MyGame.exe", in: library)
        try makeFile("Unity/MyGame_Data/globalgamemanagers", in: library)

        try makeFile("RPG/Game.ini", in: library)
        try makeFile("RPG/Game.rgss3a", in: library)
        try makeFile("RPG/Game.exe", in: library)

        try makeFile("WebRPG/www/index.html", in: library)
        try makeFile("WebRPG/www/data/System.json", in: library, contents: "{}")
        try makeFile("WebRPG/www/js/rmmz_core.js", in: library)

        try makeFile("Unknown/readme.md", in: library, contents: "not enough evidence")

        let results = try GameLibraryScanner().scan(directory: library)
        let byRoot = Dictionary(uniqueKeysWithValues: results.map { ($0.rootRelativePath, $0) })
        XCTAssertEqual(byRoot["Artemis"]?.engine, .artemis)
        XCTAssertEqual(byRoot["Artemis"]?.launchRelativePath, "Game.exe")
        XCTAssertEqual(byRoot["Tyrano"]?.engine, .tyrano)
        XCTAssertEqual(byRoot["Tyrano"]?.launchRelativePath, "index.html")
        XCTAssertEqual(byRoot["Unity"]?.engine, .unity)
        XCTAssertEqual(byRoot["Unity"]?.launchRelativePath, "MyGame.exe")
        XCTAssertEqual(byRoot["RPG"]?.engine, .rpgMaker)
        XCTAssertEqual(byRoot["RPG"]?.launchRelativePath, "Game.exe")
        XCTAssertEqual(byRoot["WebRPG"]?.engine, .rpgMaker)
        XCTAssertEqual(byRoot["WebRPG"]?.launchRelativePath, "www/index.html")
        XCTAssertEqual(byRoot["Unknown"]?.engine, .unknown)
        XCTAssertEqual(byRoot.count, 6)
    }

    func testLaunchCandidatesAreExistingFilesAndPrioritizeLaunchers() throws {
        let root = temporaryRoot.appendingPathComponent("Game")
        try makeFile("z.exe", in: root)
        try makeFile("data.xp3", in: root)
        try makeFile("Game.exe", in: root)
        try makeFile("readme.md", in: root)

        let candidates = GameLibraryScanner().launchCandidates(at: root)
        XCTAssertEqual(candidates.first, "Game.exe")
        XCTAssertTrue(candidates.contains("data.xp3"))
        XCTAssertFalse(candidates.contains("readme.md"))
    }

    func testFileSelectionIsCopiedAsOneGameAndNameCollisionIsSafe() async throws {
        let source = temporaryRoot.appendingPathComponent("Selection")
        try makeFile("nscript.dat", in: source, contents: "script")
        try makeFile("arc.nsa", in: source, contents: "archive")
        let library = temporaryRoot.appendingPathComponent("Games")
        let files = [
            source.appendingPathComponent("nscript.dat"),
            source.appendingPathComponent("arc.nsa")
        ]

        let first = try await GameLibraryImporter().importItems(files, mode: .files, gamesDirectory: library)
        let second = try await GameLibraryImporter().importItems(files, mode: .files, gamesDirectory: library)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].url.lastPathComponent, "Selection")
        XCTAssertEqual(second[0].url.lastPathComponent, "Selection 2")
        XCTAssertEqual(
            try Data(contentsOf: first[0].url.appendingPathComponent("nscript.dat")),
            Data("script".utf8)
        )
        let results = try GameLibraryScanner().scan(directory: library)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.engine == .onscripter })
    }

    func testFolderImportOwnsItsCopy() async throws {
        let source = temporaryRoot.appendingPathComponent("Source")
        try makeFile("data.xp3", in: source, contents: "xp3")
        let library = temporaryRoot.appendingPathComponent("Games")

        let imported = try await GameLibraryImporter().importItems(
            [source], mode: .folders, gamesDirectory: library
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: imported[0].url.appendingPathComponent("data.xp3").path
        ))
        let result = try GameLibraryScanner().detect(at: imported[0].url)
        XCTAssertEqual(result.engine, .kirikiri)
        XCTAssertEqual(result.rootRelativePath, "")
    }

    func testStoreRejectsTraversalAndValidatesManualLaunchFile() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Game/Game.exe", in: library)
        try makeFile("Outside.txt", in: temporaryRoot)
        let store = GameLibraryStore(gamesDirectory: library)
        let valid = LocalGame(
            title: "Game",
            engine: .kirikiri,
            rootPath: "Game",
            launchPath: "Game.exe"
        )
        XCTAssertEqual(try store.launchURL(for: valid)?.lastPathComponent, "Game.exe")

        let traversal = LocalGame(
            title: "Bad",
            engine: .unknown,
            rootPath: "Game",
            launchPath: "../Outside.txt"
        )
        XCTAssertThrowsError(try store.launchURL(for: traversal))
        XCTAssertThrowsError(try store.delete(LocalGame(
            title: "Bad", engine: .unknown, rootPath: "../Outside"
        )))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temporaryRoot.appendingPathComponent("Outside.txt").path
        ))
    }

    func testZIPShareContainsCompleteTreeAndCleanupOnlyRemovesTemporaryArchive() throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Game/data.xp3", in: library, contents: "XP3")
        try makeFile("Game/目录/说明.txt", in: library, contents: "完整内容")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Game/empty"),
            withIntermediateDirectories: true
        )
        let game = LocalGame(title: "测试 Game", engine: .kirikiri, rootPath: "Game")
        let service = GameSharingService(store: GameLibraryStore(gamesDirectory: library))

        let folder = try service.package(game: game, format: .folder)
        XCTAssertFalse(folder.isTemporary)
        folder.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Game").path))

        let archive = try service.package(game: game, format: .zip)
        XCTAssertTrue(archive.isTemporary)
        let data = try Data(contentsOf: archive.url)
        let entries = try readStoredZIPEntries(data)
        XCTAssertEqual(entries["data.xp3"], Data("XP3".utf8))
        XCTAssertEqual(entries["目录/说明.txt"], Data("完整内容".utf8))
        XCTAssertNotNil(entries["empty/"])

        archive.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Game/data.xp3").path))
    }

    func testZIPImportExtractsAndScansNestedGame() async throws {
        let exportLibrary = temporaryRoot.appendingPathComponent("ExportGames")
        try makeFile("Source/Wrapper/Inner/data.xp3", in: exportLibrary, contents: "xp3")
        try makeFile("Source/Wrapper/Inner/Game.exe", in: exportLibrary, contents: "exe")
        let exported = try GameSharingService(
            store: GameLibraryStore(gamesDirectory: exportLibrary)
        ).package(
            game: LocalGame(title: "Packed", engine: .unknown, rootPath: "Source"),
            format: .zip
        )
        defer { exported.cleanup() }
        let importLibrary = temporaryRoot.appendingPathComponent("ImportedGames")

        let imported = try await GameLibraryImporter().importItems(
            [exported.url], mode: .files, gamesDirectory: importLibrary
        )

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].sourceArchive, "Packed.zip")
        let results = try GameLibraryScanner().scan(directory: importLibrary)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].engine, .kirikiri)
        XCTAssertEqual(results[0].rootRelativePath, "Packed/Wrapper/Inner")
        XCTAssertEqual(results[0].launchRelativePath, "Game.exe")
    }

    @MainActor
    func testViewModelPersistsManualChangesAndFiltersGames() async throws {
        let library = temporaryRoot.appendingPathComponent("Games")
        try makeFile("Game/data.xp3", in: library)
        let game = LocalGame(
            title: "Original",
            engine: .kirikiri,
            rootPath: "Game",
            launchPath: "data.xp3"
        )
        let stateURL = temporaryRoot.appendingPathComponent("state.json")
        let store = JSONStore(fileURL: stateURL, defaultValue: PersistedAppState())
        let model = AppModel(store: store)
        model.games = [game]
        let viewModel = LibraryViewModel(gamesDirectory: library)

        XCTAssertTrue(viewModel.update(
            game,
            title: "手动名称",
            engine: .unknown,
            launchPath: "data.xp3",
            model: model
        ))
        await model.saveImmediately()
        let restored = await store.load()
        XCTAssertEqual(restored.games.first?.title, "手动名称")
        XCTAssertEqual(restored.games.first?.engine, .unknown)

        viewModel.searchText = "手动"
        viewModel.selectedEngine = .unknown
        XCTAssertEqual(viewModel.filteredGames(from: model.games).map(\.id), [game.id])
        viewModel.selectedEngine = .renpy
        XCTAssertTrue(viewModel.filteredGames(from: model.games).isEmpty)
    }

    @discardableResult
    private func makeFile(
        _ relativePath: String,
        in root: URL,
        contents: String = ""
    ) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Parses the stored (compression method 0) entries produced by GameSharingService.
    private func readStoredZIPEntries(_ data: Data) throws -> [String: Data] {
        let eocdSignature = Data([0x50, 0x4B, 0x05, 0x06])
        let eocdRange = try XCTUnwrap(data.range(of: eocdSignature, options: .backwards))
        let eocd = eocdRange.lowerBound
        let count = Int(try littleEndianUInt16(data, offset: eocd + 10))
        var central = Int(try littleEndianUInt32(data, offset: eocd + 16))
        var result: [String: Data] = [:]

        for _ in 0..<count {
            XCTAssertEqual(try littleEndianUInt32(data, offset: central), 0x0201_4B50)
            let method = try littleEndianUInt16(data, offset: central + 10)
            XCTAssertEqual(method, 0)
            let expectedCRC = try littleEndianUInt32(data, offset: central + 16)
            let size = Int(try littleEndianUInt32(data, offset: central + 20))
            let nameLength = Int(try littleEndianUInt16(data, offset: central + 28))
            let extraLength = Int(try littleEndianUInt16(data, offset: central + 30))
            let commentLength = Int(try littleEndianUInt16(data, offset: central + 32))
            let local = Int(try littleEndianUInt32(data, offset: central + 42))
            let nameData = data.subdata(in: central + 46..<central + 46 + nameLength)
            let name = try XCTUnwrap(String(data: nameData, encoding: .utf8))

            XCTAssertEqual(try littleEndianUInt32(data, offset: local), 0x0403_4B50)
            XCTAssertEqual(try littleEndianUInt32(data, offset: local + 14), expectedCRC)
            let localNameLength = Int(try littleEndianUInt16(data, offset: local + 26))
            let localExtraLength = Int(try littleEndianUInt16(data, offset: local + 28))
            let start = local + 30 + localNameLength + localExtraLength
            result[name] = data.subdata(in: start..<start + size)
            central += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    private func littleEndianUInt16(_ data: Data, offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw NSError(domain: "LibraryTests", code: 1)
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw NSError(domain: "LibraryTests", code: 2)
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
