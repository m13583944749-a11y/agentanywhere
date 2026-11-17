import Foundation

public enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

public enum AccentColorPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue
    case purple
    case pink
    case green
    case orange

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .green: "绿色"
        case .orange: "橙色"
        }
    }
}

public struct AppSettings: Hashable, Codable, Sendable {
    public var enabledSources: Set<WorkSource>
    public var onlySearchGalResources: Bool
    public var showsAdultContent: Bool
    public var confirmedAdultContent: Bool
    public var appearance: AppearancePreference
    public var accentColor: AccentColorPreference
    public var preferredLanguage: String
    public var ymgalClientID: String
    public var ymgalClientSecretStored: Bool
    public var download: DownloadSettings
    public var acceptedDisclaimer: Bool
    public var automaticallyChecksUpdates: Bool
    public var loadsImages: Bool

    public init(
        enabledSources: Set<WorkSource> = [.nextMoe, .vndb, .ymgal, .cnGal],
        onlySearchGalResources: Bool = true,
        showsAdultContent: Bool = false,
        confirmedAdultContent: Bool = false,
        appearance: AppearancePreference = .system,
        accentColor: AccentColorPreference = .purple,
        preferredLanguage: String = "zh-Hans",
        ymgalClientID: String = "",
        ymgalClientSecretStored: Bool = false,
        download: DownloadSettings = DownloadSettings(),
        acceptedDisclaimer: Bool = false,
        automaticallyChecksUpdates: Bool = true,
        loadsImages: Bool = true
    ) {
        self.enabledSources = enabledSources
        self.onlySearchGalResources = onlySearchGalResources
        self.showsAdultContent = showsAdultContent
        self.confirmedAdultContent = confirmedAdultContent
        self.appearance = appearance
        self.accentColor = accentColor
        self.preferredLanguage = preferredLanguage
        self.ymgalClientID = ymgalClientID
        self.ymgalClientSecretStored = ymgalClientSecretStored
        self.download = download
        self.acceptedDisclaimer = acceptedDisclaimer
        self.automaticallyChecksUpdates = automaticallyChecksUpdates
        self.loadsImages = loadsImages
    }
}

public struct HistoryEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { work.id }
    public var work: WorkSummary
    public var visitedAt: Date

    public init(work: WorkSummary, visitedAt: Date = .now) {
        self.work = work
        self.visitedAt = visitedAt
    }
}

public struct PersistedAppState: Codable, Sendable {
    public var settings: AppSettings
    public var favoriteWorkIDs: Set<String>
    public var favoriteWorks: [WorkSummary]
    public var history: [HistoryEntry]
    public var games: [LocalGame]
    public var downloads: [DownloadTask]

    public init(
        settings: AppSettings = AppSettings(),
        favoriteWorkIDs: Set<String> = [],
        favoriteWorks: [WorkSummary] = [],
        history: [HistoryEntry] = [],
        games: [LocalGame] = [],
        downloads: [DownloadTask] = []
    ) {
        self.settings = settings
        self.favoriteWorkIDs = favoriteWorkIDs
        self.favoriteWorks = favoriteWorks
        self.history = history
        self.games = games
        self.downloads = downloads
    }
}
