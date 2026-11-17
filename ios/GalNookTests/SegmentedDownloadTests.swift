import Foundation
import XCTest
@testable import GalNook

final class SegmentedDownloadTests: XCTestCase {
    func testParallelRangesWriteExactFileAndReportAggregateProgress() async throws {
        let root = try segmentedTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(300 * 1024 + 17)).map { UInt8($0 % 251) })
        let session = segmentedSession()
        defer { session.invalidateAndCancel() }

        SegmentedMockURLProtocol.reset { request in
            guard let range = segmentedClosedRange(request) else {
                return SegmentedStubResponse(statusCode: 500, headers: [:], chunks: [])
            }
            if range.start == 0, range.end == 0 {
                return SegmentedStubResponse(
                    headers: [
                        "Content-Length": "1",
                        "Content-Range": "bytes 0-0/\(body.count)",
                        "ETag": "\"parallel-v1\""
                    ],
                    chunks: [Data([body[0]])]
                )
            }
            let data = body.subdata(in: Int(range.start)..<Int(range.end + 1))
            return SegmentedStubResponse(
                headers: [
                    "Content-Length": String(data.count),
                    "Content-Range": "bytes \(range.start)-\(range.end)/\(body.count)",
                    "ETag": "\"parallel-v1\""
                ],
                chunks: segmentedChunks(data, size: 16 * 1024),
                chunkDelay: 1_000_000
            )
        }

        let partialURL = root.appendingPathComponent("parallel.partial")
        let metadataURL = root.appendingPathComponent("parallel.json")
        let engine = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: metadataURL
        )
        let history = SegmentedProgressHistory()
        let resolved = ResolvedDownload(
            url: URL(string: "https://example.com/parallel.bin")!,
            fileName: "parallel.bin",
            fileSize: Int64(body.count),
            headers: ["X-Resolver": "segmented-tests"]
        )

        let result = try await engine.download(resolved: resolved, connections: 4) {
            history.append($0)
        }

        XCTAssertEqual(result.downloadedBytes, Int64(body.count))
        XCTAssertEqual(result.totalBytes, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: partialURL), body)
        XCTAssertEqual(engine.savedProgress()?.downloadedBytes, Int64(body.count))

        let requests = SegmentedMockURLProtocol.requestHistory()
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-0")
        let segments = requests.filter {
            $0.value(forHTTPHeaderField: "Range") != "bytes=0-0"
        }
        XCTAssertEqual(segments.count, 4)
        XCTAssertTrue(segments.allSatisfy {
            $0.value(forHTTPHeaderField: "If-Range") == "\"parallel-v1\""
                && $0.value(forHTTPHeaderField: "X-Resolver") == "segmented-tests"
        })
        XCTAssertGreaterThanOrEqual(SegmentedMockURLProtocol.maximumActiveRequests(), 2)

        let progress = history.values()
        XCTAssertEqual(progress.last?.downloadedBytes, Int64(body.count))
        XCTAssertTrue(progress.allSatisfy { $0.totalBytes == Int64(body.count) })
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy {
            $0.1.downloadedBytes >= $0.0.downloadedBytes
        })
        XCTAssertGreaterThan(progress.last?.bytesPerSecond ?? 0, 0)
    }

    func testCancellationPersistsSegmentsAndResumeSkipsCompletedRange() async throws {
        let root = try segmentedTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(256 * 1024)).map { UInt8(255 - ($0 % 239)) })
        let session = segmentedSession()
        defer { session.invalidateAndCancel() }
        let segmentLength = Int64(body.count / 2)
        let resumedOffset = segmentLength + 64 * 1024

        SegmentedMockURLProtocol.reset { request in
            guard let range = segmentedClosedRange(request) else {
                return SegmentedStubResponse(statusCode: 500, headers: [:], chunks: [])
            }
            if range.start == 0, range.end == 0 {
                return SegmentedStubResponse(
                    headers: [
                        "Content-Range": "bytes 0-0/\(body.count)",
                        "ETag": "\"resume-v1\""
                    ],
                    chunks: [Data([body[0]])]
                )
            }
            let headers = [
                "Content-Range": "bytes \(range.start)-\(range.end)/\(body.count)",
                "ETag": "\"resume-v1\""
            ]
            if range.start == 0 {
                let data = body.subdata(in: 0..<Int(segmentLength))
                return SegmentedStubResponse(
                    headers: headers,
                    chunks: segmentedChunks(data, size: 32 * 1024)
                )
            }
            let firstHalf = body.subdata(in: Int(segmentLength)..<Int(resumedOffset))
            return SegmentedStubResponse(
                headers: headers,
                chunks: [firstHalf],
                chunkDelay: 250_000_000,
                tailDelay: 30_000_000_000
            )
        }

        let partialURL = root.appendingPathComponent("resume.partial")
        let metadataURL = root.appendingPathComponent("resume.json")
        let engine = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: metadataURL
        )
        let resolved = ResolvedDownload(
            url: URL(string: "https://example.com/resume.bin")!,
            fileName: "resume.bin"
        )
        let firstProgress = SegmentedProgressHistory()
        let firstTask = Task {
            try await engine.download(resolved: resolved, connections: 2) {
                firstProgress.append($0)
            }
        }

        try await segmentedWaitForProgress(firstProgress, atLeast: resumedOffset)
        firstTask.cancel()
        do {
            _ = try await firstTask.value
            XCTFail("Cancelled segmented download unexpectedly returned a result")
        } catch {
            // Pause/cancellation is expected and must leave a resumable state.
        }

        XCTAssertEqual(DownloadFileSupport.fileSize(partialURL), Int64(body.count))
        XCTAssertEqual(engine.savedProgress()?.downloadedBytes, resumedOffset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        SegmentedMockURLProtocol.reset { request in
            guard let range = segmentedClosedRange(request) else {
                return SegmentedStubResponse(statusCode: 500, headers: [:], chunks: [])
            }
            if range.start == 0, range.end == 0 {
                return SegmentedStubResponse(
                    headers: [
                        "Content-Range": "bytes 0-0/\(body.count)",
                        "ETag": "\"resume-v1\""
                    ],
                    chunks: [Data([body[0]])]
                )
            }
            guard range.start == resumedOffset, range.end == Int64(body.count - 1) else {
                return SegmentedStubResponse(statusCode: 500, headers: [:], chunks: [])
            }
            let remaining = body.subdata(in: Int(resumedOffset)..<body.count)
            return SegmentedStubResponse(
                headers: [
                    "Content-Range": "bytes \(range.start)-\(range.end)/\(body.count)",
                    "ETag": "\"resume-v1\""
                ],
                chunks: [remaining]
            )
        }

        let result = try await engine.download(resolved: resolved, connections: 2) { _ in }
        XCTAssertEqual(result.downloadedBytes, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: partialURL), body)
        let resumedRequests = SegmentedMockURLProtocol.requestHistory().filter {
            $0.value(forHTTPHeaderField: "Range") != "bytes=0-0"
        }
        XCTAssertEqual(resumedRequests.count, 1)
        XCTAssertEqual(
            resumedRequests[0].value(forHTTPHeaderField: "Range"),
            "bytes=\(resumedOffset)-\(body.count - 1)"
        )
    }

    func testHTTP200AllowsCallerToFallbackToSingleStream() async throws {
        let root = try segmentedTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data("single-stream-fallback".utf8)
        let session = segmentedSession()
        defer { session.invalidateAndCancel() }
        SegmentedMockURLProtocol.reset { _ in
            SegmentedStubResponse(
                statusCode: 200,
                headers: ["Content-Length": String(body.count)],
                chunks: [body]
            )
        }

        let partialURL = root.appendingPathComponent("fallback.partial")
        let metadataURL = root.appendingPathComponent("fallback.json")
        let resolved = ResolvedDownload(
            url: URL(string: "https://example.com/fallback.bin")!,
            fileName: "fallback.bin"
        )
        let segmented = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: metadataURL
        )

        do {
            _ = try await segmented.download(resolved: resolved, connections: 3) { _ in }
            XCTFail("A 200 response to a Range probe must not complete as segmented")
        } catch {
            let segmentedError = try XCTUnwrap(error as? SegmentedDownloadError)
            guard case .rangeNotSupported(let statusCode) = segmentedError else {
                return XCTFail("Unexpected error: \(segmentedError)")
            }
            XCTAssertEqual(statusCode, 200)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))

        // This is the caller-owned fallback path used by DownloadManager.
        let direct = DirectDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: metadataURL
        )
        let result = try await direct.download(resolved: resolved) { _ in }
        XCTAssertEqual(result.downloadedBytes, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: partialURL), body)
        let requests = SegmentedMockURLProtocol.requestHistory()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Range"), "bytes=0-0")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Range"))
    }

    func testEmptyResourceProbe416ReturnsOnlyVerifiedEmptyFile() async throws {
        let root = try segmentedTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = segmentedSession()
        defer { session.invalidateAndCancel() }
        SegmentedMockURLProtocol.reset { _ in
            SegmentedStubResponse(
                statusCode: 416,
                headers: ["Content-Range": "bytes */0"],
                chunks: []
            )
        }

        let partialURL = root.appendingPathComponent("empty.partial")
        let engine = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: root.appendingPathComponent("empty.json")
        )
        let resolved = ResolvedDownload(
            url: URL(string: "https://example.com/empty.bin")!,
            fileName: "empty.bin"
        )
        let result = try await engine.download(resolved: resolved, connections: 4) { _ in }

        XCTAssertEqual(result.downloadedBytes, 0)
        XCTAssertEqual(result.totalBytes, 0)
        XCTAssertEqual(try Data(contentsOf: partialURL), Data())
        XCTAssertEqual(SegmentedMockURLProtocol.requestHistory().count, 1)
    }

    func testNonEmptyProbe416DoesNotFabricateCompletedFile() async throws {
        let root = try segmentedTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = segmentedSession()
        defer { session.invalidateAndCancel() }
        SegmentedMockURLProtocol.reset { _ in
            SegmentedStubResponse(
                statusCode: 416,
                headers: ["Content-Range": "bytes */12345"],
                chunks: []
            )
        }

        let partialURL = root.appendingPathComponent("unsatisfiable.partial")
        let engine = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: root.appendingPathComponent("unsatisfiable.json")
        )
        let resolved = ResolvedDownload(
            url: URL(string: "https://example.com/unsatisfiable.bin")!,
            fileName: "unsatisfiable.bin"
        )

        do {
            _ = try await engine.download(resolved: resolved, connections: 4) { _ in }
            XCTFail("A non-empty 416 probe must not complete as downloaded")
        } catch {
            let segmentedError = try XCTUnwrap(error as? SegmentedDownloadError)
            guard case .unsatisfiableRange(let offset, let totalBytes) = segmentedError else {
                return XCTFail("Unexpected error: \(segmentedError)")
            }
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(totalBytes, 12_345)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testShortSegmentThrowsAndNextRunRequestsMissingBytes() async throws {
        let root = try segmentedTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(128 * 1024)).map { UInt8($0 % 223) })
        let session = segmentedSession()
        defer { session.invalidateAndCancel() }

        SegmentedMockURLProtocol.reset { request in
            segmentedRangePlan(request: request, body: body, shortenFirstSegment: true)
        }
        let partialURL = root.appendingPathComponent("short.partial")
        let metadataURL = root.appendingPathComponent("short.json")
        let engine = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: metadataURL
        )
        let resolved = ResolvedDownload(
            url: URL(string: "https://example.com/short.bin")!,
            fileName: "short.bin"
        )

        do {
            _ = try await engine.download(resolved: resolved, connections: 2) { _ in }
            XCTFail("A short segment must not be reported as complete")
        } catch {
            let downloadError = try XCTUnwrap(error as? DownloadError)
            guard case .incompleteDownload = downloadError else {
                return XCTFail("Unexpected error: \(downloadError)")
            }
        }
        XCTAssertEqual(DownloadFileSupport.fileSize(partialURL), Int64(body.count))
        XCTAssertLessThan(engine.savedProgress()?.downloadedBytes ?? 0, Int64(body.count))

        SegmentedMockURLProtocol.reset { request in
            segmentedRangePlan(request: request, body: body, shortenFirstSegment: false)
        }
        let result = try await engine.download(resolved: resolved, connections: 2) { _ in }
        XCTAssertEqual(result.downloadedBytes, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: partialURL), body)
        let ranges = SegmentedMockURLProtocol.requestHistory().compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
        XCTAssertTrue(ranges.contains("bytes=65535-65535"))
    }
}

