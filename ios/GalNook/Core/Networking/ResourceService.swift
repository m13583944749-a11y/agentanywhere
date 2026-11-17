import Foundation

public protocol ResourceClient: Sendable {
    var name: String { get }
    func resources(for work: WorkSummary) async throws -> [GameResource]
}

public struct ResourceBatch: Sendable {
    public var resources: [GameResource]
    public var failures: [String]

    public init(resources: [GameResource], failures: [String] = []) {
        self.resources = resources
        self.failures = failures
    }
}

public actor ResourceService {
    public static let shared = ResourceService(clients: [SearchGalResourceClient()])
    private var clients: [any ResourceClient]

    public init(clients: [any ResourceClient]) { self.clients = clients }

    public func register(_ client: any ResourceClient) {
        clients.removeAll { $0.name == client.name }
        clients.append(client)
    }

    public func resources(for work: WorkSummary) async throws -> ResourceBatch {
        guard !clients.isEmpty else { return ResourceBatch(resources: []) }
        return try await withThrowingTaskGroup(of: Result<(String, [GameResource]), Error>.self, returning: ResourceBatch.self) { group in
            for client in clients {
                group.addTask {
                    do { return .success((client.name, try await client.resources(for: work))) }
                    catch { return .failure(error) }
                }
            }
            var result: [GameResource] = []
            var failures: [String] = []
            var successes = 0
            for try await response in group {
                switch response {
                case .success(_, let resources):
                    successes += 1
                    result.append(contentsOf: resources)
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
            if successes == 0, !failures.isEmpty {
                throw SourceFailure.malformedResponse(failures.joined(separator: "；"))
            }
            var seen = Set<String>()
            result = result.filter { resource in
                let key = resource.preferredURL?.absoluteString ?? resource.id
                return seen.insert(key).inserted
            }
            result.sort { lhs, rhs in
                if lhs.isAndroidPackage != rhs.isAndroidPackage { return !lhs.isAndroidPackage }
                if lhs.provider == .direct, rhs.provider != .direct { return true }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return ResourceBatch(resources: result, failures: failures)
        }
    }
}

@MainActor
public final class DownloadActions {
    public static let shared = DownloadActions()
    private var enqueueHandler: ((GameResource) -> Void)?

    private init() {}

    public func register(_ handler: @escaping (GameResource) -> Void) {
        enqueueHandler = handler
    }

    @discardableResult
    public func enqueue(_ resource: GameResource) -> Bool {
        guard let enqueueHandler else { return false }
        enqueueHandler(resource)
        return true
    }
}
