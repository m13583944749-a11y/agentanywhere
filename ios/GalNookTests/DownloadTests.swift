import Foundation
import XCTest
@testable import GalNook

@MainActor
final class DownloadTests: XCTestCase {
    func testPauseResumeUsesRangeAndETagAndPreservesBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(160 * 1024)).map { UInt8($0 % 251) })
        let firstChunk = body.prefix(64 * 1024)

        MockURLProtocol.reset { request in
            if let offset = rangeOffset(in: request) {
                let remaining = body.subdata(in: Int(offset)..<body.count)
                return StubResponse(
                    statusCode: 206,
                    headers: [
                        "Content-Length": String(remaining.count),
                        "Content-Range": "bytes \(offset)-\(body.count - 1)/\(body.count)",
                        "ETag": "\"v1\""
                    ],
                    chunks: [remaining]
                )
            }
            return StubResponse(
                headers: [
                    "Content-Length": String(body.count),
                    "ETag": "\"v1\""
                ],
                chunks: [Data(firstChunk), body.suffix(body.count - firstChunk.count)],
                chunkDelay: 100_000_000
            )
        }
        let manager = makeManager(
            root: root,
            settings: DownloadSettings(maximumConcurrent: 1, maximumRetries: 0)
        )
        let id = manager.enqueue(resource(fileName: "game.zip", path: "/pause.zip"))

        try await waitUntil { manager.task(id: id)?.downloadedBytes ?? 0 >= 64 * 1024 }
        XCTAssertNotNil(manager.task(id: id)?.remainingSeconds)
        manager.pause(id: id)
        XCTAssertEqual(manager.task(id: id)?.state, .paused)
        XCTAssertEqual(manager.task(id: id)?.bytesPerSecond, 0)

        let partialURL = partialFile(root: root, id: id)
        let partialSize = DownloadFileSupport.fileSize(partialURL)
        XCTAssertGreaterThanOrEqual(partialSize, 64 * 1024)
        XCTAssertLessThan(partialSize, Int64(body.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))

        manager.resume(id: id)
        try await waitUntil { manager.task(id: id)?.state == .completed }
        let requests = MockURLProtocol.requestHistory()
        XCTAssertEqual(requests.count, 2)
        guard requests.count > 1 else { return }
        let requestedOffset = rangeOffset(in: requests[1])
        XCTAssertGreaterThanOrEqual(requestedOffset ?? 0, partialSize)
        XCTAssertLessThan(requestedOffset ?? Int64(body.count), Int64(body.count))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(try completedData(manager: manager, id: id, root: root), body)
        XCTAssertEqual(manager.task(id: id)?.progress, 1)
        XCTAssertGreaterThan(manager.task(id: id)?.bytesPerSecond ?? 0, 0)
    }

    func testAutomaticRetryResumesFailedRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(96 * 1024)).map { UInt8($0 % 239) })
        let firstChunk = Data(body.prefix(64 * 1024))

        MockURLProtocol.reset { request in
            if let offset = rangeOffset(in: request) {
                let remaining = body.subdata(in: Int(offset)..<body.count)
                return StubResponse(
                    statusCode: 206,
                    headers: [
                        "Content-Length": String(remaining.count),
                        "Content-Range": "bytes \(offset)-\(body.count - 1)/\(body.count)",
                        "ETag": "\"retry-v1\""
                    ],
                    chunks: [remaining]
                )
            }
            return StubResponse(
                headers: [
                    "Content-Length": String(body.count),
                    "ETag": "\"retry-v1\""
                ],
                chunks: [firstChunk],
                terminalError: URLError(.networkConnectionLost)
            )
        }
        let manager = makeManager(
            root: root,
            settings: DownloadSettings(maximumConcurrent: 1, maximumRetries: 1)
        )
        let id = manager.enqueue(resource(fileName: "retry.zip", path: "/retry.zip"))

        try await waitUntil(timeout: 6) { manager.task(id: id)?.state == .completed }
        XCTAssertEqual(manager.task(id: id)?.retryCount, 1)
        let requests = MockURLProtocol.requestHistory()
        XCTAssertEqual(requests.count, 2)
        guard requests.count > 1 else { return }
        XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try completedData(manager: manager, id: id, root: root), body)
    }

    func testRetryWithHTTP200TruncatesPartialAndUsesLastModifiedIfRange() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(96 * 1024)).map { UInt8(255 - ($0 % 239)) })
        let firstChunk = Data(body.prefix(64 * 1024))
        let lastModified = "Wed, 18 Nov 2026 00:00:00 GMT"

        MockURLProtocol.reset { request in
            if rangeOffset(in: request) == nil {
                return StubResponse(
                    headers: [
                        "Content-Length": String(body.count),
                        "Last-Modified": lastModified
                    ],
                    chunks: [firstChunk],
                    terminalError: URLError(.networkConnectionLost)
                )
            }
            return StubResponse(
                headers: [
                    "Content-Length": String(body.count),
                    "Last-Modified": lastModified
                ],
                chunks: [body]
            )
        }
        let manager = makeManager(
            root: root,
            settings: DownloadSettings(maximumConcurrent: 1, maximumRetries: 0)
        )
        let id = manager.enqueue(resource(fileName: "restart.zip", path: "/restart.zip"))
        try await waitUntil { manager.task(id: id)?.state == .failed }
        XCTAssertEqual(DownloadFileSupport.fileSize(partialFile(root: root, id: id)), 64 * 1024)

        manager.retry(id: id)
        try await waitUntil { manager.task(id: id)?.state == .completed }
        let requests = MockURLProtocol.requestHistory()
        XCTAssertEqual(requests.count, 2)
        guard requests.count > 1 else { return }
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"), lastModified)
        XCTAssertEqual(try completedData(manager: manager, id: id, root: root), body)
    }

    func testQueueConcurrencySafeNamesAndConflictRenaming() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(repeating: 7, count: 80 * 1024)
        MockURLProtocol.reset { _ in
            StubResponse(
                headers: ["Content-Length": String(body.count)],
                chunks: [body],
                chunkDelay: 100_000_000
            )
        }
        let manager = makeManager(
            root: root,
            settings: DownloadSettings(maximumConcurrent: 2, maximumRetries: 0)
        )
        let ids = (0..<3).map { index in
            manager.enqueue(resource(fileName: "../../evil.zip", path: "/\(index).zip"))
        }

        var maximumObserved = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !ids.allSatisfy({ manager.task(id: $0)?.state == .completed }) {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for queued downloads: \(manager.tasks)")
                return
            }
            let active = manager.tasks.filter {
                $0.state == .resolving || $0.state == .downloading
            }.count
            maximumObserved = max(maximumObserved, active)
            if ids.contains(where: { manager.task(id: $0)?.state == .failed }) {
                XCTFail("Unexpected failure: \(manager.tasks)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertLessThanOrEqual(maximumObserved, 2)
        XCTAssertEqual(maximumObserved, 2)
        let names = Set(ids.compactMap { manager.task(id: $0)?.relativePath })
        XCTAssertEqual(names, Set(["evil.zip", "evil 2.zip", "evil 3.zip"]))
        for id in ids {
            XCTAssertEqual(try completedData(manager: manager, id: id, root: root), body)
            XCTAssertEqual(manager.task(id: id)?.progress, 1)
        }
        XCTAssertTrue(ids.allSatisfy { manager.task(id: $0)?.fileName.hasPrefix("..") == false })

        let removedURL = try XCTUnwrap(manager.fileURL(for: ids[0]))
        manager.remove(id: ids[0])
        XCTAssertNil(manager.task(id: ids[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedURL.path))
        let remainingURLs = ids.dropFirst().compactMap { manager.fileURL(for: $0) }
        manager.clearFinished()
        XCTAssertTrue(ids.allSatisfy { manager.task(id: $0) == nil })
        XCTAssertTrue(remainingURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testCancelRemovesPartialAndManualRetryStartsCleanly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(repeating: 11, count: 160 * 1024)
        let firstChunk = Data(body.prefix(64 * 1024))
        MockURLProtocol.reset { _ in
            StubResponse(
                headers: ["Content-Length": String(body.count)],
                chunks: [firstChunk, body.suffix(body.count - firstChunk.count)],
                chunkDelay: 100_000_000
            )
        }
        let manager = makeManager(
            root: root,
            settings: DownloadSettings(maximumConcurrent: 1, maximumRetries: 0)
        )
        let id = manager.enqueue(resource(fileName: "cancel.zip", path: "/cancel.zip"))
        try await waitUntil { manager.task(id: id)?.downloadedBytes ?? 0 >= 64 * 1024 }
        manager.cancel(id: id)

        try await waitUntil {
            !FileManager.default.fileExists(atPath: partialFile(root: root, id: id).path)
        }
        XCTAssertEqual(manager.task(id: id)?.state, .cancelled)
        XCTAssertEqual(manager.task(id: id)?.downloadedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFile(root: root, id: id).path))

        manager.retry(id: id)
        try await waitUntil { manager.task(id: id)?.state == .completed }
        XCTAssertNil(MockURLProtocol.requestHistory().last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try completedData(manager: manager, id: id, root: root), body)
    }

    func testRegisteredResolverSupportsResourceWithoutDirectURL() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data("resolved".utf8)
        MockURLProtocol.reset { _ in
            StubResponse(headers: ["Content-Length": String(body.count)], chunks: [body])
        }
        let manager = makeManager(root: root)
        manager.registerResolver(TestResolver(body: body), for: .baidu)
        var item = resource(fileName: nil, path: "/unused")
        item.directURL = nil
        item.shareURL = URL(string: "https://pan.baidu.com/s/example")
        item.provider = .baidu
        let id = manager.enqueue(item)

        try await waitUntil { manager.task(id: id)?.state == .completed }
        XCTAssertEqual(try completedData(manager: manager, id: id, root: root), body)
        XCTAssertEqual(manager.task(id: id)?.fileName, "resolved.bin")
        XCTAssertEqual(
            MockURLProtocol.requestHistory().last?.value(forHTTPHeaderField: "X-Resolver"),
            "registered"
        )
    }
}

