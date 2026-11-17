import Foundation
import XCTest
@testable import GalNook

final class PanTests: XCTestCase {
    func testAccountStoreUsesFixedKeysAndLogoutRemovesToken() {
        let memory = PanMemoryCredentials()
        let store = PanAccountStore(credentials: memory)
        XCTAssertEqual(
            PanAccountStore.accountKeys,
            ["quark", "uc", "baidu", "pan115", "pan123", "pan123.token", "xunlei", "caiyun", "guangya", "ilanzou"]
        )
        XCTAssertTrue(store.setCookie("quark-cookie", for: PanAccountStore.quark))
        XCTAssertTrue(store.setPan123AuthorToken("author-token"))
        XCTAssertEqual(store.cookie(for: PanAccountStore.quark), "quark-cookie")
        XCTAssertEqual(store.pan123AuthorToken, "author-token")
        XCTAssertFalse(store.setValue("unexpected", for: "unknown"))
        XCTAssertTrue(store.removeAccount(PanAccountStore.pan123))
        XCTAssertNil(memory.string(for: PanAccountStore.pan123))
        XCTAssertNil(memory.string(for: PanAccountStore.pan123Token))
    }

    func testShareCodeURLAndPasscodeExtraction() throws {
        let quark = try PanShareLink.parse(
            URL(string: "https://pan.quark.cn/s/Abc_-123?pwd=a1B2")!
        )
        XCTAssertEqual(quark, PanShareLink(site: .quark, code: "Abc_-123", passcode: "a1B2"))

        let uc = try PanShareLink.parse(
            URL(string: "https://drive.uc.cn/s/UC_code?pwd=9999")!,
            fallbackPasscode: "ignored"
        )
        XCTAssertEqual(uc.site, .uc)
        XCTAssertEqual(uc.code, "UC_code")
        XCTAssertEqual(uc.passcode, "9999")

        let baidu = try PanShareLink.parse(URL(string: "https://pan.baidu.com/s/1Short_url")!)
        XCTAssertEqual(baidu.code, "1Short_url")
        XCTAssertEqual(baidu.passcode, "")

        let one15 = try PanShareLink.parse(URL(string: "https://115.com/s/abc123?password=pw9")!)
        XCTAssertEqual(one15.site, .pan115)
        XCTAssertEqual(one15.passcode, "pw9")

        let one123 = try PanShareLink.parse(URL(string: "https://www.123865.com/s/a-b_c?password=pass8")!)
        XCTAssertEqual(one123.site, .pan123)
        XCTAssertEqual(one123.passcode, "pass8")

        let fallback = try PanShareLink.parse(
            URL(string: "https://pan.quark.cn/s/abc")!,
            fallbackPasscode: "from-resource"
        )
        XCTAssertEqual(fallback.passcode, "from-resource")
    }

