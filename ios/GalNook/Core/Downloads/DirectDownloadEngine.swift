import Foundation

/// Performs the byte-level download away from the main actor. The manager owns
/// task state; this type only owns the response, file handle and resume metadata.
struct DirectDownloadEngine: Sendable {
    private let session: URLSession
    private let partialURL: URL
    private let metadataURL: URL

    init(session: URLSession, partialURL: URL, metadataURL: URL) {
        self.session = session
        self.partialURL = partialURL
        self.metadataURL = metadataURL
    }

    func download(
        resolved: ResolvedDownload,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> DownloadEngineResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var metadata = DownloadFileSupport.loadMetadata(metadataURL)

        while true {
            try Task.checkCancellation()
            let offset = DownloadFileSupport.fileSize(partialURL)

            // A previous attempt may have received every byte but been cancelled
            // immediately before the atomic move into the Downloads directory.
            if offset > 0, metadata?.totalBytes == offset {
                let item = DownloadProgress(
                    downloadedBytes: offset,
                    totalBytes: offset,
                    bytesPerSecond: 0
                )
                await progress(item)
                return DownloadEngineResult(downloadedBytes: offset, totalBytes: offset)
            }

            let request = makeRequest(resolved: resolved, offset: offset, metadata: metadata)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DownloadError.invalidResponse
            }

            if http.statusCode == 416, offset > 0 {
                let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                if let remoteSize = Self.unsatisfiedRangeTotal(value), remoteSize == offset {
                    await progress(DownloadProgress(
                        downloadedBytes: offset,
                        totalBytes: remoteSize,
                        bytesPerSecond: 0
                    ))
                    return DownloadEngineResult(downloadedBytes: offset, totalBytes: remoteSize)
                }
                try await restartFromBeginning(progress: progress)
                metadata = nil
                continue
            }

            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw DownloadError.httpStatus(http.statusCode)
            }

            var range: ContentByteRange?
            if http.statusCode == 206 {
                let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard let parsed = ContentByteRange(value: value), parsed.start == offset else {
                    if offset > 0 {
                        try await restartFromBeginning(progress: progress)
                        metadata = nil
                        continue
                    }
                    throw DownloadError.invalidContentRange(value)
                }
                range = parsed

                if offset > 0, Self.validatorsChanged(metadata: metadata, response: http) {
                    // If-Range should make the server send 200 after a validator
                    // change. Do not append if a non-conforming server sends 206.
                    try await restartFromBeginning(progress: progress)
                    metadata = nil
                    continue
                }
            }

            let isAppending = http.statusCode == 206 && offset > 0
            let responseLength = http.expectedContentLength
            var totalBytes: Int64
            if let rangeTotal = range?.total {
                totalBytes = rangeTotal
            } else if responseLength >= 0 {
                totalBytes = (isAppending ? offset : 0) + responseLength
            } else {
                totalBytes = resolved.fileSize ?? metadata?.totalBytes ?? 0
            }
            if totalBytes < 0 { totalBytes = 0 }

            let nextMetadata = DownloadResumeMetadata(
                eTag: http.value(forHTTPHeaderField: "ETag") ?? (isAppending ? metadata?.eTag : nil),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
                    ?? (isAppending ? metadata?.lastModified : nil),
                totalBytes: totalBytes
            )
            try DownloadFileSupport.saveMetadata(nextMetadata, to: metadataURL)
            metadata = nextMetadata

