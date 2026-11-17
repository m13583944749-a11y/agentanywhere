import Foundation

public actor NextMoeClient: WorkSourceClient {
    public nonisolated let source: WorkSource = .nextMoe
    private let baseURL = URL(string: "https://api.nextmoe.dev")!
    private let api: APIClient
    private var cursors: [String: String] = [:]

    public init(api: APIClient = .shared) { self.api = api }

    public func works(query: WorkQuery, page: Int, limit: Int, includeAdult: Bool) async throws -> WorkPage {
        let cacheKey = "\(query):\(limit):\(includeAdult)"
        if page <= 1 { cursors.removeValue(forKey: cacheKey) }
        var queryItems = [
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
            URLQueryItem(name: "include", value: "titles,covers,ratings,companies,tags"),
            URLQueryItem(name: "nsfw", value: String(includeAdult))
        ]
        switch query {
        case .search(let text):
            queryItems.append(URLQueryItem(name: "q", value: text))
            queryItems.append(URLQueryItem(name: "sort", value: "relevance"))
        case .latest:
            queryItems.append(URLQueryItem(name: "sort", value: "release_date"))
        case .popular:
            queryItems.append(URLQueryItem(name: "sort", value: "popularity"))
        case .highlyRated:
            queryItems.append(URLQueryItem(name: "sort", value: "rating"))
        case .tag(let id):
            queryItems.append(URLQueryItem(name: "tag_id", value: id))
        case .company(let id):
            queryItems.append(URLQueryItem(name: "company_id", value: id))
        case .random:
            queryItems.append(URLQueryItem(name: "sort", value: "random"))
        case .advanced(let search, let sort, let filter):
            if let search, !search.isEmpty { queryItems.append(URLQueryItem(name: "q", value: search)) }
            let sortValue: String
            switch sort {
            case .popularity: sortValue = search?.isEmpty == false ? "relevance" : "popularity"
            case .nextMoeRating: sortValue = "rating"
            case .vndbRating: sortValue = "vndb"
            case .erogameRating: sortValue = "erogamescape"
            case .releaseDate: sortValue = "release_date"
            }
            queryItems.append(URLQueryItem(name: "sort", value: sortValue))
            queryItems.append(URLQueryItem(name: "olang", optionalValue: filter.language))
            queryItems.append(URLQueryItem(name: "platform", optionalValue: filter.platform))
            queryItems.append(URLQueryItem(name: "year", int: filter.year))
            if let score = filter.minimumScore { queryItems.append(URLQueryItem(name: "score_min", value: String(score))) }
            queryItems.append(URLQueryItem(name: "tag_id", optionalValue: filter.tagID))
        }
        if page > 1, let cursor = cursors[cacheKey], !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        } else if page > 1 {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        let response = try await api.data(
            baseURL.appendingPathComponent("v2/catalog/works"),
            query: queryItems
        )
        let json = try JSONValue.objectValue(response.data)
        let items = (json["items"]?.array ?? json["results"]?.array ?? []).map(mapSummary)
        let next = json["next_cursor"]?.string?.nilIfBlank
        if let next { cursors[cacheKey] = next } else { cursors.removeValue(forKey: cacheKey) }
        let total = json["total"]?.int
        let hasMore = next != nil || (total.map { page * limit < $0 } ?? (items.count == limit))
        return WorkPage(items: items, page: page, hasMore: hasMore, nextCursor: next)
    }

    public func detail(for work: WorkSummary) async throws -> WorkDetail {
        let response = try await api.data(
            detailURL(work.sourceID),
            query: [
                URLQueryItem(name: "view", value: "full"),
                URLQueryItem(name: "include", value: "tags,intros,relations,covers,playtimes,ratings,companies,titles"),
                URLQueryItem(name: "nsfw", value: "true")
            ]
        )
        let item = try JSONValue.objectValue(response.data)
        guard item["id"]?.string != nil else { throw SourceFailure.malformedResponse("NextMoe 未返回作品详情") }
        var summary = mapSummary(item)
        summary.sourceID = work.sourceID
        let aliases = localizedValues(item["localized"]) + (item["aliases"]?.array?.compactMap(\.string) ?? [])
        let description = bestIntro(item["intros"]) ?? item["description"]?.string ?? item["intro"]?.string
        let publishers = (item["companies"]?.array ?? []).filter {
            let role = $0.firstString("role", "type", "kind")?.lowercased() ?? ""
            return role.contains("publish") || role.contains("发行")
        }.map { localizedName($0) }.filter { !$0.isEmpty }
        let screenshots = (item["covers"]?.array ?? item["screenshots"]?.array ?? []).compactMap {
            $0["url"]?.url ?? $0.url
        }
        var links = [ExternalLink(title: "NextMoe", url: URL(string: "https://www.nextmoe.dev/works/\(work.sourceID)") ?? detailURL(work.sourceID))]
        if let linkResponse = try? await api.data(detailURL(work.sourceID).appendingPathComponent("links")),
           let linkJSON = try? JSONValue.objectValue(linkResponse.data) {
            for link in linkJSON["items"]?.array ?? linkJSON["links"]?.array ?? [] {
                guard let url = link["url"]?.url else { continue }
                let title = link.firstString("label", "site", "name") ?? url.host ?? "外部链接"
                links.append(ExternalLink(title: title, url: url))
            }
        }
        for relation in item["relations"]?.array ?? [] {
            if let title = relation.firstString("name", "title", "label"), let url = relation["url"]?.url {
                links.append(ExternalLink(title: title, url: url))
            }
        }
        let relatedWorks = (item["relations"]?.array ?? []).compactMap { relation -> WorkSummary? in
            guard let related = relation["work"] else { return nil }
            return mapSummary(related)
        }
        var comments: [RemoteComment] = []
        for comment in item["reviews"]?.array ?? item["comments"]?.array ?? [] {
            let author = comment.dig("author", "name")?.string
                ?? comment.dig("user", "display_name")?.string
                ?? comment["author"]?.string
                ?? "匿名"
            let content = comment.firstString("content", "text", "body") ?? ""
            let translated = comment.firstString("translated_content", "translation", "content_zh", "localized")
            let rating = comment["score"]?.double ?? comment["rating"]?.double
            let createdAt = comment.firstString("created_at", "updated_at")
            let spoilers = comment["spoiler"]?.bool ?? comment["has_spoilers"]?.bool ?? false
            comments.append(RemoteComment(
                id: comment["id"]?.string ?? UUID().uuidString,
                author: author,
                content: content,
                translatedContent: translated,
                rating: rating,
                createdAt: createdAt,
                hasSpoilers: spoilers
            ))
        }
        return WorkDetail(
            summary: summary,
            aliases: Array(Set(aliases)).sorted(),
            description: description,
            publishers: publishers,
            links: links,
            comments: comments,
            screenshots: screenshots,
            relatedWorkIDs: relatedWorks.map(\.sourceID),
            relatedWorks: relatedWorks
        )
    }

    public func characters(for work: WorkSummary) async throws -> [GameCharacter] {
        let response = try await api.data(
            detailURL(work.sourceID).appendingPathComponent("characters"),
            query: [URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "nsfw", value: "true")]
        )
        let json = try JSONValue.objectValue(response.data)
        return (json["items"]?.array ?? json["results"]?.array ?? []).map { item in
            let voices = (item["voices"]?.array ?? []).compactMap {
                $0.firstString("name", "display_name", "label") ?? $0.string
            }
            return GameCharacter(
                id: item["id"]?.string ?? UUID().uuidString,
                name: localizedName(item),
                originalName: item.firstString("display_name", "original_name", "latin"),
                role: item.firstString("role", "character_role"),
                description: item.firstString("description", "intro"),
                imageURL: item.dig("figure", "url")?.url ?? item.dig("image", "url")?.url,
                birthday: item["birthday"]?.string,
                bloodType: item.firstString("blood_type", "blood"),
                height: item["height"]?.string,
                measurements: item.firstString("measurements", "bwh"),
                voiceActor: voices.joined(separator: " / ").nilIfBlank
            )
        }
    }

    public func walkthroughs(for work: WorkSummary) async throws -> [Walkthrough] {
        let response = try await api.data(
            baseURL.appendingPathComponent("v2/catalog/walkthroughs"),
            query: [URLQueryItem(name: "work_id", value: work.sourceID), URLQueryItem(name: "limit", value: "20")]
        )
        let json = try JSONValue.objectValue(response.data)
        let items = json["items"]?.array ?? json["results"]?.array ?? json.array ?? []
        var result: [Walkthrough] = []
        for item in items {
            let id = item["id"]?.string ?? UUID().uuidString
            var content = item.firstString("content", "text", "body") ?? ""
            if content.isEmpty {
                let detailResponse = try await api.data(
                    baseURL.appendingPathComponent("v2/catalog/walkthroughs/\(id)"),
                    query: [URLQueryItem(name: "view", value: "full"), URLQueryItem(name: "nsfw", value: "true")]
                )
                let detail = try JSONValue.objectValue(detailResponse.data)
                content = detail.firstString("content", "text", "body") ?? renderChart(detail)
            }
            result.append(Walkthrough(
                id: id,
                workID: work.id,
                title: item.firstString("title", "name") ?? "游戏攻略",
                content: content,
                sourceURL: item["source_url"]?.url ?? item["url"]?.url,
                isAdultOnly: item["r18"]?.bool ?? item["nsfw"]?.bool ?? false
            ))
        }
        return result
    }

    public func tags() async throws -> [CatalogTag] {
        let response = try await api.data(
            baseURL.appendingPathComponent("v2/catalog/tags"),
            query: [URLQueryItem(name: "limit", value: "80")]
        )
        let json = try JSONValue.objectValue(response.data)
        return (json["items"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.string else { return nil }
            return CatalogTag(
                id: id,
                name: localizedName(item),
                isSexual: item["is_sexual"]?.bool ?? false
            )
        }
    }

    private func renderChart(_ detail: JSONValue) -> String {
        guard let chart = detail["chart"] else { return "" }
        var lines: [String] = []
        for section in chart["sections"]?.array ?? [] {
            let title = localizedText(section["localized"]) ?? section["title"]?.string ?? section["key"]?.string ?? "章节"
            lines.append("\n## \(title)")
            for segment in chart["segments"]?.array ?? [] where segment["section_key"]?.string == section["key"]?.string {
                if let condition = localizedText(segment["condition_localized"]) ?? segment["condition"]?.string?.nilIfBlank {
                    lines.append("条件：\(condition)")
                }
                for step in segment["steps"]?.array ?? [] {
                    if let text = localizedText(step["localized"]) ?? step["text"]?.string?.nilIfBlank {
                        lines.append("• \(text)")
                    }
                    if let remark = step["remark"]?.string?.nilIfBlank { lines.append("  备注：\(remark)") }
                    for alternative in step["alternatives"]?.array ?? [] {
                        if let text = localizedText(alternative["localized"]) ?? alternative["text"]?.string?.nilIfBlank {
                            lines.append("  其他选项：\(text)")
                        }
                    }
                }
            }
        }
        let endings = chart["endings"]?.array ?? []
        if !endings.isEmpty {
            lines.append("\n## 结局")
            for ending in endings {
                let name = localizedText(ending["localized"]) ?? ending["name"]?.string ?? ending["key"]?.string ?? "结局"
                lines.append("• \(name)")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func localizedText(_ value: JSONValue?) -> String? {
        for key in ["zh-Hans", "zh-Hant", "zh"] {
            if let text = value?[key]?["value"]?.string?.nilIfBlank ?? value?[key]?.string?.nilIfBlank { return text }
        }
        return nil
    }

    private func detailURL(_ id: String) -> URL {
        baseURL.appendingPathComponent("v2/catalog/works").appendingPathComponent(id)
    }

    private func mapSummary(_ item: JSONValue) -> WorkSummary {
        let id = item["id"]?.string ?? UUID().uuidString
        let rating = preferredRating(item["ratings"]?.array ?? [])
        return WorkSummary(
            source: .nextMoe,
            sourceID: id,
            title: localizedName(item),
            originalTitle: item.firstString("display_name", "latin"),
            coverURL: item.dig("cover", "url")?.url ?? item.dig("banner", "url")?.url,
            releaseDate: item["release_date"]?.string,
            rating: rating?.score,
            ratingCount: rating?.count,
            developerNames: (item["companies"]?.array ?? []).map(localizedName),
            tags: (item["tags"]?.array ?? []).map(localizedName)
        )
    }

    private func localizedName(_ item: JSONValue) -> String {
        if let chinese = item.dig("localized", "zh-Hans", "value")?.string?.nilIfBlank { return chinese }
        if let chinese = item.dig("localized", "zh", "value")?.string?.nilIfBlank { return chinese }
        return item.firstString("display_name", "name", "title", "latin", "value") ?? "未命名"
    }

    private func localizedValues(_ localized: JSONValue?) -> [String] {
        guard let object = localized?.object else { return [] }
        return object.values.compactMap { $0["value"]?.string ?? $0.string }
    }

    private func bestIntro(_ intros: JSONValue?) -> String? {
        guard let items = intros?.array else { return intros?.string }
        let preferred = items.first { item in
            let language = item.firstString("lang", "language", "locale") ?? ""
            return language.hasPrefix("zh")
        } ?? items.first
        return preferred?.firstString("content", "value", "intro", "description", "text")
    }

    private func preferredRating(_ ratings: [JSONValue]) -> (score: Double, count: Int)? {
        let candidates = ratings.compactMap { item -> (score: Double, count: Int, source: String)? in
            guard var score = item.firstString("score", "rating", "value").flatMap(Double.init) ?? item["score"]?.double ?? item["rating"]?.double else { return nil }
            let source = item.firstString("source", "site", "provider")?.lowercased() ?? ""
            if source.contains("dlsite") {
                if score <= 5 { score *= 2 }
            } else if score > 10 {
                score /= 10
            }
            let count = item["vote_count"]?.int ?? item["votes"]?.int ?? 0
            return (score, count, source)
        }
        return candidates.sorted { $0.count > $1.count }.first.map { ($0.score, $0.count) }
    }
}
