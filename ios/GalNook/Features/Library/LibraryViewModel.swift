import Combine
import Foundation

public enum LibraryLayout: String, CaseIterable, Sendable {
    case grid
    case list
}

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var searchText = ""
    @Published public var selectedEngine: GameEngine?
    @Published public var layout: LibraryLayout = .grid
    @Published public private(set) var busyMessage: String?
    @Published public var errorMessage: String?
    @Published public var sharePackage: GameSharePackage?

    private let gamesDirectory: URL
    private let scanner: GameLibraryScanner
    private let store: GameLibraryStore

    public init(gamesDirectory: URL = AppFileLocations.games) {
        self.gamesDirectory = gamesDirectory.standardizedFileURL
        self.scanner = GameLibraryScanner()
        self.store = GameLibraryStore(gamesDirectory: gamesDirectory)
    }

    public var isBusy: Bool { busyMessage != nil }

    public func filteredGames(from games: [LocalGame]) -> [LocalGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return games.filter { game in
            if let selectedEngine, game.engine != selectedEngine { return false }
            guard !query.isEmpty else { return true }
            return game.title.localizedCaseInsensitiveContains(query)
                || game.engine.displayName.localizedCaseInsensitiveContains(query)
                || game.rootPath.localizedCaseInsensitiveContains(query)
        }
        .sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public func refresh(model: AppModel) async {
        guard !isBusy else { return }
        busyMessage = "正在扫描游戏库…"
        defer { busyMessage = nil }
        do {
            try await synchronize(model: model, importedContainers: [], removeMissing: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts security scope synchronously in the fileImporter callback, before any await.
    public func importURLs(_ urls: [URL], mode: LibraryImportMode, model: AppModel) {
        guard !urls.isEmpty, !isBusy else { return }
        let scopedURLs = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        busyMessage = mode == .folders ? "正在导入文件夹…" : "正在导入文件…"
        let gamesDirectory = self.gamesDirectory

        Task { [weak self] in
            defer {
                for (url, accessed) in scopedURLs where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
                self?.busyMessage = nil
            }
            do {
                let containers = try await Task.detached(priority: .userInitiated) {
                    try await GameLibraryImporter().importItems(
                        urls,
                        mode: mode,
                        gamesDirectory: gamesDirectory
                    )
                }.value
                guard let self else { return }
                try await self.synchronize(
                    model: model,
                    importedContainers: containers,
                    removeMissing: false
                )
            } catch {
                if !(error is CancellationError) {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    public func update(
        _ game: LocalGame,
        title: String,
        engine: GameEngine,
        launchPath: String?,
        model: AppModel
    ) -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorMessage = GameLibraryError.emptyGameName.localizedDescription
            return false
        }
        let cleanLaunch = launchPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = game
        updated.title = cleanTitle
        updated.engine = engine
        updated.launchPath = cleanLaunch?.isEmpty == true ? nil : cleanLaunch
        do {
            _ = try store.launchURL(for: updated)
            guard let index = model.games.firstIndex(where: { $0.id == game.id }) else { return false }
            model.games[index] = updated
            model.settingsChanged()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func delete(_ game: LocalGame, model: AppModel) {
        guard !isBusy else { return }
        busyMessage = "正在删除游戏…"
        let store = self.store
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.delete(game)
                }.value
                model.games.removeAll { $0.id == game.id }
                model.settingsChanged()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.busyMessage = nil
        }
    }

    public func share(_ game: LocalGame, format: GameShareFormat) {
        guard !isBusy else { return }
        if format == .folder {
            do {
                sharePackage = try GameSharingService(store: store).package(game: game, format: .folder)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        busyMessage = "正在生成完整 ZIP…"
        let store = self.store
        Task { [weak self] in
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try GameSharingService(store: store).package(game: game, format: .zip)
                }.value
                self?.sharePackage = package
            } catch {
                if !(error is CancellationError) {
                    self?.errorMessage = error.localizedDescription
                }
            }
            self?.busyMessage = nil
        }
    }

    public func dismissShare() {
        sharePackage?.cleanup()
        sharePackage = nil
    }

    public func detection(for game: LocalGame) async -> EngineDetectionResult? {
        do {
            let root = try store.gameURL(for: game)
            return try await Task.detached(priority: .utility) {
                try GameLibraryScanner().detect(at: root)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func launchCandidates(for game: LocalGame) async -> [String] {
        do {
            let root = try store.gameURL(for: game)
            return await Task.detached(priority: .utility) {
                GameLibraryScanner().launchCandidates(at: root)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    public func gameURL(for game: LocalGame) -> URL? {
        try? store.gameURL(for: game)
    }

    private func synchronize(
        model: AppModel,
        importedContainers: [ImportedGameContainer],
        removeMissing: Bool
    ) async throws {
        let root = gamesDirectory
        let scanner = self.scanner
        let results = try await Task.detached(priority: .userInitiated) {
            try scanner.scan(directory: root)
        }.value

        let archiveByContainer = Dictionary(
            uniqueKeysWithValues: importedContainers.compactMap { item -> (String, String)? in
                guard let relative = try? GameLibraryStore.relativePath(of: item.url, root: root),
                      let archive = item.sourceArchive else { return nil }
                return (relative, archive)
            }
        )

        let resultRoots = Set(results.map(\.rootRelativePath))
        var merged = removeMissing
            ? model.games.filter { resultRoots.contains($0.rootPath) }
            : model.games

        for result in results {
            if let index = merged.firstIndex(where: { $0.rootPath == result.rootRelativePath }) {
                // Never overwrite a user's manually edited title, engine or launch file.
                if merged[index].sourceArchive == nil,
                   let archive = archiveName(for: result.rootRelativePath, archives: archiveByContainer) {
                    merged[index].sourceArchive = archive
                }
                continue
            }

            let title = URL(fileURLWithPath: result.rootRelativePath).lastPathComponent.isEmpty
                ? root.lastPathComponent
                : URL(fileURLWithPath: result.rootRelativePath).lastPathComponent
            merged.append(LocalGame(
                title: title,
                engine: result.engine,
                rootPath: result.rootRelativePath,
                launchPath: result.launchRelativePath,
                sourceArchive: archiveName(for: result.rootRelativePath, archives: archiveByContainer)
            ))
        }

        if merged != model.games {
            model.games = merged
            model.settingsChanged()
        }
    }

    private func archiveName(for resultRoot: String, archives: [String: String]) -> String? {
        var bestMatch: (length: Int, name: String)?
        for (container, archive) in archives {
            let belongs = resultRoot == container || resultRoot.hasPrefix(container + "/")
            if belongs, container.count > (bestMatch?.length ?? -1) {
                bestMatch = (container.count, archive)
            }
        }
        return bestMatch?.name
    }
}
