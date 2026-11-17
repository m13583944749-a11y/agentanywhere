import Foundation

public struct PanFile: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var url: String
    /// Display size used by the original client (B/KB/MB/GB), not a byte count.
    public var size: String
    public var referer: String
    /// Preserved separately so DownloadManager does not have to parse `size`.
    public var sizeBytes: Int64?

    public var id: String { "\(name)\u{1F}\(url)" }

    public init(
        name: String,
        url: String,
        size: String = "",
        referer: String = "",
        sizeBytes: Int64? = nil
    ) {
        self.name = name
        self.url = url
        self.size = size
        self.referer = referer
        self.sizeBytes = sizeBytes
    }

    /// Headers intentionally contain no account Cookie, matching the final download helper.
    public var resolvedDownload: ResolvedDownload? {
        guard let downloadURL = URL(string: url),
              let scheme = downloadURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var headers = ["User-Agent": PanHTTP.desktopUserAgent]
        if !referer.isEmpty { headers["Referer"] = referer }
        return ResolvedDownload(
            url: downloadURL,
            fileName: name,
            fileSize: sizeBytes,
            headers: headers
        )
    }
}

public struct PanResolution: Codable, Hashable, Sendable {
    public var site: String
    public var note: String
    public var files: [PanFile]

    public init(site: String, note: String, files: [PanFile]) {
        self.site = site
        self.note = note
        self.files = files
    }
}

public enum PanError: LocalizedError, Equatable, Sendable {
    case needLogin(site: String, message: String)
    case needPasscode(site: String, message: String)
    case invalidShare(site: String, message: String)
    case empty(site: String)
    case rateLimited(site: String, message: String)
    case unsupportedProvider(site: String)
    case remote(site: String, message: String, statusCode: Int?)

    public var site: String {
        switch self {
        case .needLogin(let site, _), .needPasscode(let site, _),
             .invalidShare(let site, _), .rateLimited(let site, _),
             .remote(let site, _, _):
            site
        case .empty(let site), .unsupportedProvider(let site):
            site
        }
    }

    public var errorDescription: String? {
        switch self {
        case .needLogin(_, let message): return message
        case .needPasscode(_, let message): return message
        case .invalidShare(_, let message): return message
        case .empty(let site): return "\(site) 分享中没有可下载文件"
        case .rateLimited(_, let message): return message
        case .unsupportedProvider(let site): return "\(site) 尚未内置直链解析客户端"
        case .remote(_, let message, let statusCode):
            if let statusCode { return "\(message)（HTTP \(statusCode)）" }
            return message
        }
    }
}

public struct PanDownloadResolverAdapter: DownloadResolving {
    private let resolver: PanResolverActor

    public init(resolver: PanResolverActor = PanResolverActor()) {
        self.resolver = resolver
    }

    /// The full list remains available from PanResolverActor; DownloadManager's
    /// single-file protocol deliberately receives only the first resolved file.
    public func resolve(_ resource: GameResource) async throws -> ResolvedDownload {
        let resolution = try await resolver.resolve(resource)
        guard let file = resolution.files.first else {
            throw PanError.empty(site: resolution.site)
        }
        guard let download = file.resolvedDownload else {
            throw PanError.remote(
                site: resolution.site,
                message: "解析结果包含无效下载地址",
                statusCode: nil
            )
        }
        return download
    }
}
