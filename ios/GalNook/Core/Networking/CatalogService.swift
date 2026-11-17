import Foundation

public enum SourceFailure: LocalizedError, Sendable {
    case unsupported
    case missingCredentials
    case malformedResponse(String)
}

public protocol WorkSourceClient: Sendable {
    var source: WorkSource { get }
    func works(query: WorkQuery, page: Int, limit: Int, includeAdult: Bool) async throws -> WorkPage
    func detail(for work: WorkSummary) async throws -> WorkDetail
    func characters(for work: WorkSummary) async throws -> [GameCharacter]
    func walkthroughs(for work: WorkSummary) async throws -> [Walkthrough]
}

public extension WorkSourceClient {
    func characters(for work: WorkSummary) async throws -> [GameCharacter] { [] }
    func walkthroughs(for work: WorkSummary) async throws -> [Walkthrough] { [] }
}

public struct CatalogBatch: Sendable {
    public var works: [WorkSummary]
    public var hasMore: Bool
    public var failures: [String]

    public init(works: [WorkSummary], hasMore: Bool, failures: [String] = []) {
        self.works = works
        self.hasMore = hasMore
        self.failures = failures
    }
}

public actor CatalogService {
    public static let shared = CatalogService(clients: [
        NextMoeClient(),
        VNDBClient(),
        YmgalClient(),
        CnGalClient()
    ])

    private var clients: [WorkSource: any WorkSourceClient]

    public init(clients: [any WorkSourceClient]) {
        var mapped: [WorkSource: any WorkSourceClient] = [:]
        for client in clients { mapped[client.source] = client }
        self.clients = mapped
    }

    public func register(_ client: any WorkSourceClient) {
        clients[client.source] = client
    }

    public func works(
        query: WorkQuery,
        sources: Set<WorkSource>,
        page: Int = 1,
        limit: Int = 30,
        includeAdult: Bool = false
    ) async throws -> CatalogBatch {
        let selected = sources.compactMap { clients[$0] }
        guard !selected.isEmpty else { throw SourceFailure.unsupported }
        return try await withThrowingTaskGroup(of: Result<(WorkSource, WorkPage), Error>.self, returning: CatalogBatch.self) { group in
            for client in selected {
                group.addTask {
                    do {
                        let result = try await client.works(query: query, page: page, limit: limit, includeAdult: includeAdult)
                        return .success((client.source, result))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var works: [WorkSummary] = []
            var seen: Set<String> = []
            var hasMore = false
            var failures: [String] = []
            var successes = 0
            for try await result in group {
                switch result {
                case .success(let source, let pageResult):
                    successes += 1
                    hasMore = hasMore || pageResult.hasMore
                    for work in pageResult.items where !seen.contains(work.id) {
                        seen.insert(work.id)
                        works.append(work)
                    }
                    if works.count > limit * max(1, selected.count) { break }
                    _ = source
                case .failure(let error):
                    failures.append(error.localizedDescription)
                }
            }
            if successes == 0, let first = failures.first {
                throw SourceFailure.malformedResponse(first)
            }
            works.sort {
                switch query {
                case .highlyRated:
                    return ($0.rating ?? -1) > ($1.rating ?? -1)
                case .advanced(_, let sort, _):
                    switch sort {
                    case .nextMoeRating, .vndbRating, .erogameRating:
                        return ($0.rating ?? -1) > ($1.rating ?? -1)
                    case .releaseDate:
                        return ($0.releaseDate ?? "") > ($1.releaseDate ?? "")
                    case .popularity:
                        return ($0.ratingCount ?? -1) > ($1.ratingCount ?? -1)
                    }
                default:
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }
            return CatalogBatch(works: works, hasMore: hasMore, failures: failures)
        }
    }

    public func tags() async throws -> [CatalogTag] {
        guard let client = clients[.nextMoe] as? NextMoeClient else { return [] }
        return try await client.tags()
    }

    public func detail(for work: WorkSummary) async throws -> WorkDetail {
        guard let client = clients[work.source] else { throw SourceFailure.unsupported }
        return try await client.detail(for: work)
    }

    public func characters(for work: WorkSummary) async throws -> [GameCharacter] {
        guard let client = clients[work.source] else { throw SourceFailure.unsupported }
        return try await client.characters(for: work)
    }

    public func walkthroughs(for work: WorkSummary) async throws -> [Walkthrough] {
        if let client = clients[work.source] {
            return try await client.walkthroughs(for: work)
        }
        throw SourceFailure.unsupported
    }

    public func walkthroughsAcrossSources(for work: WorkSummary) async throws -> [Walkthrough] {
        if work.source == .nextMoe { return try await walkthroughs(for: work) }
        let equivalent = WorkSummary(source: .nextMoe, sourceID: work.sourceID, title: work.title)
        return try await walkthroughs(for: equivalent)
    }
}

public extension SourceFailure {
    var errorDescription: String? {
        switch self {
        case .unsupported: "当前数据源不支持此操作"
        case .missingCredentials: "请先在设置中填写数据源凭证"
        case .malformedResponse(let message): message
        }
    }
}