            return try await consume(
                bytes,
                offset: isAppending ? offset : Int64(0),
                totalBytes: totalBytes,
                append: isAppending,
                progress: progress
            )
        }
    }

    private func makeRequest(
        resolved: ResolvedDownload,
        offset: Int64,
        metadata: DownloadResumeMetadata?
    ) -> URLRequest {
        var request = URLRequest(url: resolved.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("GalNook-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in resolved.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let eTag = metadata?.eTag, !eTag.uppercased().hasPrefix("W/") {
                request.setValue(eTag, forHTTPHeaderField: "If-Range")
            } else if let lastModified = metadata?.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Range")
            }
        } else {
            // Resolver-supplied ranges would corrupt the byte accounting.
            request.setValue(nil, forHTTPHeaderField: "Range")
            request.setValue(nil, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    private func restartFromBeginning(
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: partialURL.path) {
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.truncate(atOffset: 0)
            try handle.close()
        }
        try? fileManager.removeItem(at: metadataURL)
        await progress(DownloadProgress(downloadedBytes: 0, totalBytes: 0, bytesPerSecond: 0))
    }

    private func consume(
        _ bytes: URLSession.AsyncBytes,
        offset: Int64,
        totalBytes: Int64,
        append: Bool,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> DownloadEngineResult {
        let fileManager = FileManager.default
        if !append || !fileManager.fileExists(atPath: partialURL.path) {
            _ = fileManager.createFile(atPath: partialURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        if append {
            let actualEnd = try handle.seekToEnd()
            guard actualEnd == UInt64(offset) else { throw DownloadError.invalidResponse }
        } else {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
        }

        var reporter = ProgressReporter(
            downloadedBytes: offset,
            totalBytes: totalBytes,
            progress: progress
        )
        await reporter.report(force: true)

        let chunkSize = 64 * 1024
        var buffer: [UInt8] = []
        buffer.reserveCapacity(chunkSize)
        var currentBytes = offset

        func flushBuffer() async throws {
            guard !buffer.isEmpty else { return }
            let data = Data(buffer)
            try handle.write(contentsOf: data)
            currentBytes += Int64(data.count)
            buffer.removeAll(keepingCapacity: true)
            await reporter.advance(to: currentBytes, totalBytes: totalBytes)
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
            // Preserve every byte already delivered by URLSession, including a
            // final partial chunk, so pause always leaves a resumable file.
            try? await flushBuffer()
            throw error
        }

        if totalBytes > 0, currentBytes != totalBytes {
            throw DownloadError.incompleteDownload(expected: totalBytes, actual: currentBytes)
        }
        await reporter.report(force: true)
        return DownloadEngineResult(downloadedBytes: currentBytes, totalBytes: totalBytes)
    }

    private static func validatorsChanged(
        metadata: DownloadResumeMetadata?,
        response: HTTPURLResponse
    ) -> Bool {
        guard let metadata else { return false }
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

    private static func unsatisfiedRangeTotal(_ value: String) -> Int64? {
        let pattern = "bytes */"
        guard value.lowercased().hasPrefix(pattern) else { return nil }
        return Int64(value.dropFirst(pattern.count))
    }
}

private struct ContentByteRange {
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
              start >= 0, end >= start else { return nil }
        let totalText = components[1]
        let total = totalText == "*" ? nil : Int64(totalText)
        if totalText != "*" && total == nil { return nil }
        if let total, total <= end { return nil }
        self.start = start
        self.end = end
        self.total = total
    }
}

private struct ProgressReporter {
    let progress: @Sendable (DownloadProgress) async -> Void
    private(set) var downloadedBytes: Int64
    private(set) var totalBytes: Int64
    private var previousSampleBytes: Int64
    private var previousSampleTime: UInt64
    private var previousEmissionTime: UInt64
    private var speed: Double = 0

    init(
        downloadedBytes: Int64,
        totalBytes: Int64,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.progress = progress
        self.previousSampleBytes = downloadedBytes
        let now = DispatchTime.now().uptimeNanoseconds
        self.previousSampleTime = now
        self.previousEmissionTime = 0
    }

    mutating func advance(to downloadedBytes: Int64, totalBytes: Int64) async {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - previousSampleTime) / 1_000_000_000
        if elapsed > 0, downloadedBytes >= previousSampleBytes {
            let instantaneous = Double(downloadedBytes - previousSampleBytes) / elapsed
            speed = speed == 0 ? instantaneous : speed * 0.65 + instantaneous * 0.35
        }
        previousSampleBytes = downloadedBytes
        previousSampleTime = now
        await report(force: false)
    }

    mutating func report(force: Bool) async {
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
