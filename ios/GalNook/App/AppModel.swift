import Foundation
import SwiftUI

@MainActor
public final class AppModel: ObservableObject {
    @Published public var settings: AppSettings
    @Published public var favoriteWorks: [WorkSummary]
    @Published public var history: [HistoryEntry]
    @Published public var games: [LocalGame]
    @Published public var downloads: [DownloadTask]
    @Published public var selectedTab: AppTab = .home
    @Published public var presentedError: String?

    private let store: JSONStore<PersistedAppState>
    private var saveTask: Task<Void, Never>?

    public init(store: JSONStore<PersistedAppState>? = nil) {
        let initial = PersistedAppState()
        self.store = store ?? JSONStore(fileURL: AppFileLocations.state, defaultValue: initial)
        self.settings = initial.settings
        self.favoriteWorks = initial.favoriteWorks
        self.history = initial.history
        self.games = initial.games
        self.downloads = initial.downloads
    }

    public func load() {
        Task { [store] in
            let restored = await store.load()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.settings = restored.settings
                self.favoriteWorks = restored.favoriteWorks
                self.history = restored.history
                self.games = restored.games
                self.downloads = restored.downloads
            }
        }
    }

    public func isFavorite(_ work: WorkSummary) -> Bool {
        favoriteWorks.contains { $0.id == work.id }
    }

    public func toggleFavorite(_ work: WorkSummary) {
        if let index = favoriteWorks.firstIndex(where: { $0.id == work.id }) {
            favoriteWorks.remove(at: index)
        } else {
            favoriteWorks.insert(work, at: 0)
        }
        scheduleSave()
    }

    public func recordVisit(_ work: WorkSummary) {
        history.removeAll { $0.id == work.id }
        history.insert(HistoryEntry(work: work), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        scheduleSave()
    }

    public func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    public func removeGames(at offsets: IndexSet) {
        let removed = offsets.compactMap { games[safe: $0] }
        games.remove(atOffsets: offsets)
        for game in removed {
            let url = AppFileLocations.games.appendingPathComponent(game.rootPath)
            try? FileManager.default.removeItem(at: url)
        }
        scheduleSave()
    }

    public func settingsChanged() {
        scheduleSave()
    }

    public func snapshot() -> PersistedAppState {
        PersistedAppState(
            settings: settings,
            favoriteWorkIDs: Set(favoriteWorks.map(\.id)),
            favoriteWorks: favoriteWorks,
            history: history,
            games: games,
            downloads: downloads
        )
    }

    public func saveImmediately() async {
        saveTask?.cancel()
        do {
            try await store.save(snapshot())
        } catch {
            presentedError = "保存失败：\(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let state = snapshot()
        saveTask = Task { [store] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? await store.save(state)
        }
    }
}

public enum AppTab: Hashable {
    case home
    case routes
    case downloads
    case library
    case profile
}
