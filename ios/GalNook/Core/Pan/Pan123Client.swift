import Foundation

struct Pan123ShareResponse: Decodable {
    let code: Int
    let message: String?
    let data: Pan123ShareData?
}

struct Pan123ShareData: Decodable {
    let shareName: String?
    let infoList: [Pan123File]?

    enum CodingKeys: String, CodingKey {
        case shareName = "ShareName"
        case infoList = "InfoList"
    }
}

struct Pan123File: Decodable {
    let type: Int?
    let fileId: PanLooseString
    let s3KeyFlag: String?
    let size: Int64?
    let etag: String?
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case fileId = "FileId"
        case s3KeyFlag = "S3KeyFlag"
        case size = "Size"
        case etag = "Etag"
        case fileName = "FileName"
    }
}

struct Pan123DownloadRequest: Encodable {
    let shareKey: String
    let fileID: String
    let s3KeyFlag: String
    let size: Int64
    let etag: String

    enum CodingKeys: String, CodingKey {
        case shareKey = "ShareKey"
        case fileID = "FileID"
        case s3KeyFlag = "S3KeyFlag"
        case size = "Size"
        case etag = "Etag"
    }
}

struct Pan123DownloadResponse: Decodable {
    let code: Int?
    let message: String?
    let data: Pan123DownloadData?
}

struct Pan123DownloadData: Decodable {
    let downloadURL: String?
    enum CodingKeys: String, CodingKey { case downloadURL = "DownloadURL" }
}

private struct Pan123EmbeddedURL: Decodable {
    let url: String?
    let downloadUrl: String?
}

struct Pan123Signature: Equatable {
    let authKey: String
    let authValue: String
}

enum Pan123Signer {
    static let alphabet = "adefghlmyijnopkqrstubcvwsz"

    static func signature(
        apiPath: String,
        now: Date,
        random: Int
    ) -> Pan123Signature {
        let epoch = Int64(now.timeIntervalSince1970.rounded(.down))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm"
        let expiry = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch + 3_600)))
        let mapped = expiry.map { character -> Character in
            let digit = character.wholeNumberValue ?? 0
            return alphabet[alphabet.index(alphabet.startIndex, offsetBy: digit)]
        }
        let authKey = crc32Hex(String(mapped))
        let source = "\(epoch)|\(random)|\(apiPath)|web|3|\(authKey)"
        return Pan123Signature(authKey: authKey, authValue: "\(epoch)-\(random)-\(crc32Hex(source))")
    }

    static func headers(
        apiPath: String,
        platform: String,
        appVersion: String,
        token: String,
        now: Date,
        random: Int
    ) -> [String: String] {
        let signature = signature(apiPath: apiPath, now: now, random: random)
        return [
            "User-Agent": PanHTTP.desktopUserAgent,
            "Referer": "https://yun.123pan.cn/",
            "Origin": "https://yun.123pan.cn",
            "platform": platform,
            "app-version": appVersion,
            "auth-key": signature.authKey,
            "auth-value": signature.authValue,
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    static func crc32Hex(_ text: String) -> String {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in Array(text.utf8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return String(crc ^ 0xFFFF_FFFF, radix: 16, uppercase: false)
    }
}

struct Pan123Client: Sendable {
    let http: PanHTTPClient
    let now: @Sendable () -> Date
    let random: @Sendable () -> Int

    func resolve(_ link: PanShareLink, token: String?) async throws -> PanResolution {
        let site = PanSite.pan123
        guard let token = token?.nilIfBlank else {
            throw PanError.needLogin(site: site.rawValue, message: "123 云盘需要 authorToken")
        }
        var query = [URLQueryItem(name: "shareKey", value: link.code)]
        if !link.passcode.isEmpty { query.append(URLQueryItem(name: "SharePwd", value: link.passcode)) }
        let listPath = "/b/api/share/get"
        let listRequest = try PanHTTP.request(
            URL(string: "https://yun.123pan.cn\(listPath)")!,
            query: query,
            headers: Pan123Signer.headers(
                apiPath: listPath,
                platform: "web",
                appVersion: "3",
                token: token,
                now: now(),
                random: random()
            )
        )
        let listResponse = try await http.data(listRequest)
        try PanResponse.validate(listResponse, site: site)
        let list = try PanResponse.decode(Pan123ShareResponse.self, response: listResponse, site: site)
        try Self.checkCode(list.code, message: list.message, site: site)
        let items = (list.data?.infoList ?? []).filter { $0.type != 1 && !$0.fileId.value.isEmpty }
        guard !items.isEmpty else { throw PanError.empty(site: site.rawValue) }

        var files: [PanFile] = []
        files.reserveCapacity(items.count)
        let downloadPath = "/b/api/share/download/info"
        for item in items {
            let body = try JSONEncoder().encode(Pan123DownloadRequest(
                shareKey: link.code,
                fileID: item.fileId.value,
                s3KeyFlag: item.s3KeyFlag ?? "",
                size: item.size ?? 0,
                etag: item.etag ?? ""
            ))
            let request = try PanHTTP.request(
                URL(string: "https://www.123865.com\(downloadPath)")!,
                method: "POST",
                headers: Pan123Signer.headers(
                    apiPath: downloadPath,
                    platform: "android",
                    appVersion: "39",
                    token: token,
                    now: now(),
                    random: random()
                ),
                body: body
            )
            let response = try await http.data(request)
            try PanResponse.validate(response, site: site)
            let download = try PanResponse.decode(Pan123DownloadResponse.self, response: response, site: site)
            if let code = download.code { try Self.checkCode(code, message: download.message, site: site) }
            guard let rawURL = download.data?.downloadURL?.nilIfBlank else {
                throw PanError.remote(site: site.rawValue, message: "123 下载响应缺少 DownloadURL", statusCode: nil)
            }
            let url = try Self.unwrapDownloadURL(rawURL)
            files.append(PanFile(
                name: item.fileName?.nilIfBlank ?? item.fileId.value,
                url: url,
                size: PanByteFormatter.string(item.size),
                referer: "https://yun.123pan.cn/",
                sizeBytes: item.size
            ))
        }
        return PanResolution(
            site: site.rawValue,
            note: list.data?.shareName?.nilIfBlank ?? "已解析 \(files.count) 个文件",
            files: files
        )
    }

    static func unwrapDownloadURL(_ raw: String) throws -> String {
        guard let paramsRange = raw.range(of: "params=") else { return raw }
        let tail = raw[paramsRange.upperBound...]
        let encoded = tail.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let base64 = encoded.removingPercentEncoding,
              let data = Data(base64Encoded: base64),
              let embedded = try? JSONDecoder().decode(Pan123EmbeddedURL.self, from: data),
              let result = embedded.url?.nilIfBlank ?? embedded.downloadUrl?.nilIfBlank else {
            throw PanError.remote(site: PanSite.pan123.rawValue, message: "123 params 下载参数解码失败", statusCode: nil)
        }
        return result
    }

    private static func checkCode(_ code: Int, message: String?, site: PanSite) throws {
        guard code != 0 else { return }
        let text = message ?? "123 云盘接口返回错误 \(code)"
        switch code {
        case 401, 403:
            throw PanError.needLogin(site: site.rawValue, message: text)
        case 429:
            throw PanError.rateLimited(site: site.rawValue, message: text)
        default:
            throw PanError.remote(site: site.rawValue, message: text, statusCode: nil)
        }
    }
}