private struct SegmentedStubResponse: Sendable {
    var statusCode: Int = 206
    var headers: [String: String]
    var chunks: [Data]
    var chunkDelay: UInt64 = 0
    var tailDelay: UInt64 = 0
}

private final class SegmentedMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> SegmentedStubResponse

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var history: [URLRequest] = []
    private static var activeIDs: Set<UUID> = []
    private static var maximumActive = 0

    private let identifier = UUID()
    private var worker: Task<Void, Never>?

    static func reset(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        history = []
        activeIDs = []
        maximumActive = 0
        lock.unlock()
    }

    static func requestHistory() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    static func maximumActiveRequests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let plan = Self.begin(request, identifier: identifier)
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: plan.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: plan.headers
        ) else {
            Self.finish(identifier: identifier)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        worker = Task { [self] in
            defer { Self.finish(identifier: identifier) }
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
            if plan.tailDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: plan.tailDelay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        worker?.cancel()
        worker = nil
    }

    private static func begin(_ request: URLRequest, identifier: UUID) -> SegmentedStubResponse {
        lock.lock()
        let handler = self.handler
        history.append(request)
        activeIDs.insert(identifier)
        maximumActive = max(maximumActive, activeIDs.count)
        lock.unlock()
        return handler?(request) ?? SegmentedStubResponse(
            statusCode: 500,
            headers: [:],
            chunks: []
        )
    }

    private static func finish(identifier: UUID) {
        lock.lock()
        activeIDs.remove(identifier)
        lock.unlock()
    }
}

