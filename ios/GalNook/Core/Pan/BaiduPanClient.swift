import Foundation

struct BaiduVerifyResponse: Decodable {
    let errno: Int
    let randsk: String?
}

struct BaiduListResponse: Decodable {
    let errno: Int
    let title: String?
    let list: [BaiduListItem]?
}

struct BaiduListItem: Decodable {
    let isdir: PanLooseString?
    let fsId: PanLooseString
    let size: Int64?
    let serverFilename: String?

    enum CodingKeys: String, CodingKey {
        case isdir, size
        case fsId = "fs_id"
        case serverFilename = "server_filename"
    }
}

struct BaiduDownloadResponse: Decodable {
    let errno: Int
    let dlink: String?
    let list: [BaiduDownloadItem]?
}

struct BaiduDownloadItem: Decodable { let dlink: String? }

struct BaiduPageParameters: Equatable {
    let timestamp: String
    let sign: String
    let shareID: String
    let uk: String
}

struct BaiduPanClient: Sendable {
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    let http: PanHTTPClient

    func resolve(_ link: PanShareLink, accountCookie: String?) async throws -> PanResolution {
        let site = PanSite.baidu
        let shareURL = URL(string: "https://pan.baidu.com/s/\(link.code)")!
        let initial = try await getSharePage(shareURL, cookie: nil)
        var parameters = Self.pageParameters(from: initial.data)
        if parameters == nil {
            guard !link.passcode.isEmpty else {
                throw PanError.needPasscode(
                    site: site.rawValue,
                    message: "分享需要提取码，或分享页参数无法识别"
                )
            }
            let verifyURL = URL(string: "https://pan.baidu.com/share/verify")!
            var headers = baseHeaders(referer: shareURL.absoluteString)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            if let accountCookie, !accountCookie.isEmpty { headers["Cookie"] = accountCookie }
            let body = PanHTTP.formBody([
                ("pwd", link.passcode), ("vcode_str", ""), ("vcode", "")
            ])
            let request = try PanHTTP.request(
                verifyURL,
                method: "POST",
                query: [URLQueryItem(name: "surl", value: link.code)],
                headers: headers,
                body: body
            )
            let response = try await http.data(request)
            try PanResponse.validate(response, site: site)
            let verify = try PanResponse.decode(BaiduVerifyResponse.self, response: response, site: site)
            try Self.checkErrno(verify.errno, site: site, message: "提取码验证失败")
            guard let randsk = verify.randsk?.nilIfBlank else {
                throw PanError.needPasscode(site: site.rawValue, message: "提取码验证未返回 randsk")
            }
            let refreshed = try await getSharePage(
                shareURL,
                cookie: "BDCLND=\(PanHTTP.formEncode(randsk))"
            )
            parameters = Self.pageParameters(from: refreshed.data)
        }
        guard let parameters else {
            throw PanError.invalidShare(site: site.rawValue, message: "分享页缺少 sign、timestamp、shareid 或 uk")
        }

        let listURL = URL(string: "https://pan.baidu.com/rest/2.0/xpan/share")!
        let listRequest = try PanHTTP.request(
            listURL,
            query: [
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "shorturl", value: link.code),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "num", value: "100"),
                URLQueryItem(name: "root", value: "1"),
                URLQueryItem(name: "dir", value: "/")
            ],
            headers: authorizedHeaders(referer: shareURL.absoluteString, cookie: accountCookie)
        )
        let listResponse = try await http.data(listRequest)
        try PanResponse.validate(listResponse, site: site)
        let list = try PanResponse.decode(BaiduListResponse.self, response: listResponse, site: site)
        try Self.checkErrno(list.errno, site: site, message: "获取百度分享列表失败")
        let items = (list.list ?? []).filter { $0.isdir?.value != "1" && !$0.fsId.value.isEmpty }
        guard !items.isEmpty else { throw PanError.empty(site: site.rawValue) }

        var files: [PanFile] = []
        files.reserveCapacity(items.count)
        for item in items {
            guard let fsID = Int64(item.fsId.value),
                  let idData = try? JSONSerialization.data(withJSONObject: [fsID]),
                  let idList = String(data: idData, encoding: .utf8) else {
                throw PanError.remote(
                    site: site.rawValue,
                    message: "百度文件 fs_id 无法组成 fid_list",
                    statusCode: nil
                )
            }
            let request = try PanHTTP.request(
                URL(string: "https://pan.baidu.com/api/sharedownload")!,
                query: [
                    URLQueryItem(name: "sign", value: parameters.sign),
                    URLQueryItem(name: "timestamp", value: parameters.timestamp),
                    URLQueryItem(name: "fid_list", value: idList),
                    URLQueryItem(name: "uk", value: parameters.uk),
                    URLQueryItem(name: "primaryid", value: parameters.shareID),
                    URLQueryItem(name: "channel", value: "chunlei"),
                    URLQueryItem(name: "web", value: "1"),
                    URLQueryItem(name: "app_id", value: "250528"),
                    URLQueryItem(name: "clienttype", value: "0")
                ],
                headers: authorizedHeaders(referer: shareURL.absoluteString, cookie: accountCookie)
            )
            let response = try await http.data(request)
            try PanResponse.validate(response, site: site)
            let download = try PanResponse.decode(BaiduDownloadResponse.self, response: response, site: site)
            try Self.checkErrno(download.errno, site: site, message: "获取百度下载地址失败")
            guard let url = download.dlink?.nilIfBlank ?? download.list?.first?.dlink?.nilIfBlank else {
                throw PanError.remote(site: site.rawValue, message: "百度下载响应缺少 dlink", statusCode: nil)
            }
            files.append(PanFile(
                name: item.serverFilename?.nilIfBlank ?? item.fsId.value,
                url: url,
                size: PanByteFormatter.string(item.size),
                referer: "https://pan.baidu.com/",
                sizeBytes: item.size
            ))
        }
        return PanResolution(
            site: site.rawValue,
            note: list.title?.nilIfBlank ?? "已解析 \(files.count) 个文件",
            files: files
        )
    }

    static func pageParameters(from data: Data) -> BaiduPageParameters? {
        guard let html = String(data: data, encoding: .utf8),
              let timestamp = PanRegex.first(in: html, pattern: #""timestamp"\s*:\s*(\d{9,})"#),
              let sign = PanRegex.first(in: html, pattern: #""sign"\s*:\s*"([0-9a-fA-F]+)""#),
              let shareID = PanRegex.first(in: html, pattern: #""shareid"\s*:\s*(\d+)"#),
              let uk = PanRegex.first(in: html, pattern: #""uk"\s*:\s*(\d+)"#) else { return nil }
        return BaiduPageParameters(timestamp: timestamp, sign: sign, shareID: shareID, uk: uk)
    }

    private func getSharePage(_ url: URL, cookie: String?) async throws -> HTTPResponse {
        var headers = baseHeaders(referer: "https://pan.baidu.com/")
        if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        let response = try await http.data(PanHTTP.request(url, headers: headers))
        try PanResponse.validate(response, site: .baidu)
        return response
    }

    private func baseHeaders(referer: String) -> [String: String] {
        ["User-Agent": Self.userAgent, "Referer": referer]
    }

    private func authorizedHeaders(referer: String, cookie: String?) -> [String: String] {
        var headers = baseHeaders(referer: referer)
        if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    private static func checkErrno(_ errno: Int, site: PanSite, message: String) throws {
        guard errno != 0 else { return }
        switch errno {
        case -6:
            throw PanError.needLogin(site: site.rawValue, message: "百度网盘要求登录（errno=-6）")
        case -12, -9:
            throw PanError.needPasscode(site: site.rawValue, message: "\(message)（errno=\(errno)）")
        default:
            throw PanError.remote(site: site.rawValue, message: "\(message)（errno=\(errno)）", statusCode: nil)
        }
    }
}
