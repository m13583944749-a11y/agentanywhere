import Foundation

struct ResourceSpeedResult: Sendable {
    let resourceID: String
    let milliseconds: Int?
    let bytesPerSecond: Double?
    let error: String?

    var summary: String {
        if let error { return error }
        if let milliseconds { return "\(milliseconds) ms" }
        return "已响应"
    }
}

actor ResourceSpeedTester {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testAll(_ resources: [GameResource], concurrency: Int = 8) async -> [String: ResourceSpeedResult] {
        guard !resources.isEmpty else { return [:] }
        var iterator = resources.makeIterator()
        let workers = min(max(1, concurrency), resources.count)
        var results: [String: ResourceSpeedResult] = [:]
        await withTaskGroup(of: ResourceSpeedResult.self) { group in
            for _ in 0..<workers {
                guard let resource = iterator.next() else { break }
                group.addTask { await self.test(resource) }
            }
            while let result = await group.next() {
                results[result.resourceID] = result
                if let resource = iterator.next() {
                    group.addTask { await self.test(resource) }
                }
            }
        }
        return results
    }

    private func test(_ resource: GameResource) async -> ResourceSpeedResult {
        guard let url = resource.preferredURL else {
            return ResourceSpeedResult(resourceID: resource.id, milliseconds: nil, bytesPerSecond: nil, error: "无地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("bytes=0-8191", forHTTPHeaderField: "Range")

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ResourceSpeedResult(resourceID: resource.id, milliseconds: nil, bytesPerSecond: nil, error: "HTTP \(code)")
            }
            var firstByteAt: UInt64?
            var received = 0
            for try await _ in bytes {
                if firstByteAt == nil { firstByteAt = DispatchTime.now().uptimeNanoseconds }
                received += 1
                if received >= 8 * 1024 { break }
            }
            let finished = DispatchTime.now().uptimeNanoseconds
            guard let firstByteAt, received > 0 else {
                return ResourceSpeedResult(resourceID: resource.id, milliseconds: nil, bytesPerSecond: nil, error: "无响应数据")
            }
            let latency = Double(firstByteAt - started) / 1_000_000
            let transferSeconds = max(0.001, Double(finished - firstByteAt) / 1_000_000_000)
            let speed = Double(received) / transferSeconds
            return ResourceSpeedResult(
                resourceID: resource.id,
                milliseconds: Int(latency.rounded()),
                bytesPerSecond: speed,
                error: nil
            )
        } catch {
            return ResourceSpeedResult(
                resourceID: resource.id,
                milliseconds: nil,
                bytesPerSecond: nil,
                error: error.localizedDescription
            )
        }
    }
}
