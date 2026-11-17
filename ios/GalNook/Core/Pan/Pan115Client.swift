import Foundation

struct ChromeVersionResponse: Decodable { let data: ChromeVersionData? }
struct ChromeVersionData: Decodable { let win: ChromeVersionWin? }
struct ChromeVersionWin: Decodable {
    let versionCode: String?
    enum CodingKeys: String, CodingKey { case versionCode = "version_code" }
}

struct Pan115SnapResponse: Decodable {
    let message: String?
    let data: Pan115SnapData?
}

struct Pan115SnapData: Decodable {
    let userinfo: Pan115UserInfo?
    let shareinfo: Pan115ShareInfo?
    let list: [Pan115File]?
}

struct Pan115UserInfo: Decodable {
    let userId: PanLooseString
    enum CodingKeys: String, CodingKey { case userId = "user_id" }
}

struct Pan115ShareInfo: Decodable {
    let shareTitle: String?
    enum CodingKeys: String, CodingKey { case shareTitle = "share_title" }
}

struct Pan115File: Decodable {
    let isDir: Int?
    let fid: PanLooseString
    let n: String?
    let s: PanLooseString?

    enum CodingKeys: String, CodingKey {
        case isDir = "is_dir"
        case fid, n, s
    }
}

struct Pan115DownloadResponse: Decodable { let data: Pan115DownloadData? }

struct Pan115DownloadData: Decodable {
    let fileUrl302: String?
    let fileUrl: String?
    let url: Pan115NestedURL?
    let fn: String?

    enum CodingKeys: String, CodingKey {
        case fileUrl302 = "file_url_302"
        case fileUrl = "file_url"
        case url, fn
    }
}

struct Pan115NestedURL: Decodable { let url: String? }

struct Pan115Client: Sendable {
    let http: PanHTTPClient

    func resolve(_ link: PanShareLink, cookie: String?) async throws -> PanResolution {
        let site = PanSite.pan115
        guard let cookie = cookie?.nilIfBlank else {
            throw PanError.needLogin(site: site.rawValue, message: "115 网盘需要账号 Cookie")
        }
        let version = await chromeVersion()
        let shareReferer = Self.referer(for: link)
        let headers = [
            "User-Agent": "Mozilla/5.0 115Browser/\(version)",
            "Referer": shareReferer,
            "Cookie": cookie
        ]
        let snapRequest = try PanHTTP.request(
            URL(string: "https://webapi.115.com/share/snap")!,
            query: [
                URLQueryItem(name: "share_code", value: link.code),
                URLQueryItem(name: "receive_code", value: link.passcode),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "asc", value: "0"),
                URLQueryItem(name: "cid", value: "0"),
                URLQueryItem(name: "format", value: "json")
            ],
            headers: headers
        )
        let snapResponse = try await http.data(snapRequest)
        try PanResponse.validate(snapResponse, site: site)
        let snap = try PanResponse.decode(Pan115SnapResponse.self, response: snapResponse, site: site)
        guard let data = snap.data else {
            throw PanError.needLogin(
                site: site.rawValue,
                message: snap.message ?? "115 未返回分享数据，请检查登录状态"
            )
        }
        guard let userID = data.userinfo?.userId.value.nilIfBlank else {
            throw PanError.needLogin(site: site.rawValue, message: "115 分享响应缺少 user_id")
        }
        let items = (data.list ?? []).filter { $0.isDir != 1 && !$0.fid.value.isEmpty }
        guard !items.isEmpty else { throw PanError.empty(site: site.rawValue) }

        var files: [PanFile] = []
        files.reserveCapacity(items.count)
        for item in items {
            var query = [
                URLQueryItem(name: "dl", value: "1"),
                URLQueryItem(name: "user_id", value: userID),
                URLQueryItem(name: "share_code", value: link.code),
                URLQueryItem(name: "file_id", value: item.fid.value)
            ]
            if !link.passcode.isEmpty {
                query.append(URLQueryItem(name: "receive_code", value: link.passcode))
            }
            let request = try PanHTTP.request(
                URL(string: "https://webapi.115.com/share/downurl")!,
                query: query,
                headers: headers
            )
            let response = try await http.data(request)
            try PanResponse.validate(response, site: site)
            let download = try PanResponse.decode(Pan115DownloadResponse.self, response: response, site: site)
            guard let downloadData = download.data else {
                throw PanError.remote(site: site.rawValue, message: "115 下载响应缺少 data", statusCode: nil)
            }
            let resolvedURL = downloadData.fileUrl302?.nilIfBlank
                ?? downloadData.fileUrl?.nilIfBlank
                ?? downloadData.url?.url?.nilIfBlank
            guard let url = resolvedURL else {
                throw PanError.remote(site: site.rawValue, message: "115 下载响应缺少文件地址", statusCode: nil)
            }
            let bytes = item.s.flatMap { Int64($0.value) }
            files.append(PanFile(
                name: downloadData.fn?.nilIfBlank ?? item.n?.nilIfBlank ?? item.fid.value,
                url: url,
                size: PanByteFormatter.string(bytes),
                referer: shareReferer,
                sizeBytes: bytes
            ))
        }
        return PanResolution(
            site: site.rawValue,
            note: data.shareinfo?.shareTitle?.nilIfBlank ?? "已解析 \(files.count) 个文件",
            files: files
        )
    }

    static func referer(for link: PanShareLink) -> String {
        var components = URLComponents(string: "https://115.com/s/\(link.code)")!
        if !link.passcode.isEmpty {
            components.queryItems = [URLQueryItem(name: "password", value: link.passcode)]
        }
        return components.string!
    }

    private func chromeVersion() async -> String {
        do {
            let request = try PanHTTP.request(URL(string: "https://appversion.115.com/1/web/1.0/api/chrome")!)
            let response = try await http.data(request)
            guard (200..<300).contains(response.response.statusCode) else { return "36.0.1" }
            let decoded = try JSONDecoder().decode(ChromeVersionResponse.self, from: response.data)
            return decoded.data?.win?.versionCode?.nilIfBlank ?? "36.0.1"
        } catch {
            return "36.0.1"
        }
    }
}
