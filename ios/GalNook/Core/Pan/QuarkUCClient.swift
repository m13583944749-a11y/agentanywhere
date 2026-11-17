import Foundation

struct QuarkTokenRequest: Encodable {
    let pwdID: String
    let passcode: String
    let supportVisitLimitPrivateShare: Bool

    enum CodingKeys: String, CodingKey {
        case pwdID = "pwd_id"
        case passcode
        case supportVisitLimitPrivateShare = "support_visit_limit_private_share"
    }
}

struct QuarkTokenResponse: Decodable {
    let status: Int?
    let code: Int?
    let message: String?
    let data: QuarkTokenData?
}

struct QuarkTokenData: Decodable {
    let stoken: String
    let title: String?
}

struct QuarkListResponse: Decodable {
    let status: Int?
    let code: Int?
    let message: String?
    let data: QuarkListData?
}

struct QuarkListData: Decodable { let list: [QuarkListItem]? }

struct QuarkListItem: Decodable {
    let dir: Bool?
    let fid: PanLooseString
    let shareFidToken: String
    let fileName: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case dir, fid, size
        case shareFidToken = "share_fid_token"
        case fileName = "file_name"
    }
}

struct QuarkDownloadRequest: Encodable {
    let fids: [String]
    let fidsToken: [String]
    let pwdID: String
    let stoken: String
    let speedupSession: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case fids
        case fidsToken = "fids_token"
        case pwdID = "pwd_id"
        case stoken
        case speedupSession = "speedup_session"
        case token
    }
}

struct QuarkDownloadResponse: Decodable {
    let code: Int?
    let message: String?
    let data: [QuarkDownloadItem]?
}

struct QuarkDownloadItem: Decodable {
    let downloadUrl: String

    enum CodingKeys: String, CodingKey { case downloadUrl = "download_url" }
}

struct QuarkUCClient: Sendable {
    struct Configuration: Sendable {
        let site: PanSite
        let sharePage: String
        let userAgent: String
        let tokenURL: URL
        let detailURL: URL
        let downloadURL: URL