private final class SegmentedProgressHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DownloadProgress] = []

    func append(_ item: DownloadProgress) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func values() -> [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var lastDownloadedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return items.last?.downloadedBytes ?? 0
    }
}

private struct SegmentedTestRange {
    var start: Int64
    var end: Int64
}

private func segmentedClosedRange(_ request: URLRequest) -> SegmentedTestRange? {
    guard let value = request.value(forHTTPHeaderField: "Range"),
          value.hasPrefix("bytes=") else { return nil }
    let bounds = value.dropFirst(6).split(separator: "-", maxSplits: 1)
    guard bounds.count == 2,
          let start = Int64(bounds[0]),
          let end = Int64(bounds[1]),
          start >= 0,
          end >= start else { return nil }
    return SegmentedTestRange(start: start, end: end)
}

private func segmentedRangePlan(
    request: URLRequest,
    body: Data,
    shortenFirstSegment: Bool
) -> SegmentedStubResponse {
    guard let range = segmentedClosedRange(request) else {
        return SegmentedStubResponse(statusCode: 500, headers: [:], chunks: [])
    }
    if range.start == 0, range.end == 0 {
        return SegmentedStubResponse(
            headers: [
                "Content-Range": "bytes 0-0/\(body.count)",
                "ETag": "\"short-v1\""
            ],
            chunks: [Data([body[0]])]
        )
    }
    var data = body.subdata(in: Int(range.start)..<Int(range.end + 1))
    if shortenFirstSegment, range.start == 0, data.count > 1 {
        data.removeLast()
    }
    return SegmentedStubResponse(
        headers: [
            "Content-Range": "bytes \(range.start)-\(range.end)/\(body.count)",
            "ETag": "\"short-v1\""
        ],
        chunks: [data]
    )
}

private func segmentedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SegmentedMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func segmentedTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SegmentedDownloadTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func segmentedChunks(_ data: Data, size: Int) -> [Data] {
    guard !data.isEmpty else { return [] }
    var result: [Data] = []
    var offset = 0
    while offset < data.count {
        let end = min(data.count, offset + size)
        result.append(data.subdata(in: offset..<end))
        offset = end
    }
    return result
}

private func segmentedWaitForProgress(
    _ history: SegmentedProgressHistory,
    atLeast expectedBytes: Int64
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
    while history.lastDownloadedBytes < expectedBytes {
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            XCTFail("Timed out waiting for segmented progress: \(history.lastDownloadedBytes)")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
