import Foundation

public actor YmgalClient: WorkSourceClient {
    public nonisolated let source: WorkSource = .ymgal
    private let baseURL = URL(string: "https://www.ymgal.games")!
    private let api: APIClient
    private let credentials: @Sendable () -> (id: String, secret: String)
    private var accessToken: String?
    private var tokenExpiry = Date.distantPast

    public init(api: APIClient = .shared, credentials: (@Sendable () -> (id: String, secret: String))? = nil) {
        self.api = api
        self.credentials = credentials ?? {
            let keychain = KeychainStore()
            let id = keychain.string(for: "ymgal.clientID")?.nilIfBlank ?? "ymgal"
            let secret = keychain.string(for: "ymgal.clientSecret")?.nilIfBlank ?? "luna0327"
            return (id, secret)
        }
    }

    public func works(query: WorkQuery, page: Int, limit: Int, includeAdult: Bool) async throws -> WorkPage {
        let keyword: String
        switch query {
        case .search(let text), .tag(let text), .company(let text): keyword = text
        case .advanced(let search, _, _):
            guard let search, !search.isEmpty else { throw SourceFailure.unsupported }
            keyword = search
        default: throw SourceFailure.unsupported
        }
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WorkPage(items: [], page: page, hasMore: false)
        }
        let headers = try await authorizationHeaders()
        let response = try await api.data(
            baseURL.appendingPathComponent("open/archive/search-game"),
            query: [
                URLQueryItem(name: "mode", value: "list"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "pageNum", value: String(max(1, page))),
                URLQueryItem(name: "pageSize", value: String(min(20, max(1, limit))))
            ],
            headers: headers
        )
        let json = try JSONValue.objectValue(response.data)
        if json["success"]?.bool == false {
            throw SourceFailure.malformedResponse(json.firstString("message", "msg", "error") ?? "月幕搜索失败")
        }
        let data = json["data"] ?? json
        let items = data["result"]?.array ?? data["items"]?.array ?? []
        let total = data["total"]?.int
        return WorkPage(
            items: items.map(mapSummary),
            page: page,
            hasMore: total.map { page * limit < $0 } ?? (items.count == min(20, limit))
        )
    }

    public func detail(for work: WorkSummary) async throws -> WorkDetail {
        let response = try await api.data(
            baseURL.appendingPathComponent("open/archive"),
            query: [URLQueryItem(name: "gid", value: work.sourceID)],
            headers: try await authorizationHeaders()
        )
        let json = try JSONValue.objectValue(response.data)
        guard let game = json.dig("data", "game") else { throw SourceFailure.malformedResponse("月幕未返回作品详情") }
        let summary = mapSummary(game)
        var description = game.firstString("introduction", "intro")
        if description?.isEmpty != false {
            let intros = game["intros"]?.array ?? []
            description = intros.first { $0["lang"]?.string == "zh-Hans" }?["value"]?.string ?? intros.first?["value"]?.string
        }
        return WorkDetail(
            summary: summary,
            description: description,
            publishers: (game["publishers"]?.array ?? []).compactMap { $0.firstString("name", "displayName") ?? $0.string },
            links: [ExternalLink(title: "月幕 Galgame", url: URL(string: "https://www.ymgal.games/galgame/\(work.sourceID)")!)]
        )
    }

    private func authorizationHeaders() async throws -> [String: String] {
        if let accessToken, tokenExpiry > Date() { return ["Authorization": "Bearer \(accessToken)", "Accept": "application/json;charset=utf-8"] }
        let pair = credentials()
        let response = try await api.data(
            baseURL.appendingPathComponent("oauth/token"),
            query: [
                URLQueryItem(name: "grant_type", value: "client_credentials"),
                URLQueryItem(name: "client_id", value: pair.id),
                URLQueryItem(name: "client_secret", value: pair.secret),
                URLQueryItem(name: "scope", value: "public")
            ]
        )
        let json = try JSONValue.objectValue(response.data)
        guard let token = json["access_token"]?.string, !token.isEmpty else {
            throw SourceFailure.malformedResponse("月幕未返回 access_token")
        }
        let expires = max(60, json["expires_in"]?.int ?? 3600)
        self.accessToken = token
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expires - 60))
        return ["Authorization": "Bearer \(token)", "Accept": "application/json;charset=utf-8"]
    }

    private func mapSummary(_ item: JSONValue) -> WorkSummary {
        let id = item["id"]?.string ?? item["gid"]?.string ?? UUID().uuidString
        return WorkSummary(
            source: .ymgal,
            sourceID: id,
            title: item.firstString("chineseName", "name", "orgName") ?? "未命名",
            originalTitle: item.firstString("orgName", "name"),
            coverURL: item["mainImg"]?.url,
            releaseDate: item["releaseDate"]?.string,
            rating: item["score"]?.double,
            developerNames: (item["developers"]?.array ?? []).compactMap { $0.firstString("name", "displayName") ?? $0.string }
        )
    }
}
