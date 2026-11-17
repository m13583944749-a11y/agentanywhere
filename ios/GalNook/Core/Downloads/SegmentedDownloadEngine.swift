import Foundation

/// Errors specific to parallel range downloads. A 200 response to a Range
/// request means that the caller should retry with `DirectDownloadEngine`.
public enum SegmentedDownloadError: LocalizedError, Sendable, Equatable {
    case invalidConnections(Int)
    case rangeNotSupported(statusCode: Int)
    case resourceChanged
    case unsatisfiableRange(offset: Int64, totalBytes: Int64?)

    public var errorDescription: String? {
        switch self {
        case .invalidConnections(let count):
            return "分片下载的连接数必须大于 1，当前为 \(count)"
        case .rangeNotSupported(let statusCode):
            return "服务器未按 Range 请求返回 206（HTTP \(statusCode)），请改用单流下载"
        case .resourceChanged:
            return "下载期间远端文件已变化，请重新解析地址后重试"
        case .unsatisfiableRange(let offset, let totalBytes):
            if let totalBytes {
                return "远端拒绝了偏移 \(offset) 的分片请求，文件总长为 \(totalBytes)"
            }
            return "远端拒绝了偏移 \(offset) 的分片请求"
        }
    }

    /// Whether this error leaves state that must not be reused by another engine.
    var discardsResumeState: Bool {
        switch self {
        case .rangeNotSupported, .resourceChanged:
            return true
        case .invalidConnections, .unsatisfiableRange:
            return false
        }
    }
}

/// Downloads one file into independently written ranges. The download entry
/// point has the same module-internal progress and result types as
/// `DirectDownloadEngine`; no duplicate progress/result models are introduced.
public struct SegmentedDownloadEngine: Sendable {
    private let session: URLSession
    private let partialURL: URL
    private let metadataURL: URL

    public init(session: URLSession, partialURL: URL, metadataURL: URL) {
        self.session = session
        self.partialURL = partialURL
        self.metadataURL = metadataURL
    }

    /// Returns the persisted logical progress. This is necessary because the
    /// partial file is preallocated and its file size is not downloaded progress.
    func savedProgress() -> DownloadProgress? {
        guard let metadata = Self.loadMetadata(metadataURL),
              Self.isStructurallyValid(metadata),
              FileManager.default.fileExists(atPath: partialURL.path),
              DownloadFileSupport.fileSize(partialURL) == metadata.totalBytes else {
            return nil
        }
        return DownloadProgress(
            downloadedBytes: metadata.downloadedBytes,
            totalBytes: metadata.totalBytes,
            bytesPerSecond: 0
        )
    }

