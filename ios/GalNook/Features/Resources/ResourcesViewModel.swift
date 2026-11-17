import Foundation

@MainActor
final class ResourcesViewModel: ObservableObject {
    @Published var resources: [GameResource] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var failures: [String] = []
    @Published var compatibleOnly = false

    private let service: ResourceService
    private var task: Task<Void, Never>?

    init(service: ResourceService = .shared) { self.service = service }

    var filtered: [GameResource] {
        guard compatibleOnly else { return resources }
        return resources.filter { !$0.isAndroidPackage && ($0.engine == .unknown || $0.engine.supportedByKrKrCat) }
    }

    func load(_ work: WorkSummary) {
        task?.cancel()
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
}
