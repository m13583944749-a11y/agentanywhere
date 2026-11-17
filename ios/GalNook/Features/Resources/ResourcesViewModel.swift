import Foundation

@MainActor
final class ResourcesViewModel: ObservableObject {
    @Published var resources: [GameResource] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var failures: [String] = []
    @Published var compatibleOnly = false
    @Published var speedResults: [String: ResourceSpeedResult] = [:]
    @Published var isSpeedTesting = false

    private let service: ResourceService
    private let speedTester = ResourceSpeedTester()
    private var task: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?

    init(service: ResourceService = .shared) { self.service = service }

    struct ResourceGroup: Identifiable {
        let id: String
        let sourceName: String
        let resources: [GameResource]
        let hasAPK: Bool
    }

    var filtered: [GameResource] {
        guard compatibleOnly else { return resources }
        return resources.filter { !$0.isAndroidPackage && ($0.engine == .unknown || $0.engine.supportedByKrKrCat) }
    }

    var groups: [ResourceGroup] {
        Dictionary(grouping: filtered, by: \.sourceName)
            .map { sourceName, items in
                let sorted = items.sorted { lhs, rhs in
                    let left = speedResults[lhs.id]?.milliseconds
                    let right = speedResults[rhs.id]?.milliseconds
                    if let left, let right, left != right { return left < right }
                    if left != nil, right == nil { return true }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return ResourceGroup(
                    id: sourceName,
                    sourceName: sourceName,
                    resources: sorted,
                    hasAPK: items.contains(where: \.isAndroidPackage)
                )
            }
            .sorted { $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending }
    }

    var apkGroups: [ResourceGroup] { groups.filter(\.hasAPK) }
    var otherGroups: [ResourceGroup] { groups.filter { !$0.hasAPK } }

    func speedResult(for resource: GameResource) -> ResourceSpeedResult? {
        speedResults[resource.id]
    }

    func load(_ work: WorkSummary) {
        task?.cancel()
        speedTask?.cancel()
        speedResults = [:]
        isSpeedTesting = false
        isLoading = true
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let batch = try await service.resources(for: work)
                guard !Task.isCancelled else { return }
                resources = batch.resources
                failures = batch.failures
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func addManual(_ resource: GameResource) {
        resources.insert(resource, at: 0)
    }

    func testSpeeds() {
        guard !isSpeedTesting, !filtered.isEmpty else { return }
        isSpeedTesting = true
        speedResults = [:]
        let items = filtered
        speedTask = Task { [weak self] in
            guard let self else { return }
            let results = await speedTester.testAll(items)
            guard !Task.isCancelled else { return }
            speedResults = results
            isSpeedTesting = false
        }
    }
}
