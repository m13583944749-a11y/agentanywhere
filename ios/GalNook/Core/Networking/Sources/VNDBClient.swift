import Foundation

public struct VNDBClient: WorkSourceClient {
    public let source: WorkSource = .vndb
    private let baseURL = URL(string: "https://api.vndb.org/kana")!
    private let api: APIClient

    public init(api: APIClient = .shared) { self.api = api }

    public func works(query: WorkQuery, page: Int, limit: Int, includeAdult: Bool) async throws -> WorkPage {
        let endpoint = baseURL.appendingPathComponent("vn")
        var sort = "title"
        var reverse = false
        switch query {
        case .popular:
            sort = "votecount"
            reverse = true
        case .latest:
            sort = "released"
            reverse = true
        case .highlyRated:
            sort = "rating"
            reverse = true
        case .random:
            sort = "random"
        case .advanced(_, let requestedSort, _):
            switch requestedSort {
            case .vndbRating, .nextMoeRating, .erogameRating:
                sort = "rating"
                reverse = true
            case .releaseDate:
                sort = "released"
                reverse = true
            case .popularity:
                sort = "votecount"
                reverse = true
            }
        default:
            break
        }
        let body = requestBody(query: query, sort: sort, reverse: reverse, page: page, limit: limit)
        let response = try await api.data(
            endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let json = try JSONValue.objectValue(response.data)
        let items = json["results"]?.array ?? []
        return WorkPage(
            items: items.map(mapSummary),
            page: page,
            hasMore: json["more"]?.bool ?? (items.count == limit)
        )
    }

    public func detail(for work: WorkSummary) async throws -> WorkDetail {
        let body = try JSONSerialization.data(withJSONObject: [
            "filters": ["id", "=", work.sourceID],
            "fields": "id,title,alttitle,titles.lang,titles.title,titles.latin,released,rating,votecount,description,image.url,image.thumbnail,developers.name,developers.original,aliases,screenshots.url,tags.name,tags.category,staff.name,staff.original,staff.role,va.character.id,va.character.name,va.character.original,va.character.image.url,va.staff.name,va.staff.original",
            "results": 1
        ])
        let response = try await api.data(
            baseURL.appendingPathComponent("vn"),
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let json = try JSONValue.objectValue(response.data)
        guard let item = json["results"]?[0] else { throw SourceFailure.malformedResponse("VNDB 未返回作品详情") }
        var characters: [GameCharacter] = []
        for entry in item["va"]?.array ?? [] {
            guard let character = entry["character"], let id = character["id"]?.string else { continue }
            characters.append(GameCharacter(
                id: id,
                name: character.firstString("name", "original") ?? id,
                originalName: character["original"]?.string,
                imageURL: character.dig("image", "url")?.url,
                voiceActor: entry["staff"]?.firstString("name", "original")
            ))
        }
        let staff = (item["staff"]?.array ?? []).map {
            StaffMember(name: $0.firstString("name", "original") ?? "未知", role: $0["role"]?.string ?? "Staff")
        }
        var summary = mapSummary(item)
        summary.source = .vndb
        summary.sourceID = work.sourceID
        return WorkDetail(
            summary: summary,
            aliases: item["aliases"]?.array?.compactMap(\.string) ?? [],
            description: item["description"]?.string,
            links: [ExternalLink(title: "VNDB", url: URL(string: "https://vndb.org/\(work.sourceID)")!)],
            characters: characters,
            staff: staff,
            screenshots: item["screenshots"]?.array?.compactMap { $0["url"]?.url } ?? []
        )
    }

    public func characters(for work: WorkSummary) async throws -> [GameCharacter] {
        let body = try JSONSerialization.data(withJSONObject: [
            "filters": ["vn", "=", ["id", "=", work.sourceID]],
            "fields": "id,name,original,description,image.url,blood_type,birthday,height,bust,waist,hips,vns.role",
            "results": 100
        ])
        let response = try await api.data(
            baseURL.appendingPathComponent("character"),
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let json = try JSONValue.objectValue(response.data)
        var characters: [GameCharacter] = []
        for item in json["results"]?.array ?? [] {
            let measurementParts = [item["bust"]?.string, item["waist"]?.string, item["hips"]?.string]
                .compactMap { $0 }
            let measurements = measurementParts.joined(separator: "/")
            var birthday: String?
            if let values = item["birthday"]?.array, values.count == 2 {
                birthday = "\(values[0].string ?? "--")-\(values[1].string ?? "--")"
            }
            let height = item["height"]?.string.map { "\($0) cm" }
            let character = GameCharacter(
                id: item["id"]?.string ?? UUID().uuidString,
                name: item.firstString("name", "original") ?? "未知角色",
                originalName: item["original"]?.string,
                role: item["vns"]?[0]?["role"]?.string,
                description: item["description"]?.string,
                imageURL: item.dig("image", "url")?.url,
                birthday: birthday,
                bloodType: item["blood_type"]?.string,
                height: height,
                measurements: measurements.nilIfBlank
            )
            characters.append(character)
        }
        return characters
    }

    private func requestBody(query: WorkQuery, sort: String, reverse: Bool, page: Int, limit: Int) -> Data {
        let filters: Any
        switch query {
        case .popular: filters = NSNull()
        case .latest: filters = NSNull()
        case .highlyRated: filters = ["votecount", ">", 50]
        case .random: filters = NSNull()
        case .search(let text): filters = ["search", "=", text]
        case .tag(let tag): filters = ["tag", "=", tag]
        case .company(let company): filters = ["developer", "=", company]
        case .advanced(let search, _, let filter):
            var conditions: [Any] = []
            if let search, !search.isEmpty { conditions.append(["search", "=", search]) }
            if let language = filter.language { conditions.append(["olang", "=", language]) }
            if let platform = filter.platform { conditions.append(["platform", "=", platform]) }
            if let year = filter.year { conditions.append(["released", ">=", "\(year)-01-01"]); conditions.append(["released", "<=", "\(year)-12-31"]) }
            if let score = filter.minimumScore { conditions.append(["rating", ">=", score * 10]) }
            if let tag = filter.tagID { conditions.append(["tag", "=", tag]) }
            if conditions.isEmpty { filters = NSNull() }
            else if conditions.count == 1 { filters = conditions[0] }
            else {
                var combined: [Any] = ["and"]
                combined.append(contentsOf: conditions)
                filters = combined
            }
        }
        let object: [String: Any] = [
            "filters": filters,
            "fields": "id,title,alttitle,titles.lang,titles.title,titles.latin,image.url,image.thumbnail,released,rating,votecount,developers.name,tags.name",
            "results": min(100, max(1, limit)),
            "page": page,
            "sort": sort,
            "reverse": reverse
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func mapSummary(_ item: JSONValue) -> WorkSummary {
        let id = item["id"]?.string ?? UUID().uuidString
        let titles = item["titles"]?.array ?? []
        let chinese = titles.first { $0["lang"]?.string?.hasPrefix("zh") == true }
        let title = chinese?.firstString("title", "latin") ?? item.firstString("title", "alttitle") ?? id
        return WorkSummary(
            source: .vndb,
            sourceID: id,
            title: title,
            originalTitle: item.firstString("alttitle", "title"),
            coverURL: item.dig("image", "url")?.url ?? item.dig("image", "thumbnail")?.url,
            releaseDate: item["released"]?.string,
            rating: item["rating"]?.double.map { $0 > 10 ? $0 / 10 : $0 },
            ratingCount: item["votecount"]?.int,
            developerNames: item["developers"]?.array?.compactMap { $0.firstString("name", "original") } ?? [],
            tags: item["tags"]?.array?.compactMap { $0["name"]?.string } ?? []
        )
    }
}
