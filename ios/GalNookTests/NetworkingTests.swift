import XCTest
@testable import GalNook

final class NetworkingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "only_searchgal")
    }

    func testJSONValueRejectsUnsafeIntegerConversion() throws {
        let value = JSONValue.number(1e300)
        XCTAssertNil(value.int)
        XCTAssertNil(value.int64)
        XCTAssertNotNil(value.string)
        XCTAssertEqual(JSONValue.number(42).int, 42)
        XCTAssertEqual(JSONValue.string("7").int, 7)
    }

    func testSearchGalFormAndSSEMapping() async throws {
        let sse = """
        data: {"total":2}

        data: {"result":{"name":"站点A","tags":["KrKr"],"items":[{"name":"游戏.zip","url":"https://files.example.com/game.zip"},{"name":"重复","url":"https://files.example.com/game.zip"},{"name":"安卓.apk","url":"https://files.example.com/game.apk"}]}}
        """
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/gal")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
            let body = request.httpBodyString
            XCTAssertTrue(body.contains("game=CLANNAD"))
            return (200, ["Content-Type": "text/event-stream"], Data(sse.utf8))
        }
        let client = SearchGalResourceClient(
            session: ProtocolStub.session(),
            baseProvider: { URL(string: "https://search.example.com")! }
        )
        let work = WorkSummary(source: .nextMoe, sourceID: "1", title: "CLANNAD")
        let resources = try await client.resources(for: work)
        XCTAssertEqual(resources.count, 2)
        XCTAssertEqual(resources[0].provider, .direct)
        XCTAssertEqual(resources[0].engine, .kirikiri)
        XCTAssertFalse(resources[0].isAndroidPackage)
        XCTAssertTrue(resources[1].isAndroidPackage)
    }

    func testSearchGalDrivePageIsNotTreatedAsArchive() async throws {
        let sse = """
        data: {"result":{"name":"资源站","tags":["NoReq","SuDrive"],"items":[{"name":"游戏.rar","url":"https://resource.example.com/files/game.rar"}]}}
        """
        ProtocolStub.handler = { _ in (200, ["Content-Type": "text/event-stream"], Data(sse.utf8)) }
        let client = SearchGalResourceClient(
            session: ProtocolStub.session(),
            baseProvider: { URL(string: "https://search.example.com")! }
        )
        let resources = try await client.resources(for: WorkSummary(source: .nextMoe, sourceID: "1", title: "游戏"))
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources[0].provider, .other)
        XCTAssertNil(resources[0].directURL)
        XCTAssertNotNil(resources[0].pageURL)
    }

    func testNextMoeSummaryMapping() async throws {
        let body = """
        {"items":[{"id":"248408","display_name":"原名","localized":{"zh-Hans":{"value":"中文名"}},"release_date":"2019-07-09","cover":{"url":"https://img.example.com/cover.webp"},"companies":[{"display_name":"会社"}],"ratings":[{"source":"vndb","score":87.3,"vote_count":11603}]}],"next_cursor":null}
        """
        ProtocolStub.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("include=titles") == true)
            return (200, [:], Data(body.utf8))
        }
        let client = NextMoeClient(api: APIClient(session: ProtocolStub.session()))
        let page = try await client.works(query: .search("原名"), page: 1, limit: 20, includeAdult: false)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].title, "中文名")
        XCTAssertEqual(page.items[0].rating ?? 0, 8.73, accuracy: 0.001)
        XCTAssertEqual(page.items[0].ratingCount, 11603)
    }

    func testVNDBRatingUsesTenPointScale() async throws {
        let body = """
        {"more":false,"results":[{"id":"v4","title":"CLANNAD","developers":[{"name":"Key"}],"image":{"url":"https://img.example.com/v4.jpg"},"rating":87.3,"released":"2004-04-28","votecount":11603,"titles":[]}]}
        """
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/kana/vn")
            return (200, [:], Data(body.utf8))
        }
        let client = VNDBClient(api: APIClient(session: ProtocolStub.session()))
        let page = try await client.works(query: .search("clannad"), page: 1, limit: 1, includeAdult: false)
        XCTAssertEqual(page.items[0].rating ?? 0, 8.73, accuracy: 0.001)
    }
}

private final class ProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolStub.self]
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }
}

private extension URLRequest {
    var httpBodyString: String {
        if let httpBody, let text = String(data: httpBody, encoding: .utf8) { return text }
        if let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
}