    /// Requires `connections > 1`. A successful return guarantees that every
    /// segment was persisted in full and the preallocated file has the expected
    /// size. Cancellation and transport errors preserve resumable segment state.
    func download(
        resolved: ResolvedDownload,
        connections: Int,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> DownloadEngineResult {
        guard connections > 1 else {
            throw SegmentedDownloadError.invalidConnections(connections)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = Self.loadMetadata(metadataURL)
        if let existing,
           Self.isStructurallyValid(existing),
           existing.isComplete,
           FileManager.default.fileExists(atPath: partialURL.path),
           DownloadFileSupport.fileSize(partialURL) == existing.totalBytes {
            let reporter = SegmentProgressReporter(
                downloadedBytes: existing.totalBytes,
                totalBytes: existing.totalBytes,
                progress: progress
            )
            await reporter.report(force: true)
            return DownloadEngineResult(
                downloadedBytes: existing.totalBytes,
                totalBytes: existing.totalBytes
            )
        }

        var progressReporter: SegmentProgressReporter?
        do {
            let probe = try await probe(resolved: resolved)
            let resumed = existing.flatMap {
                canResume($0, probe: probe) ? $0 : nil
            }
            var metadata = resumed ?? SegmentedResumeMetadata(
                eTag: probe.eTag,
                lastModified: probe.lastModified,
                totalBytes: probe.totalBytes,
                segments: Self.makeSegments(
                    totalBytes: probe.totalBytes,
                    connections: connections
                )
            )
            if resumed != nil {
                metadata.eTag = probe.eTag ?? metadata.eTag
                metadata.lastModified = probe.lastModified ?? metadata.lastModified
            }

            let store = SegmentMetadataStore(metadata: metadata, url: metadataURL)
            // Persist zeroed/revalidated metadata before truncating. If the
            // process dies between these steps, the next run can only redownload
            // bytes; it can never mistake stale bytes for completed segments.
            try await store.save()
            try preallocate(totalBytes: metadata.totalBytes)

            let reporter = SegmentProgressReporter(
                downloadedBytes: metadata.downloadedBytes,
                totalBytes: metadata.totalBytes,
                progress: progress
            )
            progressReporter = reporter
            await reporter.report(force: true)

            let pending = metadata.segments.filter { !$0.isComplete }
            try await downloadSegments(
                pending,
                resolved: resolved,
                metadata: metadata,
                connections: connections,
                store: store,
                reporter: reporter
            )

            let finalMetadata = await store.metadata
            guard finalMetadata.isComplete else {
                throw DownloadError.incompleteDownload(
                    expected: finalMetadata.totalBytes,
                    actual: finalMetadata.downloadedBytes
                )
            }
            guard FileManager.default.fileExists(atPath: partialURL.path),
                  DownloadFileSupport.fileSize(partialURL) == finalMetadata.totalBytes else {
                throw DownloadError.invalidResponse
            }

            await reporter.advance(
                to: finalMetadata.downloadedBytes,
                totalBytes: finalMetadata.totalBytes
            )
            await reporter.report(force: true)
            return DownloadEngineResult(
                downloadedBytes: finalMetadata.downloadedBytes,
                totalBytes: finalMetadata.totalBytes
            )
        } catch {
            await progressReporter?.report(force: true)
            if let segmentedError = error as? SegmentedDownloadError,
               segmentedError.discardsResumeState {
                try? FileManager.default.removeItem(at: partialURL)
                try? FileManager.default.removeItem(at: metadataURL)
            }
            throw error
        }
    }

    private func probe(resolved: ResolvedDownload) async throws -> SegmentProbe {
        let request = makeRequest(
            resolved: resolved,
            range: "bytes=0-0",
            validators: nil
        )
        let (_, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }

        if http.statusCode == 416 {
            let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let total = SegmentedContentRange.unsatisfiedTotal(value)
            // An empty resource is the only successful 0-0 probe that may
            // legitimately produce 416. A positive total is not treated as done.
            guard total == 0 else {
                throw SegmentedDownloadError.unsatisfiableRange(
                    offset: 0,
                    totalBytes: total
                )
            }
            return SegmentProbe(
                totalBytes: 0,
                eTag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        }
        if http.statusCode == 200 {
            throw SegmentedDownloadError.rangeNotSupported(statusCode: 200)
        }
        guard http.statusCode == 206 else {
            throw DownloadError.httpStatus(http.statusCode)
        }

        let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
        guard let range = SegmentedContentRange(value: value),
              range.start == 0,
              range.end == 0,
              let total = range.total,
              total > 0 else {
            throw DownloadError.invalidContentRange(value)
        }
        return SegmentProbe(
            totalBytes: total,
            eTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    private func downloadSegments(
        _ segments: [DownloadSegment],
        resolved: ResolvedDownload,
        metadata: SegmentedResumeMetadata,
        connections: Int,
        store: SegmentMetadataStore,
        reporter: SegmentProgressReporter
    ) async throws {
        guard !segments.isEmpty else { return }
        var iterator = segments.makeIterator()
        let workerCount = min(connections, segments.count)

        try await withThrowingTaskGroup(of: Void.self, returning: Void.self) { group in
            for _ in 0..<workerCount {
                guard let segment = iterator.next() else { break }
                group.addTask {
                    try await self.downloadSegment(
                        segment,
                        resolved: resolved,
                        metadata: metadata,
                        store: store,
                        reporter: reporter
                    )
                }
            }
            while try await group.next() != nil {
                if let segment = iterator.next() {
                    group.addTask {
                        try await self.downloadSegment(
                            segment,
                            resolved: resolved,
                            metadata: metadata,
                            store: store,
                            reporter: reporter
                        )
                    }
                }
            }
        }
    }

    private func downloadSegment(
        _ segment: DownloadSegment,
        resolved: ResolvedDownload,
        metadata: SegmentedResumeMetadata,
        store: SegmentMetadataStore,
        reporter: SegmentProgressReporter
    ) async throws {
        guard !segment.isComplete else { return }
        let requestOffset = segment.start + segment.receivedBytes
        let request = makeRequest(
            resolved: resolved,
            range: "bytes=\(requestOffset)-\(segment.end)",
            validators: SegmentValidators(
                eTag: metadata.eTag,
                lastModified: metadata.lastModified
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }

        if http.statusCode == 416 {
            let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let remoteTotal = SegmentedContentRange.unsatisfiedTotal(value)
            guard remoteTotal == metadata.totalBytes else {
                throw SegmentedDownloadError.resourceChanged
            }
            // This is defensive: complete segments are normally skipped before
            // requesting. Never turn an incomplete 416 into a successful result.
            if requestOffset == segment.end + 1 {
                let downloaded = try await store.record(
                    segmentIndex: segment.index,
                    receivedBytes: segment.length
                )
                await reporter.advance(to: downloaded, totalBytes: metadata.totalBytes)
                return
            }
            throw SegmentedDownloadError.unsatisfiableRange(
                offset: requestOffset,
                totalBytes: remoteTotal
            )
        }
        if http.statusCode == 200 {
            throw SegmentedDownloadError.rangeNotSupported(statusCode: 200)
        }
        guard http.statusCode == 206 else {
            throw DownloadError.httpStatus(http.statusCode)
        }

        let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
        guard let range = SegmentedContentRange(value: value),
              range.start == requestOffset,
              range.end == segment.end,
              range.total == metadata.totalBytes else {
            throw DownloadError.invalidContentRange(value)
        }
        guard !Self.validatorsChanged(metadata: metadata, response: http) else {
            throw SegmentedDownloadError.resourceChanged
        }

        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(requestOffset))

        var receivedBytes = segment.receivedBytes
        let chunkSize = 64 * 1024
        var buffer: [UInt8] = []
        buffer.reserveCapacity(chunkSize)

        func flushBuffer() async throws {
            guard !buffer.isEmpty else { return }
            let data = Data(buffer)
            guard Int64(data.count) <= segment.length - receivedBytes else {
                // Do not let an overlong response overwrite a neighbouring range.
                throw DownloadError.invalidResponse
            }
            try handle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            buffer.removeAll(keepingCapacity: true)
            let downloaded = try await store.record(
                segmentIndex: segment.index,
                receivedBytes: receivedBytes
            )
            await reporter.advance(to: downloaded, totalBytes: metadata.totalBytes)
        }

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count == chunkSize {
                    try await flushBuffer()
                }
            }
            try await flushBuffer()
        } catch {
            // Preserve the final partial chunk on pause/cancellation. If this
            // flush itself fails, the older checkpoint remains safe to overwrite.
            try? await flushBuffer()
            throw error
        }

        guard receivedBytes == segment.length else {
            throw DownloadError.incompleteDownload(
                expected: segment.length,
                actual: receivedBytes
            )
        }
    }

    private func preallocate(totalBytes: Int64) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partialURL.path) {
            fileManager.createFile(atPath: partialURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(totalBytes))
        try handle.seek(toOffset: 0)
    }

    private func makeRequest(
        resolved: ResolvedDownload,
        range: String,
        validators: SegmentValidators?
    ) -> URLRequest {
        var request = URLRequest(url: resolved.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("GalNook-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in resolved.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Resolver headers must never change the engine's byte accounting.
        request.setValue(range, forHTTPHeaderField: "Range")
        if let eTag = validators?.eTag, !eTag.uppercased().hasPrefix("W/") {
            request.setValue(eTag, forHTTPHeaderField: "If-Range")
        } else if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Range")
        } else {
            request.setValue(nil, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    private func canResume(
        _ metadata: SegmentedResumeMetadata,
        probe: SegmentProbe
    ) -> Bool {
        guard metadata.totalBytes == probe.totalBytes,
              Self.isStructurallyValid(metadata),
              FileManager.default.fileExists(atPath: partialURL.path),
              DownloadFileSupport.fileSize(partialURL) == metadata.totalBytes else {
            return false
        }
        if let oldETag = metadata.eTag,
           let newETag = probe.eTag,
           oldETag != newETag {
            return false
        }
        if let oldDate = metadata.lastModified,
           let newDate = probe.lastModified,
           oldDate != newDate {
            return false
        }
        return true
    }

    private static func isStructurallyValid(_ metadata: SegmentedResumeMetadata) -> Bool {
        guard metadata.format == SegmentedResumeMetadata.currentFormat,
              metadata.totalBytes >= 0 else { return false }
        if metadata.totalBytes == 0 { return metadata.segments.isEmpty }

        var expectedStart: Int64 = 0
        for (index, segment) in metadata.segments.enumerated() {
            guard segment.index == index,
                  segment.start == expectedStart,
                  expectedStart <= metadata.totalBytes,
                  segment.length > 0,
                  segment.length <= metadata.totalBytes - expectedStart,
                  segment.receivedBytes >= 0,
                  segment.receivedBytes <= segment.length else { return false }
            expectedStart += segment.length
        }
        return !metadata.segments.isEmpty && expectedStart == metadata.totalBytes
    }

    private static func makeSegments(totalBytes: Int64, connections: Int) -> [DownloadSegment] {
        guard totalBytes > 0 else { return [] }
        let count = Int(min(Int64(connections), totalBytes))
        let baseLength = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)
        var start: Int64 = 0
        return (0..<count).map { index in
            let length = baseLength + (Int64(index) < remainder ? 1 : 0)
            let segment = DownloadSegment(
                index: index,
                start: start,
                length: length,
                receivedBytes: 0
            )
            start += length
            return segment
        }
    }

    private static func validatorsChanged(
        metadata: SegmentedResumeMetadata,
        response: HTTPURLResponse
    ) -> Bool {
        if let oldETag = metadata.eTag,
           let newETag = response.value(forHTTPHeaderField: "ETag"),
           oldETag != newETag {
            return true
        }
        if let oldDate = metadata.lastModified,
           let newDate = response.value(forHTTPHeaderField: "Last-Modified"),
           oldDate != newDate {
            return true
        }
        return false
    }

    private static func loadMetadata(_ url: URL) -> SegmentedResumeMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SegmentedResumeMetadata.self, from: data)
    }
}

private struct SegmentProbe: Sendable {
    var totalBytes: Int64
    var eTag: String?
    var lastModified: String?
}

private struct SegmentValidators: Sendable {
    var eTag: String?
    var lastModified: String?
}

private struct DownloadSegment: Codable, Sendable {
    var index: Int
    var start: Int64
    var length: Int64
    var receivedBytes: Int64

    var end: Int64 { start + length - 1 }
    var isComplete: Bool { receivedBytes == length }
}

private struct SegmentedResumeMetadata: Codable, Sendable {
    static let currentFormat = "galnook.segmented.v1"

    var format = currentFormat
    var eTag: String?
    var lastModified: String?
    var totalBytes: Int64
    var segments: [DownloadSegment]

    var downloadedBytes: Int64 {
        segments.reduce(0) { $0 + $1.receivedBytes }
    }

    var isComplete: Bool {
        segments.allSatisfy(\.isComplete)
            && downloadedBytes == totalBytes
    }
}

private actor SegmentMetadataStore {
    private var value: SegmentedResumeMetadata
    private let url: URL

    var metadata: SegmentedResumeMetadata { value }

    init(metadata: SegmentedResumeMetadata, url: URL) {
        self.value = metadata
        self.url = url
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    func record(segmentIndex: Int, receivedBytes: Int64) throws -> Int64 {
        guard value.segments.indices.contains(segmentIndex) else {
            throw DownloadError.invalidResponse
        }
        let previous = value.segments[segmentIndex].receivedBytes
        value.segments[segmentIndex].receivedBytes = receivedBytes
        do {
            try save()
        } catch {
            value.segments[segmentIndex].receivedBytes = previous
            throw error
        }
        return value.downloadedBytes
    }
}

private actor SegmentProgressReporter {
    private let progress: @Sendable (DownloadProgress) async -> Void
    private var downloadedBytes: Int64
    private var totalBytes: Int64
    private var previousSampleBytes: Int64
    private var previousSampleTime: UInt64
    private var previousEmissionTime: UInt64 = 0
    private var speed: Double = 0

    init(
        downloadedBytes: Int64,
        totalBytes: Int64,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.previousSampleBytes = downloadedBytes
        self.previousSampleTime = DispatchTime.now().uptimeNanoseconds
        self.progress = progress
    }

    func advance(to newDownloadedBytes: Int64, totalBytes newTotalBytes: Int64) async {
        // Metadata updates and reporter calls from different workers may be
        // reordered at an await boundary. Never emit regressive UI progress.
        let newValue = max(downloadedBytes, newDownloadedBytes)
        downloadedBytes = newValue
        totalBytes = newTotalBytes
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - previousSampleTime) / 1_000_000_000
        if elapsed > 0, newValue >= previousSampleBytes {
            let instantaneous = Double(newValue - previousSampleBytes) / elapsed
            speed = speed == 0 ? instantaneous : speed * 0.65 + instantaneous * 0.35
        }
        previousSampleBytes = newValue
        previousSampleTime = now
        await report(force: false)
    }

    func report(force: Bool) async {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || previousEmissionTime == 0
                || now - previousEmissionTime >= 200_000_000 else { return }
        previousEmissionTime = now
        await progress(DownloadProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: speed
        ))
    }
}

private struct SegmentedContentRange {
    var start: Int64
    var end: Int64
    var total: Int64?

    init?(value: String) {
        let prefix = "bytes "
        guard value.lowercased().hasPrefix(prefix) else { return nil }
        let components = value.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }
        let bounds = components[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start else { return nil }
        let totalText = components[1]
        let total = totalText == "*" ? nil : Int64(totalText)
        if totalText != "*" && total == nil { return nil }
        if let total, total <= end { return nil }
        self.start = start
        self.end = end
        self.total = total
    }

    static func unsatisfiedTotal(_ value: String) -> Int64? {
        let prefix = "bytes */"
        guard value.lowercased().hasPrefix(prefix),
              let total = Int64(value.dropFirst(prefix.count)),
              total >= 0 else { return nil }
        return total
    }
}
