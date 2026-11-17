import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = 0
    @State private var searchText = ""

    private var filteredFavorites: [WorkSummary] {
        guard !searchText.isEmpty else { return model.favoriteWorks }
        return model.favoriteWorks.filter { $0.searchableText.contains(searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }
    }

    private var filteredHistory: [HistoryEntry] {
        guard !searchText.isEmpty else { return model.history }
        return model.history.filter { $0.work.searchableText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("类型", selection: $selection) {
                    Text("收藏 \(model.favoriteWorks.count)").tag(0)
                    Text("历史 \(model.history.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                if selection == 0 {
                    ForEach(filteredFavorites) { work in
                        NavigationLink(value: work) { WorkRow(work: work, showsFavorite: true) }
                    }
                } else {
                    ForEach(filteredHistory) { entry in
                        NavigationLink(value: entry.work) {
                            VStack(alignment: .leading) {
                                WorkRow(work: entry.work)
                                Text("浏览于 \(entry.visitedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                model.history.removeAll { $0.id == entry.id }
                                model.settingsChanged()
                            }
                        }
                    }
                }
            }
            .overlay {
                if selection == 0, filteredFavorites.isEmpty {
                    EmptyStateView(title: searchText.isEmpty ? "还没有收藏" : "没有匹配的收藏", systemImage: "heart", description: "在作品详情页点击爱心即可收藏。")
                } else if selection == 1, filteredHistory.isEmpty {
                    EmptyStateView(title: "暂无浏览记录", systemImage: "clock")
                }
            }
            .navigationTitle("我的作品")
            .searchable(text: $searchText)
            .toolbar {
                if selection == 1, !model.history.isEmpty {
                    Button("清空", role: .destructive) { model.clearHistory() }
                }
            }
            .navigationDestination(for: WorkSummary.self) { WorkDetailView(work: $0) }
        }
    }
}