private struct TestResolver: DownloadResolving {
    let body: Data

    func resolve(_ resource: GameResource) async throws -> ResolvedDownload {
        ResolvedDownload(
            url: URL(string: "https://example.com/registered.bin")!,
            fileName: "resolved.bin",
            fileSize: Int64(body.count),
            headers: ["X-Resolver": "registered"]
        )
    }
}

private struct StubResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String]
    var chunks: [Data]
    var chunkDelay: UInt64 = 0
    var terminalError: URLError?
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var history: [URLRequest] = []
    private var worker: Task<Void, Never>?

    static func reset(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        history = []
        lock.unlock()
    }

    static func requestHistory() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let plan = Self.respond(to: request)
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: plan.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: plan.headers
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        worker = Task { [self] in
            for chunk in plan.chunks {
                if plan.chunkDelay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: plan.chunkDelay)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            guard !Task.isCancelled else { return }
            if let error = plan.terminalError {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        worker?.cancel()
        worker = nil
    }

    private static func respond(to request: URLRequest) -> StubResponse {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        let plan = handler?(request) ?? StubResponse(
            statusCode: 500,
            headers: [:],
            chunks: []
        )
        lock.lock()
        history.append(request)
        lock.unlock()
        return plan
    }
}

@MainActor
private extension DownloadTests {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeManager(
        root: URL,
        settings: DownloadSettings = DownloadSettings(maximumRetries: 0)
    ) -> DownloadManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return DownloadManager(
            session: session,
            settings: settings,
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true),
            partialDirectory: root.appendingPathComponent("Partial", isDirectory: true),
            store: JSONStore(
                fileURL: root.appendingPathComponent("tasks.json"),
                defaultValue: []
            )
        )
    }

    func resource(fileName: String?, path: String) -> GameResource {
        GameResource(
            title: "Test Game",
            sourceName: "Tests",
            directURL: URL(string: "https://example.com\(path)")!,
            provider: .direct,
            fileName: fileName
        )
    }

    func partialFile(root: URL, id: UUID) -> URL {
        DownloadFileSupport.partialURL(
            for: id,
            directory: root.appendingPathComponent("Partial", isDirectory: true)
        )
    }

    func metadataFile(root: URL, id: UUID) -> URL {
        DownloadFileSupport.metadataURL(
            for: id,
            directory: root.appendingPathComponent("Partial", isDirectory: true)
        )
    }

    func completedData(manager: DownloadManager, id: UUID, root: URL) throws -> Data {
        let relativePath = try XCTUnwrap(manager.task(id: id)?.relativePath)
        let url = try XCTUnwrap(manager.fileURL(for: id))
        XCTAssertEqual(relativePath, url.lastPathComponent)
        return try Data(contentsOf: url)
    }

    func waitUntil(
        timeout: TimeInterval = 4,
        condition: () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for download condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private func rangeOffset(in request: URLRequest) -> Int64? {
    guard let range = request.value(forHTTPHeaderField: "Range"),
          range.hasPrefix("bytes="), range.hasSuffix("-") else { return nil }
    return Int64(range.dropFirst(6).dropLast())
}