        static let quark = Configuration(
            site: .quark,
            sharePage: "https://pan.quark.cn/",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch",
            tokenURL: URL(string: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc")!,
            detailURL: URL(string: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc")!,
            downloadURL: URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2")!
        )

        static let uc = Configuration(
            site: .uc,
            sharePage: "https://drive.uc.cn/",
            userAgent: PanHTTP.chrome124UserAgent,
            tokenURL: URL(string: "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc")!,
            detailURL: URL(string: "https://pc-api.uc.cn/1/clouddrive/share/sharepage/v2/detail?pr=UCBrowser&fr=pc")!,
            downloadURL: URL(string: "https://pc-api.uc.cn/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser")!
        )
    }

    let http: PanHTTPClient

    func resolve(
        _ link: PanShareLink,
        configuration: Configuration,
        initialCookie: String?
    ) async throws -> PanResolution {
        let site = configuration.site
        var cookie = initialCookie ?? ""
        let tokenBody = try JSONEncoder().encode(QuarkTokenRequest(
            pwdID: link.code,
            passcode: link.passcode,
            supportVisitLimitPrivateShare: true
        ))
        let tokenResponse = try await send(
            configuration.tokenURL,
            method: "POST",
            headers: headers(configuration, cookie: cookie, jsonBody: true),
            body: tokenBody,
            configuration: configuration,
            cookie: &cookie
        )
        let token = try PanResponse.decode(QuarkTokenResponse.self, response: tokenResponse, site: site)
        try checkAPICODE(token.code, message: token.message, site: site)
        guard token.status == 200 else {
            throw PanError.remote(
                site: site.rawValue,
                message: token.message ?? "分享 token 请求失败",
                statusCode: tokenResponse.response.statusCode
            )
        }
        guard let stoken = token.data?.stoken.nilIfBlank else {
            throw PanError.invalidShare(site: site.rawValue, message: token.message ?? "分享未返回 stoken")
        }

        let detailQuery = [
            URLQueryItem(name: "pwd_id", value: link.code),
            URLQueryItem(name: "stoken", value: stoken),
            URLQueryItem(name: "pdir_fid", value: "0"),
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_banner", value: "0"),
            URLQueryItem(name: "_fetch_share", value: "0"),
            URLQueryItem(name: "fetch_relate_conversation", value: "0"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
        ]
        let detailResponse = try await send(
            configuration.detailURL,
            query: detailQuery,
            headers: headers(configuration, cookie: cookie, jsonBody: false),
            configuration: configuration,
            cookie: &cookie
        )
        let detail = try PanResponse.decode(QuarkListResponse.self, response: detailResponse, site: site)
        try checkAPICODE(detail.code, message: detail.message, site: site)
        if let status = detail.status, status != 200 {
            throw PanError.remote(
                site: site.rawValue,
                message: detail.message ?? "分享文件列表请求失败",
                statusCode: detailResponse.response.statusCode
            )
        }
        let items = (detail.data?.list ?? []).filter { $0.dir != true && !$0.fid.value.isEmpty }
        guard !items.isEmpty else { throw PanError.empty(site: site.rawValue) }

        var files: [PanFile] = []
        files.reserveCapacity(items.count)
        for item in items {
            let body = try JSONEncoder().encode(QuarkDownloadRequest(
                fids: [item.fid.value],
                fidsToken: [item.shareFidToken],
                pwdID: link.code,
                stoken: stoken,
                speedupSession: "",
                token: ""
            ))
            let response = try await send(
                configuration.downloadURL,
                method: "POST",
                headers: headers(configuration, cookie: cookie, jsonBody: true),
                body: body,
                configuration: configuration,
                cookie: &cookie
            )
            let download = try PanResponse.decode(QuarkDownloadResponse.self, response: response, site: site)
            try checkAPICODE(download.code, message: download.message, site: site)
            guard let url = download.data?.first?.downloadUrl.nilIfBlank else {
                throw PanError.remote(
                    site: site.rawValue,
                    message: download.message ?? "下载接口未返回直链",
                    statusCode: response.response.statusCode
                )
            }
            files.append(PanFile(
                name: item.fileName?.nilIfBlank ?? item.fid.value,
                url: url,
                size: PanByteFormatter.string(item.size),
                referer: configuration.sharePage,
                sizeBytes: item.size
            ))
        }
        let title = token.data?.title?.nilIfBlank
        return PanResolution(
            site: site.rawValue,
            note: title ?? "已解析 \(files.count) 个文件",
            files: files
        )
    }

    private func headers(
        _ configuration: Configuration,
        cookie: String,
        jsonBody: Bool
    ) -> [String: String] {
        var result = [
            "User-Agent": configuration.userAgent,
            "Accept": "application/json",
            "Origin": String(configuration.sharePage.dropLast()),
            "Referer": configuration.sharePage
        ]
        if !cookie.isEmpty { result["Cookie"] = cookie }
        if jsonBody { result["Content-Type"] = "application/json" }
        return result
    }

    private func send(
        _ url: URL,
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String],
        body: Data? = nil,
        configuration: Configuration,
        cookie: inout String
    ) async throws -> HTTPResponse {
        let request = try PanHTTP.request(url, method: method, query: query, headers: headers, body: body)
        let response = try await http.data(request, followsRedirects: false)
        if let pugs = Self.pugsCookie(from: response.response) { cookie = pugs }
        try PanResponse.validate(response, site: configuration.site)
        return response
    }

    static func pugsCookie(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, name.lowercased() == "set-cookie" else { continue }
            let values = value as? [String] ?? [String(describing: value)]
            for header in values {
                if let match = PanRegex.first(in: header, pattern: #"__pugs=([^;]*)"#) {
                    return "__pugs=\(match)"
                }
            }
        }
        return nil
    }

    private func checkAPICODE(_ code: Int?, message: String?, site: PanSite) throws {
        guard let code, code != 0 else { return }
        let text = message ?? "网盘接口返回错误 \(code)"
        switch code {
        case 41004, 41006:
            throw PanError.needPasscode(site: site.rawValue, message: text)
        case 23026:
            throw PanError.rateLimited(site: site.rawValue, message: text)
        case 31001:
            throw PanError.needLogin(site: site.rawValue, message: text)
        default:
            throw PanError.remote(site: site.rawValue, message: text, statusCode: nil)
        }
    }
}
