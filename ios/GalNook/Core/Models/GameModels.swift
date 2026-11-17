import Foundation

public enum GameEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case kirikiri
    case onscripter
    case renpy
    case artemis
    case tyrano
    case unity
    case rpgMaker
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kirikiri: "KrKr"
        case .onscripter: "ONS"
        case .renpy: "Ren’Py"
        case .artemis: "Artemis"
        case .tyrano: "TyranoScript"
        case .unity: "Unity"
        case .rpgMaker: "RPG Maker"
        case .unknown: "未知引擎"
        }
    }

    public var supportedByKrKrCat: Bool {
        switch self {
        case .kirikiri, .onscripter, .renpy: true
        default: false
        }
    }
}

public enum GamePlatform: String, Codable, CaseIterable, Sendable {
    case windows
    case android
    case ios
    case crossPlatform
    case unknown
}

public enum PanProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case baidu
    case quark
    case uc
    case oneOneFive
    case pan123
    case xunlei
    case lanzou
    case guangyapan
    case direct
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .baidu: "百度网盘"
        case .quark: "夸克网盘"
        case .uc: "UC 网盘"
        case .oneOneFive: "115"
        case .pan123: "123 云盘"
        case .xunlei: "迅雷云盘"
        case .lanzou: "蓝奏云"
        case .guangyapan: "光年Pan"
        case .direct: "直链"
        case .other: "其他"
        }
    }

    public static func detect(url: URL) -> PanProvider {
        let host = (url.host ?? "").lowercased()
        if host.contains("pan.baidu.com") { return .baidu }
        if host.contains("pan.quark.cn") { return .quark }
        if host.contains("drive.uc.cn") { return .uc }
        if host.contains("115.com") { return .oneOneFive }
        if host.contains("123pan") || host.contains("123865") || host.contains("123684") || host.contains("123912") { return .pan123 }
        if host.contains("xunlei.com") { return .xunlei }
        if host.contains("lanzou") || host.contains("ilanzou") { return .lanzou }
        if host.contains("guangyapan.com") { return .guangyapan }
        if ["zip", "rar", "7z", "lz4", "xp3", "nsa"].contains(url.pathExtension.lowercased()) { return .direct }
        return .other
    }
}

public struct GameResource: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var workID: String?
    public var title: String
    public var sourceName: String
    public var pageURL: URL?
    public var shareURL: URL?
    public var directURL: URL?
    public var provider: PanProvider
    public var fileName: String?
    public var fileSize: Int64?
    public var sharePassword: String?
    public var extractionPassword: String?
    public var platform: GamePlatform
    public var engine: GameEngine
    public var note: String?
    public var downloadHeaders: [String: String]
    public var isAndroidPackage: Bool

    public init(
        id: String = UUID().uuidString,
        workID: String? = nil,
        title: String,
        sourceName: String,
        pageURL: URL? = nil,
        shareURL: URL? = nil,
        directURL: URL? = nil,
        provider: PanProvider? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        sharePassword: String? = nil,
        extractionPassword: String? = nil,
        platform: GamePlatform = .unknown,
        engine: GameEngine = .unknown,
        note: String? = nil,
        downloadHeaders: [String: String] = [:],
        isAndroidPackage: Bool = false
    ) {
        self.id = id
        self.workID = workID
        self.title = title
        self.sourceName = sourceName
        self.pageURL = pageURL
        self.shareURL = shareURL
        self.directURL = directURL
        self.provider = provider ?? shareURL.flatMap(PanProvider.detect) ?? directURL.flatMap(PanProvider.detect) ?? .other
        self.fileName = fileName
        self.fileSize = fileSize
        self.sharePassword = sharePassword
        self.extractionPassword = extractionPassword
        self.platform = platform
        self.engine = engine
        self.note = note
        self.downloadHeaders = downloadHeaders
        self.isAndroidPackage = isAndroidPackage || fileName?.lowercased().hasSuffix(".apk") == true || directURL?.pathExtension.lowercased() == "apk"
    }

    public var preferredURL: URL? { directURL ?? shareURL ?? pageURL }
}

public struct ResolvedDownload: Sendable {
    public var url: URL
    public var fileName: String
    public var fileSize: Int64?
    public var headers: [String: String]
    public var expiresAt: Date?

    public init(url: URL, fileName: String, fileSize: Int64? = nil, headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.headers = headers
        self.expiresAt = expiresAt
    }
}

public struct EngineDetectionResult: Sendable {
    public var engine: GameEngine
    public var rootRelativePath: String
    public var launchRelativePath: String?
    public var evidence: [String]

    public init(engine: GameEngine, rootRelativePath: String, launchRelativePath: String?, evidence: [String]) {
        self.engine = engine
        self.rootRelativePath = rootRelativePath
        self.launchRelativePath = launchRelativePath
        self.evidence = evidence
    }
}

public struct LocalGame: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var workID: String?
    public var engine: GameEngine
    public var rootPath: String
    public var launchPath: String?
    public var coverPath: String?
    public var sourceArchive: String?
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var playSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        title: String,
        workID: String? = nil,
        engine: GameEngine,
        rootPath: String,
        launchPath: String? = nil,
        coverPath: String? = nil,
        sourceArchive: String? = nil,
        addedAt: Date = .now,
        lastOpenedAt: Date? = nil,
        playSeconds: TimeInterval = 0
    ) {
        self.id = id
        self.title = title
        self.workID = workID
        self.engine = engine
        self.rootPath = rootPath
        self.launchPath = launchPath
        self.coverPath = coverPath
        self.sourceArchive = sourceArchive
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.playSeconds = playSeconds
    }
}
