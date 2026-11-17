import Foundation

struct LanzouResponse: Decodable {
    let zt: Int?
    let inf: String?
    let dom: String?
    let url: String?
}

struct LanzouClient: Sendable {
    let http: PanHTTPClient

    func resolve(_ link: PanShareLink, shareURL: URL) async throws -> PanResolution {
        let site = link.site
        precondition(site == .lanzou || site == .ilanzou)
        var headers = [
            "User-Agent": PanHTTP.chrome124UserAgent,
            "Referer": shareURL.absoluteString
        ]
        if site == .lanzou { headers["Accept-Language"] = "zh-CN,zh;q=0.9" }
        let firstResponse = try await http.data(PanHTTP.request(shareURL, headers: headers))
        try PanResponse.validate(firstResponse, site: site)
        var html = String(data: firstResponse.data, encoding: .utf8) ?? ""
        if site == .lanzou, let iframe = Self.iframeURL(in: html, relativeTo: shareURL) {
            let response = try await http.data(PanHTTP.request(iframe, headers: headers))
            try PanResponse.validate(response, site: site)
            html = String(data: response.data, encoding: .utf8) ?? ""
        }
        guard let fileID = Self.fileID(in: html) else {
            throw PanError.needLogin(
                site: site.rawValue,
                message: "无法识别蓝奏页面 file id，页面可能要求登录或结构已变化"
            )
        }

        var websignkey = ""
        var sign = ""
        var kd = "1"
        if site == .lanzou {
            guard let extractedSign = Self.scriptValue(named: "sign", in: html, pattern: "[0-9a-fA-F]+"),
                  let extractedKey = Self.scriptValue(named: "websignkey", in: html, pattern: "[^'\"]*") else {
                throw PanError.needLogin(
                    site: site.rawValue,
                    message: "蓝奏页面缺少 sign 或 websignkey"
                )
            }
            sign = extractedSign
            websignkey = extractedKey
            kd = Self.scriptValue(named: "kd", in: html, pattern: "\\d+") ?? "1"
        }
        guard let ajaxURL = Self.ajaxURL(fileID: fileID, shareURL: shareURL) else {
            throw PanError.invalidShare(site: site.rawValue, message: "蓝奏分享 URL 无效")
        }
        let body = PanHTTP.formBody([
            ("action", "downprocess"),
            ("websign", ""),
            ("websignkey", websignkey),
            ("sign", sign),
            ("kd", kd)
        ])
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let response = try await http.data(PanHTTP.request(
            ajaxURL,
            method: "POST",
            headers: headers,
            body: body
        ))
        try PanResponse.validate(response, site: site)
        let download = try PanResponse.decode(LanzouResponse.self, response: response, site: site)
        if site == .lanzou, download.zt != 1 {
            let message = download.inf ?? "蓝奏下载请求失败"
            if message.contains("登录") {
                throw PanError.needLogin(site: site.rawValue, message: message)
            }
            throw PanError.remote(site: site.rawValue, message: message, statusCode: nil)
        }
        guard let dom = download.dom?.nilIfBlank, let path = download.url?.nilIfBlank else {
            throw PanError.remote(site: site.rawValue, message: download.inf ?? "蓝奏响应缺少 dom 或 url", statusCode: nil)
        }
        let finalURL = dom + "/file/" + path
        guard URL(string: finalURL) != nil else {
            throw PanError.remote(site: site.rawValue, message: "蓝奏返回了无效下载地址", statusCode: nil)
        }
        let name = Self.fileName(in: html) ?? link.code
        return PanResolution(
            site: site.rawValue,
            note: name,
            files: [PanFile(name: name, url: finalURL, referer: shareURL.absoluteString)]
        )
    }

    static func fileID(in html: String) -> String? {
        if let id = PanRegex.first(in: html, pattern: #"ajaxm?\.php\?file=(\d+)"#) { return id }
        return PanRegex.first(
            in: html,
            pattern: #"(?:['"]file['"]|\bfile)\s*(?:=|:|,)\s*['"]?(\d{6,})"#
        )
    }

    static func iframeURL(in html: String, relativeTo base: URL) -> URL? {
        guard let source = PanRegex.first(
            in: html,
            pattern: #"<iframe[^>]*\bsrc\s*=\s*["']([^"']+)["']"#
        ) else { return nil }
        return URL(string: source, relativeTo: base)?.absoluteURL
    }

    static func fileName(in html: String) -> String? {
        guard let title = PanRegex.first(in: html, pattern: #"<title[^>]*>(.*?)</title>"#) else { return nil }
        let name = title.components(separatedBy: " - ").first ?? title
        return decodeEntities(name).nilIfBlank
    }

    private static func scriptValue(named name: String, in html: String, pattern value: String) -> String? {
        let patterns = [
            #"['"]?"# + name + #"['"]?\s*:\s*['"]("# + value + #")['"]"#,
            #"\b"# + name + #"\s*=\s*['"]("# + value + #")['"]"#
        ]
        for pattern in patterns {
            if let result = PanRegex.first(in: html, pattern: pattern) { return result }
        }
        return nil
    }

    private static func ajaxURL(fileID: String, shareURL: URL) -> URL? {
        guard var components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, !scheme.isEmpty,
              components.host != nil else { return nil }
        components.path = "/ajaxm.php"
        components.queryItems = [URLQueryItem(name: "file", value: fileID)]
        components.fragment = nil
        return components.url
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
