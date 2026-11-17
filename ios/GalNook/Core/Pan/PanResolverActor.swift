import Foundation

public actor PanResolverActor {
    public let accountStore: PanAccountStore

    private let quarkUCClient: QuarkUCClient
    private let baiduClient: BaiduPanClient
    private let pan115Client: Pan115Client
    private let pan123Client: Pan123Client
    private let lanzouClient: LanzouClient

    public init(
        accountStore: PanAccountStore = PanAccountStore(),
        session: URLSession = .shared
    ) {
        self.init(
            accountStore: accountStore,
            session: session,
            now: { .now },
            random: { Int.random(in: 0...9_999_999) }
        )
    }

    init(
        accountStore: PanAccountStore,
        session: URLSession,
        now: @escaping @Sendable () -> Date,
        random: @escaping @Sendable () -> Int
    ) {
        self.accountStore = accountStore
        let http = PanHTTPClient(session: session)
        self.quarkUCClient = QuarkUCClient(http: http)
        self.baiduClient = BaiduPanClient(http: http)
        self.pan115Client = Pan115Client(http: http)
        self.pan123Client = Pan123Client(http: http, now: now, random: random)
        self.lanzouClient = LanzouClient(http: http)
    }

    public func resolve(_ resource: GameResource) async throws -> PanResolution {
        guard let shareURL = resource.shareURL else {
            throw PanError.invalidShare(site: resource.provider.rawValue, message: "资源没有分享链接")
        }
        return try await resolve(shareURL: shareURL, passcode: resource.sharePassword)
    }

    public func resolve(shareURL: URL, passcode: String? = nil) async throws -> PanResolution {
        guard let site = PanSite.detect(shareURL) else {
            throw PanError.unsupportedProvider(site: shareURL.host ?? "未知网盘")
        }
        if site == .xunlei || site == .caiyun || site == .guangya {
            throw PanError.unsupportedProvider(site: site.rawValue)
        }
        do {
            let link = try PanShareLink.parse(shareURL, fallbackPasscode: passcode)
            switch site {
            case .quark:
                return try await quarkUCClient.resolve(
                    link,
                    configuration: .quark,
                    initialCookie: accountStore.cookie(for: PanAccountStore.quark)
                )
            case .uc:
                return try await quarkUCClient.resolve(
                    link,
                    configuration: .uc,
                    initialCookie: accountStore.cookie(for: PanAccountStore.uc)
                )
            case .baidu:
                return try await baiduClient.resolve(
                    link,
                    accountCookie: accountStore.cookie(for: PanAccountStore.baidu)
                )
            case .pan115:
                return try await pan115Client.resolve(
                    link,
                    cookie: accountStore.cookie(for: PanAccountStore.pan115)
                )
            case .pan123:
                return try await pan123Client.resolve(
                    link,
                    token: accountStore.pan123AuthorToken
                )
            case .lanzou, .ilanzou:
                return try await lanzouClient.resolve(link, shareURL: shareURL)
            case .xunlei, .caiyun, .guangya:
                throw PanError.unsupportedProvider(site: site.rawValue)
            }
        } catch {
            throw panRemoteError(error, site: site)
        }
    }
}