    func testLanzouPathAndInvalidOrUnsupportedShares() throws {
        let lanzou = try PanShareLink.parse(URL(string: "https://www.lanzoui.com/iAbcd123")!)
        XCTAssertEqual(lanzou.site, .lanzou)
        XCTAssertEqual(lanzou.code, "iAbcd123")

        XCTAssertThrowsError(try PanShareLink.parse(URL(string: "https://pan.quark.cn/not-a-share")!)) { error in
            guard case .invalidShare(let site, _)? = error as? PanError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(site, PanSite.quark.rawValue)
        }
        for url in [
            URL(string: "https://pan.xunlei.com/share/abc")!,
            URL(string: "https://yun.139.com/share/abc")!,
            URL(string: "https://www.guangyapan.com/share/abc")!
        ] {
            XCTAssertThrowsError(try PanShareLink.parse(url)) { error in
                guard case .unsupportedProvider? = error as? PanError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertThrowsError(try PanShareLink.parse(URL(string: "https://example.com/s/abc")!)) { error in
            guard case .unsupportedProvider? = error as? PanError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testQuarkAndPan123RequestDTOEncoding() throws {
        let token = try jsonObject(JSONEncoder().encode(QuarkTokenRequest(
            pwdID: "share-id",
            passcode: "pwd",
            supportVisitLimitPrivateShare: true
        )))
        XCTAssertEqual(token["pwd_id"] as? String, "share-id")
        XCTAssertEqual(token["passcode"] as? String, "pwd")
        XCTAssertEqual(token["support_visit_limit_private_share"] as? Bool, true)
        XCTAssertNil(token["pwdID"])

        let quarkDownload = try jsonObject(JSONEncoder().encode(QuarkDownloadRequest(
            fids: ["fid"],
            fidsToken: ["fid-token"],
            pwdID: "share-id",
            stoken: "stoken",
            speedupSession: "",
            token: ""
        )))
        XCTAssertEqual(quarkDownload["fids"] as? [String], ["fid"])
        XCTAssertEqual(quarkDownload["fids_token"] as? [String], ["fid-token"])
        XCTAssertEqual(quarkDownload["pwd_id"] as? String, "share-id")
        XCTAssertEqual(quarkDownload["speedup_session"] as? String, "")
        XCTAssertEqual(quarkDownload["token"] as? String, "")

        let one123 = try jsonObject(JSONEncoder().encode(Pan123DownloadRequest(
            shareKey: "share-key",
            fileID: "123456789012",
            s3KeyFlag: "s3",
            size: 12345,
            etag: "etag"
        )))
        XCTAssertEqual(one123["ShareKey"] as? String, "share-key")
        XCTAssertEqual(one123["FileID"] as? String, "123456789012")
        XCTAssertEqual(one123["S3KeyFlag"] as? String, "s3")
        XCTAssertEqual(one123["Size"] as? Int, 12345)
        XCTAssertEqual(one123["Etag"] as? String, "etag")
        XCTAssertNil(one123["shareKey"])
        XCTAssertNil(one123["fileID"])
    }

    func testLooseIDsBaiduPageParametersAndFormBody() throws {
        let item = try JSONDecoder().decode(
            BaiduListItem.self,
            from: Data(#"{"isdir":0,"fs_id":123456789012,"size":1024,"server_filename":"game.zip"}"#.utf8)
        )
        XCTAssertEqual(item.isdir?.value, "0")
        XCTAssertEqual(item.fsId.value, "123456789012")
        let html = Data(#"{"timestamp":1700000000,"sign":"aB12","shareid":99,"uk":88}"#.utf8)
        XCTAssertEqual(
            BaiduPanClient.pageParameters(from: html),
            BaiduPageParameters(timestamp: "1700000000", sign: "aB12", shareID: "99", uk: "88")
        )
        let form = String(data: PanHTTP.formBody([
            ("pwd", "a b&"), ("vcode_str", ""), ("vcode", "")
        ]), encoding: .utf8)
        XCTAssertEqual(form, "pwd=a%20b%26&vcode_str=&vcode=")
    }

    func testPan123CRC32AndDeterministicSignature() {
        XCTAssertEqual(Pan123Signer.crc32Hex("123456789"), "cbf43926")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let list = Pan123Signer.signature(apiPath: "/b/api/share/get", now: now, random: 42)
        XCTAssertEqual(list.authKey, "3404595e")
        XCTAssertEqual(list.authValue, "1700000000-42-b5688fc4")
        let download = Pan123Signer.signature(apiPath: "/b/api/share/download/info", now: now, random: 42)
        XCTAssertEqual(download.authKey, "3404595e")
        XCTAssertEqual(download.authValue, "1700000000-42-d982125f")

        let headers = Pan123Signer.headers(
            apiPath: "/b/api/share/download/info",
            platform: "android",
            appVersion: "39",
            token: "secret-token",
            now: now,
            random: 42
        )
        XCTAssertEqual(headers["platform"], "android")
        XCTAssertEqual(headers["app-version"], "39")
        XCTAssertEqual(headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(headers["auth-value"], "1700000000-42-d982125f")
    }

    func testMissingCredentialsAndUnsupportedProvidersMakeNoRequests() async {
        let memory = PanMemoryCredentials()
        memory.setString("115-cookie-is-not-a-real-cookie", for: PanAccountStore.pan123)
        PanMockURLProtocol.reset { _ in
            XCTFail("A request was made despite missing credentials or an unsupported provider")
            return PanStub(body: Data())
        }
        let resolver = makeResolver(credentials: memory)
        await expectPanError {
            _ = try await resolver.resolve(shareURL: URL(string: "https://115.com/s/abc")!)
        } matches: {
            guard case .needLogin(let site, _) = $0 else { return false }
            return site == PanSite.pan115.rawValue
        }
        await expectPanError {
            _ = try await resolver.resolve(shareURL: URL(string: "https://www.123865.com/s/abc")!)
        } matches: {
            guard case .needLogin(let site, _) = $0 else { return false }
            return site == PanSite.pan123.rawValue
        }
        for url in [
            URL(string: "https://pan.xunlei.com/s/abc")!,
            URL(string: "https://caiyun.139.com/s/abc")!,
            URL(string: "https://www.guangyapan.com/s/abc")!
        ] {
            await expectPanError {
                _ = try await resolver.resolve(shareURL: url)
            } matches: {
                guard case .unsupportedProvider = $0 else { return false }
                return true
            }
        }
        XCTAssertTrue(PanMockURLProtocol.requestHistory().isEmpty)
    }

    func testQuarkThreeStepsTrackPugsAndReturnEveryFile() async throws {
        let memory = PanMemoryCredentials()
        memory.setString("__pus=test-login; other=old", for: PanAccountStore.quark)
        PanMockURLProtocol.reset { recorded in
            let request = recorded.request
            let path = request.url?.path ?? ""
            if path.hasSuffix("/token") {
                XCTAssertEqual(recorded.header("Cookie"), "__pus=test-login; other=old")
                XCTAssertEqual(recorded.header("Origin"), "https://pan.quark.cn")
                XCTAssertEqual(recorded.jsonBody()["pwd_id"] as? String, "share")
                return PanStub(
                    headers: ["Set-Cookie": "__pugs=one; Path=/; HttpOnly"],
                    body: Data(#"{"status":200,"code":0,"data":{"stoken":"stoken-value","title":"Two files"}}"#.utf8)
                )
            }
            if path.hasSuffix("/detail") {
                XCTAssertEqual(recorded.header("Cookie"), "__pugs=one")
                XCTAssertNil(recorded.header("Content-Type"))
                XCTAssertEqual(recorded.query("stoken"), "stoken-value")
                XCTAssertEqual(recorded.query("_size"), "100")
                return PanStub(
                    headers: ["Set-Cookie": "__pugs=two; Path=/"],
                    body: Data(#"{"status":200,"code":0,"data":{"list":[{"dir":true,"fid":"dir","share_fid_token":"skip"},{"dir":false,"fid":1,"share_fid_token":"token-1","file_name":"one.zip","size":1024},{"dir":false,"fid":"2","share_fid_token":"token-2","file_name":"two.zip","size":2048}]}}"#.utf8)
                )
            }
            if path.hasSuffix("/download") {
                let fids = recorded.jsonBody()["fids"] as? [String]
                if fids == ["1"] {
                    XCTAssertEqual(recorded.header("Cookie"), "__pugs=two")
                    return PanStub(
                        headers: ["Set-Cookie": "__pugs=three; Path=/"],
                        body: Data(#"{"code":0,"data":[{"download_url":"https://cdn.example.com/one.zip"}]}"#.utf8)
                    )
                }
                XCTAssertEqual(fids, ["2"])
                XCTAssertEqual(recorded.header("Cookie"), "__pugs=three")
                XCTAssertEqual(recorded.jsonBody()["fids_token"] as? [String], ["token-2"])
                return PanStub(body: Data(#"{"code":0,"data":[{"download_url":"https://cdn.example.com/two.zip"}]}"#.utf8))
            }
            XCTFail("Unexpected request: \(request.url?.absoluteString ?? "")")
            return PanStub(statusCode: 500, body: Data())
        }
        let result = try await makeResolver(credentials: memory).resolve(
            shareURL: URL(string: "https://pan.quark.cn/s/share?pwd=pw1")!
        )
        XCTAssertEqual(result.site, PanSite.quark.rawValue)
        XCTAssertEqual(result.note, "Two files")
        XCTAssertEqual(result.files.map(\.name), ["one.zip", "two.zip"])
        XCTAssertEqual(result.files.map(\.sizeBytes), [1024, 2048])
        XCTAssertEqual(result.files[0].size, "1.0 KB")
        XCTAssertEqual(result.files[0].referer, "https://pan.quark.cn/")
        XCTAssertEqual(result.files[0].resolvedDownload?.fileSize, 1024)
        XCTAssertEqual(result.files[0].resolvedDownload?.headers["Referer"], "https://pan.quark.cn/")
        XCTAssertNil(result.files[0].resolvedDownload?.headers["Cookie"])
        XCTAssertEqual(PanMockURLProtocol.requestHistory().count, 4)
    }

    func testQuarkErrorCodesMapToUserFlows() async {
        for (code, expected) in [(41004, "passcode"), (23026, "rate"), (31001, "login")] {
            PanMockURLProtocol.reset { _ in
                PanStub(body: Data("{\"status\":200,\"code\":\(code),\"message\":\"test error\"}".utf8))
            }
            let resolver = makeResolver()
            await expectPanError {
                _ = try await resolver.resolve(shareURL: URL(string: "https://drive.uc.cn/s/abc")!)
            } matches: { error in
                switch (expected, error) {
                case ("passcode", .needPasscode), ("rate", .rateLimited), ("login", .needLogin): true
                default: false
                }
            }
            XCTAssertEqual(PanMockURLProtocol.requestHistory().count, 1)
        }
    }

    func testUCUsesThreeStepV2DetailAndFTDownloadEndpoints() async throws {
        PanMockURLProtocol.reset { recorded in
            let url = recorded.request.url!
            XCTAssertEqual(recorded.header("Origin"), "https://drive.uc.cn")
            XCTAssertEqual(recorded.header("Referer"), "https://drive.uc.cn/")
            if url.path.hasSuffix("/token") {
                XCTAssertEqual(recorded.query("pr"), "UCBrowser")
                XCTAssertNil(recorded.header("Cookie"))
                return PanStub(body: Data(#"{"status":200,"code":0,"data":{"stoken":"uc-token"}}"#.utf8))
            }
            if url.path.hasSuffix("/v2/detail") {
                XCTAssertEqual(recorded.query("pr"), "UCBrowser")
                return PanStub(body: Data(#"{"status":200,"code":0,"data":{"list":[{"fid":"uc-file","share_fid_token":"uc-fid-token","file_name":"uc.zip","size":1}]}}"#.utf8))
            }
            if url.path.hasSuffix("/download") {
                XCTAssertEqual(recorded.query("entry"), "ft")
                XCTAssertEqual(recorded.query("pr"), "UCBrowser")
                return PanStub(body: Data(#"{"code":0,"data":[{"download_url":"https://cdn.example.com/uc.zip"}]}"#.utf8))
            }
            XCTFail("Unexpected UC request: \(url.absoluteString)")
            return PanStub(statusCode: 500, body: Data())
        }
        let result = try await makeResolver().resolve(shareURL: URL(string: "https://drive.uc.cn/s/uc-share")!)
        XCTAssertEqual(result.site, PanSite.uc.rawValue)
        XCTAssertEqual(result.files.map(\.name), ["uc.zip"])
        XCTAssertEqual(result.files[0].size, "1 B")
        XCTAssertEqual(PanMockURLProtocol.requestHistory().count, 3)
    }

    func testEmptyAndRemoteHTTPErrorMappings() async {
        PanMockURLProtocol.reset { recorded in
            if recorded.request.url?.path.hasSuffix("/token") == true {
                return PanStub(body: Data(#"{"status":200,"code":0,"data":{"stoken":"token"}}"#.utf8))
            }
            return PanStub(body: Data(#"{"status":200,"code":0,"data":{"list":[{"dir":true,"fid":"folder","share_fid_token":"token"}]}}"#.utf8))
        }
        await expectPanError {
            _ = try await makeResolver().resolve(shareURL: URL(string: "https://pan.quark.cn/s/empty")!)
        } matches: {
            guard case .empty(let site) = $0 else { return false }
            return site == PanSite.quark.rawValue
        }

        PanMockURLProtocol.reset { _ in
            PanStub(statusCode: 500, body: Data("offline stub failure".utf8))
        }
        await expectPanError {
            _ = try await makeResolver().resolve(shareURL: URL(string: "https://pan.quark.cn/s/failure")!)
        } matches: {
            guard case .remote(_, let message, let status) = $0 else { return false }
            return message == "offline stub failure" && status == 500
        }
    }

    func testBaiduVerifyRefreshesParametersThenListsAndDownloads() async throws {
        let memory = PanMemoryCredentials()
        memory.setString("BAIDUID=test-account-cookie", for: PanAccountStore.baidu)
        PanMockURLProtocol.reset { recorded in
            let request = recorded.request
            let url = request.url!
            if url.path == "/s/short" {
                if recorded.header("Cookie") == nil {
                    return PanStub(body: Data("<html>passcode required</html>".utf8))
                }
                XCTAssertEqual(recorded.header("Cookie"), "BDCLND=randsk%20value")
                return PanStub(body: Data(#"{"timestamp":1700000000,"sign":"aB12","shareid":99,"uk":88}"#.utf8))
            }
            if url.path == "/share/verify" {
                XCTAssertEqual(recorded.query("surl"), "short")
                XCTAssertEqual(recorded.header("Cookie"), "BAIDUID=test-account-cookie")
                XCTAssertEqual(recorded.bodyString(), "pwd=pw1&vcode_str=&vcode=")
                return PanStub(body: Data(#"{"errno":0,"randsk":"randsk value"}"#.utf8))
            }
            if url.path == "/rest/2.0/xpan/share" {
                XCTAssertEqual(recorded.header("Cookie"), "BAIDUID=test-account-cookie")
                XCTAssertEqual(recorded.query("dir"), "/")
                XCTAssertEqual(recorded.query("shorturl"), "short")
                return PanStub(body: Data(#"{"errno":0,"title":"Baidu files","list":[{"isdir":"1","fs_id":"7","server_filename":"folder"},{"isdir":0,"fs_id":123456,"size":2048,"server_filename":"game.zip"}]}"#.utf8))
            }
            if url.path == "/api/sharedownload" {
                XCTAssertEqual(recorded.query("fid_list"), "[123456]")
                XCTAssertEqual(recorded.query("sign"), "aB12")
                XCTAssertEqual(recorded.query("timestamp"), "1700000000")
                XCTAssertEqual(recorded.query("primaryid"), "99")
                XCTAssertEqual(recorded.query("uk"), "88")
                return PanStub(body: Data(#"{"errno":0,"list":[{"dlink":"https://cdn.example.com/baidu.zip"}]}"#.utf8))
            }
            XCTFail("Unexpected request: \(url.absoluteString)")
            return PanStub(statusCode: 500, body: Data())
        }
        let result = try await makeResolver(credentials: memory).resolve(
            shareURL: URL(string: "https://pan.baidu.com/s/short?pwd=pw1")!
        )
        XCTAssertEqual(result.note, "Baidu files")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].name, "game.zip")
        XCTAssertEqual(result.files[0].url, "https://cdn.example.com/baidu.zip")
        XCTAssertEqual(result.files[0].referer, "https://pan.baidu.com/")
        let history = PanMockURLProtocol.requestHistory()
        XCTAssertEqual(history.count, 5)
        XCTAssertNil(history[0].header("Cookie"))
        XCTAssertEqual(history[2].header("Cookie"), "BDCLND=randsk%20value")
    }

    func testBaiduErrnoMinusSixNeedsLogin() async {
        PanMockURLProtocol.reset { recorded in
            if recorded.request.url?.path == "/s/short" {
                return PanStub(body: Data(#"{"timestamp":1700000000,"sign":"aa","shareid":1,"uk":2}"#.utf8))
            }
            return PanStub(body: Data(#"{"errno":-6}"#.utf8))
        }
        await expectPanError {
            _ = try await makeResolver().resolve(shareURL: URL(string: "https://pan.baidu.com/s/short")!)
        } matches: {
            guard case .needLogin(let site, _) = $0 else { return false }
            return site == PanSite.baidu.rawValue
        }
    }

    func test115DynamicUAListAndSingleFileDownload() async throws {
        let memory = PanMemoryCredentials()
        memory.setString("UID=test;CID=test", for: PanAccountStore.pan115)
        PanMockURLProtocol.reset { recorded in
            let url = recorded.request.url!
            if url.host == "appversion.115.com" {
                XCTAssertEqual(recorded.header("User-Agent"), PanHTTP.galNookUserAgent)
                return PanStub(body: Data(#"{"data":{"win":{"version_code":"35.2.1"}}}"#.utf8))
            }
            XCTAssertEqual(recorded.header("User-Agent"), "Mozilla/5.0 115Browser/35.2.1")
            XCTAssertEqual(recorded.header("Cookie"), "UID=test;CID=test")
            XCTAssertEqual(recorded.header("Referer"), "https://115.com/s/share123?password=pw9")
            if url.path == "/share/snap" {
                XCTAssertEqual(recorded.query("receive_code"), "pw9")
                XCTAssertEqual(recorded.query("limit"), "100")
                return PanStub(body: Data(#"{"data":{"userinfo":{"user_id":42},"shareinfo":{"share_title":"115 files"},"list":[{"is_dir":1,"fid":"skip"},{"is_dir":0,"fid":123,"n":"original.zip","s":"4096"}]}}"#.utf8))
            }
            if url.path == "/share/downurl" {
                XCTAssertEqual(recorded.query("user_id"), "42")
                XCTAssertEqual(recorded.query("file_id"), "123")
                XCTAssertEqual(recorded.query("receive_code"), "pw9")
                return PanStub(body: Data(#"{"data":{"file_url_302":"https://cdn.example.com/115.zip","file_url":"https://ignored.example.com","fn":"renamed.zip"}}"#.utf8))
            }
            XCTFail("Unexpected request: \(url.absoluteString)")
            return PanStub(statusCode: 500, body: Data())
        }
        let result = try await makeResolver(credentials: memory).resolve(
            shareURL: URL(string: "https://115.com/s/share123?pwd=pw9")!
        )
        XCTAssertEqual(result.note, "115 files")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].name, "renamed.zip")
        XCTAssertEqual(result.files[0].url, "https://cdn.example.com/115.zip")
        XCTAssertEqual(result.files[0].sizeBytes, 4096)
    }

    func test123SignedListDownloadDTOAndEmbeddedURL() async throws {
        let memory = PanMemoryCredentials()
        memory.setString("test-author-token", for: PanAccountStore.pan123Token)
        let embedded = Data(#"{"url":"https://cdn.example.com/123.zip"}"#.utf8).base64EncodedString()
        let encoded = PanHTTP.formEncode(embedded)
        PanMockURLProtocol.reset { recorded in
            let url = recorded.request.url!
            XCTAssertEqual(recorded.header("Authorization"), "Bearer test-author-token")
            XCTAssertEqual(recorded.header("auth-key"), "3404595e")
            if url.path == "/b/api/share/get" {
                XCTAssertEqual(recorded.header("platform"), "web")
                XCTAssertEqual(recorded.header("app-version"), "3")
                XCTAssertEqual(recorded.header("auth-value"), "1700000000-42-b5688fc4")
                XCTAssertEqual(recorded.query("SharePwd"), "pw8")
                return PanStub(body: Data(#"{"code":0,"data":{"ShareName":"123 files","InfoList":[{"Type":1,"FileId":"skip"},{"Type":0,"FileId":123456789012,"S3KeyFlag":"s3","Size":12345,"Etag":"etag","FileName":"game.zip"}]}}"#.utf8))
            }
            if url.path == "/b/api/share/download/info" {
                XCTAssertEqual(recorded.header("platform"), "android")
                XCTAssertEqual(recorded.header("app-version"), "39")
                XCTAssertEqual(recorded.header("auth-value"), "1700000000-42-d982125f")
                XCTAssertEqual(recorded.jsonBody()["FileID"] as? String, "123456789012")
                XCTAssertEqual(recorded.jsonBody()["Size"] as? Int, 12345)
                return PanStub(body: Data("{\"code\":0,\"data\":{\"DownloadURL\":\"https://www.123865.com/download?params=\(encoded)&next=1\"}}".utf8))
            }
            XCTFail("Unexpected request: \(url.absoluteString)")
            return PanStub(statusCode: 500, body: Data())
        }
        let result = try await makeResolver(credentials: memory).resolve(
            shareURL: URL(string: "https://www.123865.com/s/share-key?pwd=pw8")!
        )
        XCTAssertEqual(result.note, "123 files")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].url, "https://cdn.example.com/123.zip")
        XCTAssertEqual(result.files[0].size, "12.1 KB")
        XCTAssertEqual(result.files[0].sizeBytes, 12345)
    }

    func testLanzouIframeFormAndFileName() async throws {
        PanMockURLProtocol.reset { recorded in
            let url = recorded.request.url!
            if url.path == "/iAbcd123" {
                XCTAssertNil(recorded.header("Cookie"))
                return PanStub(body: Data(#"<html><iframe src="/fn?frame=1"></iframe></html>"#.utf8))
            }
            if url.path == "/fn" {
                return PanStub(body: Data(#"<html><head><title>Game &amp; Patch.zip - 蓝奏云</title></head><script>var sign = 'a1B2'; var websignkey = 'key x'; var kd = '2'; var endpoint = 'ajaxm.php?file=123456';</script></html>"#.utf8))
            }
            if url.path == "/ajaxm.php" {
                XCTAssertEqual(recorded.query("file"), "123456")
                XCTAssertEqual(recorded.bodyString(), "action=downprocess&websign=&websignkey=key%20x&sign=a1B2&kd=2")
                XCTAssertEqual(recorded.header("Accept-Language"), "zh-CN,zh;q=0.9")
                return PanStub(body: Data(#"{"zt":1,"dom":"https://cdn.example.com","url":"download-id"}"#.utf8))
            }
            XCTFail("Unexpected request: \(url.absoluteString)")
            return PanStub(statusCode: 500, body: Data())
        }
        let result = try await makeResolver().resolve(
            shareURL: URL(string: "https://www.lanzoui.com/iAbcd123")!
        )
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].name, "Game & Patch.zip")
        XCTAssertEqual(result.files[0].url, "https://cdn.example.com/file/download-id")
        XCTAssertEqual(result.files[0].size, "")
    }

    func testILanzouDoesNotRequireZTAndAdapterReturnsResolvedDownload() async throws {
        PanMockURLProtocol.reset { recorded in
            if recorded.request.url?.path == "/s/abc" {
                return PanStub(body: Data(#"<title>ilanzou.zip - 蓝奏优享版</title><script>var endpoint='ajaxm.php?file=654321';</script>"#.utf8))
            }
            XCTAssertEqual(recorded.bodyString(), "action=downprocess&websign=&websignkey=&sign=&kd=1")
            XCTAssertNil(recorded.header("Cookie"))
            return PanStub(body: Data(#"{"zt":0,"dom":"https://cdn.example.com","url":"ilanzou-id"}"#.utf8))
        }
        let resolver = makeResolver()
        let resource = GameResource(
            title: "Test",
            sourceName: "Tests",
            shareURL: URL(string: "https://www.ilanzou.com/s/abc")!
        )
        let resolution = try await resolver.resolve(resource)
        XCTAssertEqual(resolution.files[0].url, "https://cdn.example.com/file/ilanzou-id")
        let adapted = try await PanDownloadResolverAdapter(resolver: resolver).resolve(resource)
        XCTAssertEqual(adapted.url.absoluteString, "https://cdn.example.com/file/ilanzou-id")
        XCTAssertEqual(adapted.fileName, "ilanzou.zip")
        XCTAssertEqual(adapted.headers["User-Agent"], PanHTTP.desktopUserAgent)
        XCTAssertEqual(adapted.headers["Referer"], "https://www.ilanzou.com/s/abc")
        XCTAssertNil(adapted.headers["Cookie"])
    }

    private func makeResolver(credentials: PanCredentialStoring = PanMemoryCredentials()) -> PanResolverActor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PanMockURLProtocol.self]
        return PanResolverActor(
            accountStore: PanAccountStore(credentials: credentials),
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            random: { 42 }
        )
    }
}

private struct PanStub: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data
}

private struct PanRecordedRequest: @unchecked Sendable {
    let request: URLRequest
    let body: Data

    func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }

    func query(_ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    func bodyString() -> String { String(data: body, encoding: .utf8) ?? "" }

    func jsonBody() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

private final class PanMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (PanRecordedRequest) -> PanStub
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var history: [PanRecordedRequest] = []

    static func reset(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        history = []
        lock.unlock()
    }

    static func requestHistory() -> [PanRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = PanRecordedRequest(request: request, body: Self.readBody(from: request))
        let stub = Self.respond(recorded)
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func respond(_ request: PanRecordedRequest) -> PanStub {
        lock.lock()
        let handler = self.handler
        history.append(request)
        lock.unlock()
        return handler?(request) ?? PanStub(statusCode: 500, body: Data())
    }

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16_384)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 16_384)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class PanMemoryCredentials: PanCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    @discardableResult
    func setString(_ value: String?, for account: String) -> Bool {
        lock.lock()
        values[account] = value
        if value == nil { values.removeValue(forKey: account) }
        lock.unlock()
        return true
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func expectPanError(
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void,
    matches: (PanError) -> Bool
) async {
    do {
        try await operation()
        XCTFail("Expected PanError", file: file, line: line)
    } catch let error as PanError {
        XCTAssertTrue(matches(error), "Unexpected PanError: \(error)", file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
