import Foundation

@MainActor
final class WorkDetailViewModel: ObservableObject {
    @Published var detail: WorkDetail?
    @Published var characters: [GameCharacter] = []
    @Published var walkthroughs: [Walkthrough] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: CatalogService
    private var loadTask: Task<Void, Never>?

    init(service: CatalogService = .shared) { self.service = service }

    func load(_ work: WorkSummary) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let detailRequest = service.detail(for: work)
                async let charactersRequest = service.characters(for: work)
                async let walkthroughsRequest = service.walkthroughsAcrossSources(for: work)
                let detail = try await detailRequest
                self.detail = detail
                self.characters = detail.characters
                let loadedCharacters = try? await charactersRequest
                if let loadedCharacters, !loadedCharacters.isEmpty {
                    self.characters = loadedCharacters
                }
                let loadedWalkthroughs = try? await walkthroughsRequest
                if let loadedWalkthroughs {
                    self.walkthroughs = loadedWalkthroughs
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
