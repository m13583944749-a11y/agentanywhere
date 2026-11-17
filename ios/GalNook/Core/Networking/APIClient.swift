import Foundation

public struct APIError: LocalizedError, Sendable {
    public var statusCode: Int?
    public var responseBody: String?
    public var underlyingDescription: String?

    public init(statusCode: Int? = nil, responseBody: String? = nil, underlyingDescription: String? = nil) {
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? {
        if let statusCode {
            return "请求失败（HTTP \(statusCode)）\(responseBody?.isEmpty == false ? "：\(responseBody!)" : "")"
        }
        return underlyingDescription ?? "网络请求失败"
    }
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var response: HTTPURLResponse
}

public actor APIClient {
    public static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .useDefaultKeys
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func data(
        _ url: URL,
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        acceptsHTTPError: Bool = false
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let finalURL = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 45
        request.setValue("GalNook-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(underlyingDescription: "服务器返回了无效响应")
        }
        if !acceptsHTTPError, !(200..<300).contains(http.statusCode) {
            let text = String(data: data.prefix(32_768), encoding: .utf8)
            throw APIError(statusCode: http.statusCode, responseBody: text)
        }
        return HTTPResponse(data: data, response: http)
    }

    public func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            let preview = String(data: response.data.prefix(2_048), encoding: .utf8) ?? "非文本响应"
            throw APIError(underlyingDescription: "响应解析失败：\(error.localizedDescription)\n\(preview)")
        }
    }

    public func json<T: Decodable>(
        _ type: T.Type,
        url: URL,
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> T {
        let response = try await data(url, method: method, query: query, headers: headers, body: body)
        return try decode(T.self, from: response)
    }

    public func jsonObject(_ object: some Encodable) throws -> Data {
        try JSONEncoder().encode(object)
    }
}

public extension URLQueryItem {
    init(name: String, optionalValue: String?) {
        self.init(name: name, value: optionalValue?.isEmpty == false ? optionalValue : nil)
    }

    init(name: String, int: Int?) {
        self.init(name: name, value: int.map(String.init))
    }
}
