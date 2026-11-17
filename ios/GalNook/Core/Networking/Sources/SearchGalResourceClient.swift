import Foundation

public struct SearchGalResourceClient: ResourceClient {
    public let name = "SearchGal"
    private let session: URLSession
    private let baseProvider: @Sendable () -> URL

    public init(session: URLSession = .shared, baseProvider: (@Sendable () -> URL)? = nil) {
        self.session = session
        self.baseProvider = baseProvider ?? {
            let keychain = KeychainStore()
            if let value = keychain.string(for: "searchgal.baseURL")?.nilIfBlank,
               let url = URL(string: value), url.scheme != nil { return url }
            return URL(string: "https://vercel.api.searchgal.top")!
        }
    }

    public func resources(for work: WorkSummary) async throws -> [GameResource] {
        let onlyPrimary = UserDefaults.standard.object(forKey: "only_searchgal") as? Bool ?? true
        do {
            let primary = try await fetchResources(for: work, base: baseProvider())
            if onlyPrimary || !primary.isEmpty { return primary }
        } catch {
            if onlyPrimary { throw error }
        }
        return try await fetchResources(for: work, base: URL(string: "https://gal.0721ciallo.top")!)
    }

    private func fetchResources(for work: WorkSummary, base baseURL: URL) async throws -> [GameResource] {
        let endpoint = baseURL.appendingPathComponent("gal")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("GalNook-iOS/1.0", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "game", value: work.title)]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw APIError(statusCode: status, responseBody: String(data: data.prefix(600), encoding: .utf8))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceFailure.malformedResponse("SearchGal 返回了非 UTF-8 事件流")
        }
        var resources: [GameResource] = []
        var seenURLs = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("data:") {
                line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("{"), let lineData = line.data(using: .utf8),
                  let event = try? JSONValue.objectValue(lineData),
                  let result = event["result"] else { continue }
            let siteName = result["name"]?.string?.nilIfBlank ?? "资源站"
            let tags = result["tags"]?.array?.compactMap(\.string) ?? []
            var siteCount = 0
            for item in result["items"]?.array ?? [] {
                guard siteCount < 40,
                      let urlString = item["url"]?.string?.nilIfBlank,
                      let url = URL(string: urlString),
                      !seenURLs.contains(url.absoluteString) else { continue }
                seenURLs.insert(url.absoluteString)
                siteCount += 1
                let itemName = item["name"]?.string?.nilIfBlank ?? work.title
                resources.append(makeResource(itemName: itemName, url: url, siteName: siteName, tags: tags, work: work))
            }
        }
        return resources
    }

    private func makeResource(itemName: String, url: URL, siteName: String, tags: [String], work: WorkSummary) -> GameResource {
        let provider = PanProvider.detect(url: url)
        let lower = "\(itemName) \(tags.joined(separator: " "))".lowercased()
        let engine: GameEngine
        if lower.contains("ren'py") || lower.contains("renpy") { engine = .renpy }
        else if lower.contains("krkr") || lower.contains("kirikiri") || lower.contains("xp3") { engine = .kirikiri }
        else if lower.contains("ons") { engine = .onscripter }
        else if lower.contains("tyrano") { engine = .tyrano }
        else if lower.contains("artemis") { engine = .artemis }
        else if lower.contains("rpg") { engine = .rpgMaker }
        else { engine = .unknown }
        let isAPK = url.pathExtension.lowercased() == "apk" || lower.contains(".apk") || lower.contains("安卓直装")
        let isDirect = provider == .direct
        return GameResource(
            id: "searchgal:\(url.absoluteString)",
            workID: work.id,
            title: itemName,
            sourceName: siteName,
            pageURL: provider == .other ? url : nil,
            shareURL: isDirect || provider == .other ? nil : url,
            directURL: isDirect ? url : nil,
            provider: provider,
            fileName: URL(string: itemName)?.pathExtension.isEmpty == false ? itemName : nil,
            sharePassword: tags.first(where: { $0.contains("提取码") }),
            extractionPassword: tags.first(where: { $0.contains("解压") }),
            platform: lower.contains("android") || lower.contains("安卓") ? .android : .unknown,
            engine: engine,
            note: tags.joined(separator: " · ").nilIfBlank,
            isAndroidPackage: isAPK
        )
    }
}
