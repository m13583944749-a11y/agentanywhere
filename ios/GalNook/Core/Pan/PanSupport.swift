import Foundation

public enum PanSite: String, Codable, CaseIterable, Sendable {
    case quark, uc, baidu, pan115, pan123, lanzou, ilanzou
    case xunlei, caiyun, guangya

    var displayName: String {
        switch self {
        case .quark: "夸克网盘"
        case .uc: "UC 网盘"
        case .baidu: "百度网盘"
        case .pan115: "115"
        case .pan123: "123 云盘"
        case .lanzou: "蓝奏云"
        case .ilanzou: "蓝奏优享版"
        case .xunlei: "迅雷云盘"
        case .caiyun: "和彩云"
        case .guangya: "光年"
        }
    }

    var accountKey: String? {
        switch self {
        case .pan115: PanAccountStore.pan115
        case .quark: PanAccountStore.quark
        case .uc: PanAccountStore.uc
        case .baidu: PanAccountStore.baidu
        case .pan123: PanAccountStore.pan123
        case .ilanzou: PanAccountStore.ilanzou
        case .xunlei: PanAccountStore.xunlei
        case .caiyun: PanAccountStore.caiyun
        case .guangya: PanAccountStore.guangya
        case .lanzou: nil
        }
    }

    static func detect(_ url: URL) -> PanSite? {
        let host = (url.host ?? "").lowercased()
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("pan.quark.cn") { return .quark }
        if matches("drive.uc.cn") { return .uc }
        if matches("pan.baidu.com") { return .baidu }
        if matches("115.com") { return .pan115 }
        if host.contains("123pan") || matches("123865.com") || matches("123684.com") || matches("123912.com") {
            return .pan123
        }
        if matches("ilanzou.com") { return .ilanzou }
        for domain in ["lanzou.com", "lanzoui.com", "lanzoux.com", "lanzouy.com", "lanzouj.com", "lanzouw.com", "lanzn.com"] {
            if matches(domain) { return .lanzou }
        }
        if matches("pan.xunlei.com") { return .xunlei }
        if matches("caiyun.139.com") || matches("yun.139.com") { return .caiyun }
        if matches("guangyapan.com") { return .guangya }
        return nil
    }
}

public struct PanShareLink: Equatable, Sendable {
    public var site: PanSite
    public var code: String
    public var passcode: String

    public static func parse(_ url: URL, fallbackPasscode: String? = nil) throws -> PanShareLink {
        guard let site = PanSite.detect(url) else {
            throw PanError.unsupportedProvider(site: url.host ?? "未知网盘")
        }
        if site == .xunlei || site == .caiyun || site == .guangya {
            throw PanError.unsupportedProvider(site: site.rawValue)
        }
        let absolute = url.absoluteString
        let code: String
        if site == .lanzou || site == .ilanzou {
            guard let pathCode = url.lastPathComponent.nilIfBlank else {
                throw PanError.invalidShare(site: site.rawValue, message: "蓝奏分享链接缺少路径")
            }
            code = pathCode
        } else {
            let codePattern = site == .pan115
                ? #"/s/([0-9a-zA-Z]+)"#
                : #"/s/([0-9A-Za-z_-]+)"#
            guard let extracted = PanRegex.first(in: absolute, pattern: codePattern) else {
                throw PanError.invalidShare(site: site.rawValue, message: "无法从分享链接识别分享码")
            }
            code = extracted
        }
        let passcodeNames: [String]
        switch site {
        case .pan115: passcodeNames = ["password", "pwd"]
        case .pan123: passcodeNames = ["pwd", "password"]
        default: passcodeNames = ["pwd"]
        }
        var passcode = ""
        for name in passcodeNames {
            if let value = PanRegex.first(in: absolute, pattern: #"[?&]"# + name + #"=([0-9A-Za-z]+)"#) {
                passcode = value
                break
            }
        }
        if passcode.isEmpty { passcode = fallbackPasscode ?? "" }
        return PanShareLink(site: site, code: code, passcode: passcode)
    }
}

struct PanLooseString: Codable, Hashable, Sendable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value }
        else if let value = try? container.decode(Int64.self) { self.value = String(value) }
        else if let value = try? container.decode(Double.self) { self.value = String(value) }
        else if let value = try? container.decode(Bool.self) { self.value = String(value) }
        else { self.value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

enum PanRegex {
    static func first(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.range(at: group).location != NSNotFound,
              let result = Range(match.range(at: group), in: text) else { return nil }
        return String(text[result])
    }
}

enum PanHTTP {
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let chrome124UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    static let galNookUserAgent = "GalNook/1.1.25 (Android; +https://galnook.app)"

    static func request(
        _ url: URL,
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let finalURL = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 25
        request.setValue(galNookUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        pairs.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func stringBody(_ data: Data, limit: Int = 1_024) -> String {
        String(data: data.prefix(limit), encoding: .utf8) ?? "非文本响应"
    }
}

private final class PanNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct PanHTTPClient: Sendable {
    let session: URLSession

    func data(_ request: URLRequest, followsRedirects: Bool = true) async throws -> HTTPResponse {
        let delegate: PanNoRedirectDelegate? = followsRedirects ? nil : PanNoRedirectDelegate()
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(underlyingDescription: "服务器返回了无效响应")
        }
        return HTTPResponse(data: data, response: http)
    }
}

enum PanResponse {
    static func validate(_ response: HTTPResponse, site: PanSite) throws {
        let status = response.response.statusCode
        guard !(200..<300).contains(status) else { return }
        let body = PanHTTP.stringBody(response.data)
        switch status {
        case 401, 403:
            throw PanError.needLogin(site: site.rawValue, message: body.isEmpty ? "网盘要求登录" : body)
        case 404, 410:
            throw PanError.invalidShare(site: site.rawValue, message: body.isEmpty ? "分享不存在或已失效" : body)
        case 429:
            throw PanError.rateLimited(site: site.rawValue, message: body.isEmpty ? "网盘请求过于频繁" : body)
        default:
            throw PanError.remote(site: site.rawValue, message: body, statusCode: status)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, response: HTTPResponse, site: PanSite) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.data) }
        catch {
            throw PanError.remote(
                site: site.rawValue,
                message: "响应解析失败：\(error.localizedDescription)",
                statusCode: response.response.statusCode
            )
        }
    }
}

enum PanByteFormatter {
    static func string(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "0 B" }
        if bytes < 1_024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = "B"
        for next in units where value >= 1_024 {
            value /= 1_024
            unit = next
        }
        return String(format: "%.1f %@", value, unit)
    }
}

func panRemoteError(_ error: Error, site: PanSite) -> PanError {
    if let error = error as? PanError { return error }
    return .remote(site: site.rawValue, message: error.localizedDescription, statusCode: nil)
}
