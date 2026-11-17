import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    enum Category: String, CaseIterable, Identifiable {
        case popular = "推荐"
        case latest = "最新"
        case highlyRated = "高分"
        case random = "随机"
        var id: String { rawValue }
    }

    @Published var works: [WorkSummary] = []
    @Published var searchText = ""
    @Published var category: Category = .popular
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var sourceFailures: [String] = []
    @Published var hasMore = false
    @Published var filter = WorkFilter()
    @Published var sortOption = WorkSort.popularity
    @Published var availableTags: [CatalogTag] = []

    private var page = 1
    private var task: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sources: Set<WorkSource> = [.nextMoe]
    private var includeAdult = false
    private let service: CatalogService

    init(service: CatalogService = .shared) { self.service = service }

    func configure(sources: Set<WorkSource>, includeAdult: Bool) {
        let changed = self.sources != sources || self.includeAdult != includeAdult
        self.sources = sources
        self.includeAdult = includeAdult
        if changed { reload() }
    }

    func selectCategory(_ value: Category) {
        category = value
        searchText = ""
        reload()
    }

    func searchSubmitted() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { reload(); return }
        page = 1
        load(reset: true)
    }

    func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.searchSubmitted() }
        }
    }

    func reload() {
        page = 1
        load(reset: true)
    }

    func resetFilters() {
        filter = WorkFilter()
        sortOption = .popularity
        reload()
    }

    func loadTags() async {
        guard availableTags.isEmpty else { return }
        availableTags = (try? await service.tags()) ?? []
    }

    func loadMoreIfNeeded(current: WorkSummary) {
        guard hasMore, !isLoadingMore, !isLoading,
              works.last?.id == current.id else { return }
        page += 1
        load(reset: false)
    }

    private func load(reset: Bool) {
        task?.cancel()
        if reset { isLoading = true } else { isLoadingMore = true }
        errorMessage = nil
        let query: WorkQuery
        if filter.isActive || sortOption != .popularity {
            query = .advanced(search: searchText.nilIfBlank, sort: sortOption, filter: filter)
        } else if let search = searchText.nilIfBlank {
            query = .search(search)
        } else {
            switch category {
            case .popular: query = .popular
            case .latest: query = .latest
            case .highlyRated: query = .highlyRated
            case .random: query = .random
            }
        }
        let requestedPage = page
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let batch = try await service.works(
                    query: query,
                    sources: sources,
                    page: requestedPage,
                    limit: 30,
                    includeAdult: includeAdult
                )
                guard !Task.isCancelled else { return }
                if reset { works = batch.works }
                else {
                    var seen = Set(works.map(\.id))
                    works.append(contentsOf: batch.works.filter { seen.insert($0.id).inserted })
                }
                hasMore = batch.hasMore
                sourceFailures = batch.failures
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                if !reset { page = max(1, page - 1) }
            }
            isLoading = false
            isLoadingMore = false
        }
    }
}
