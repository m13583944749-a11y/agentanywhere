import Foundation

public actor CnGalClient: WorkSourceClient {
    public nonisolated let source: WorkSource = .cnGal
    private let baseURL = URL(string: "https://api.cngal.org")!
    private let api: APIClient
    private var cachedIndex: [JSONValue]?
    private var cacheDate: Date?

    public init(api: APIClient = .shared) { self.api = api }

    public func works(query: WorkQuery, page: Int, limit: Int, includeAdult: Bool) async throws -> WorkPage {
        var items = try await index()
        switch query {
        case .search(let text), .tag(let text), .company(let text):
            let needle = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            items = items.filter { ($0["name"]?.string ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }
        case .random:
            items.shuffle()
        case .advanced(let search, _, _):
            if let search, !search.isEmpty {
                let needle = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                items = items.filter { ($0["name"]?.string ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }
            }
        default:
            break
        }
        let safePage = max(1, page)
        let safeLimit = min(100, max(1, limit))
        let start = (safePage - 1) * safeLimit
        let slice = start < items.count ? Array(items[start..<min(items.count, start + safeLimit)]) : []
        return WorkPage(items: slice.map(mapSummary), page: safePage, hasMore: start + safeLimit < items.count)
    }

    public func detail(for work: WorkSummary) async throws -> WorkDetail {
        let response = try await api.data(baseURL.appendingPathComponent("api/entries/GetEntryView/\(work.sourceID)"))
        let item = try JSONValue.objectValue(response.data)
        guard item["id"]?.string != nil else { throw SourceFailure.malformedResponse("CnGal 未返回作品详情") }
        var summary = mapSummary(item)
        summary.sourceID = work.sourceID
        let information = item["information"]?.array ?? []
        let releaseDate = information.first { ($0["name"]?.string ?? "").contains("发行") }?["value"]?.string
        if let releaseDate { summary.releaseDate = releaseDate }
        let characters = mapCharacters(item["roles"]?.array ?? [])
        var staff: [StaffMember] = []
        for group in item["staffs"]?.array ?? [] {
            let category = group["modifier"]?.string ?? "Staff"
            for person in group["staffList"]?.array ?? [] {
                let role = person["modifier"]?.string ?? category
                for name in person["names"]?.array ?? [] {
                    staff.append(StaffMember(name: name.firstString("displayName", "name") ?? "未知", role: role))
                }
            }
        }
        var links = [ExternalLink(title: "CnGal", url: URL(string: "https://www.cngal.org/entries/index/\(work.sourceID)")!)]
        if let steam = information.first(where: { ($0["name"]?.string ?? "").lowercased().contains("steam") })?["value"]?.url {
            links.append(ExternalLink(title: "Steam", url: steam))
        }
        return WorkDetail(
            summary: summary,
            aliases: [item["anotherName"]?.string].compactMap { $0?.nilIfBlank },
            description: item["mainPage"]?.string?.strippingHTML.nilIfBlank ?? item["briefIntroduction"]?.string,
            publishers: (item["publishers"]?.array ?? []).compactMap { $0.firstString("displayName", "name") },
            links: links,
            characters: characters,
            staff: staff,
            screenshots: (item["pictures"]?.array ?? []).compactMap {
                $0.firstString("url", "mainImage", "image").flatMap(URL.init) ?? $0["url"]?.url
            },
            relatedWorkIDs: (item["entryRelevances"]?.array ?? []).compactMap { $0["id"]?.string }
        )
    }

    public func characters(for work: WorkSummary) async throws -> [GameCharacter] {
        let response = try await api.data(baseURL.appendingPathComponent("api/entries/GetEntryView/\(work.sourceID)"))
        return mapCharacters((try JSONValue.objectValue(response.data))["roles"]?.array ?? [])
    }

    private func index() async throws -> [JSONValue] {
        if let cachedIndex, let cacheDate, Date().timeIntervalSince(cacheDate) < 21_600 { return cachedIndex }
        let response = try await api.data(baseURL.appendingPathComponent("api/entries/GetAllEntriesIdName"))
        let json = try JSONValue.objectValue(response.data)
        let items = json.array ?? json["items"]?.array ?? []
        cachedIndex = items
        cacheDate = .now
        return items
    }

    private func mapSummary(_ item: JSONValue) -> WorkSummary {
        let id = item["id"]?.string ?? UUID().uuidString
        return WorkSummary(
            source: .cnGal,
            sourceID: id,
            title: item.firstString("name", "displayName") ?? "未命名",
            originalTitle: item["anotherName"]?.string,
            coverURL: item.firstString("mainPicture", "mainImage", "thumbnail").flatMap(URL.init),
            releaseDate: item.firstString("publishTime", "releaseDate", "time"),
            developerNames: (item["productionGroups"]?.array ?? []).compactMap { $0.firstString("displayName", "name") },
            tags: (item["tags"]?.array ?? []).compactMap { $0.firstString("displayName", "name") }
        )
    }

    private func mapCharacters(_ items: [JSONValue]) -> [GameCharacter] {
        items.map { item in
            GameCharacter(
                id: item["id"]?.string ?? UUID().uuidString,
                name: item.firstString("name", "displayName") ?? "未知角色",
                role: item.firstString("roleIdentity", "type"),
                description: item["briefIntroduction"]?.string,
                imageURL: item.firstString("standingPainting", "mainImage").flatMap(URL.init),
                birthday: item["birthday"]?.string,
                height: item["height"]?.string,
                voiceActor: item["cv"]?.string
            )
        }
    }
}
