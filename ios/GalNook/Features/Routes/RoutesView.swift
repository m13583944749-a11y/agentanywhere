import SwiftUI

public struct RoutesView: View {
    @StateObject private var store: RouteStore
    @State private var searchText = ""
    @State private var deletingRoute: LocalRoute?

    public init(store: RouteStore = .shared) {
        _store = StateObject(wrappedValue: store)
    }

    private var filteredRoutes: [LocalRoute] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.routes }
        return store.routes.filter { route in
            let fields = [route.title, route.workTitle, route.character, route.displayStatus]
            if fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            return route.nodes.contains {
                $0.label.localizedCaseInsensitiveContains(query) ||
                $0.condition.localizedCaseInsensitiveContains(query) ||
                $0.notes.localizedCaseInsensitiveContains(query) ||
                $0.alternatives.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(filteredRoutes) { route in
                    NavigationLink {
                        RouteDetailView(routeID: route.id, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(route.title).font(.headline).lineLimit(2)
                                Spacer()
                                Text("\(route.nodes.count) 节点")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !route.workTitle.isEmpty {
                                Text(route.workTitle).font(.subheadline).lineLimit(1)
                            }
                            HStack(spacing: 8) {
                                if !route.character.isEmpty {
                                    Label(route.character, systemImage: "person")
                                }
                                Label(route.displayStatus, systemImage: "checkmark.circle")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text("更新于 \(route.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { deletingRoute = route }
                    }
                }
            }
            .overlay {
                if store.routes.isEmpty {
                    EmptyStateView(
                        title: "还没有离线路线",
                        systemImage: "map",
                        description: "在作品详情页选择攻略与角色导入，导入后可离线阅读、编辑和分享。"
                    )
                } else if filteredRoutes.isEmpty {
                    EmptyStateView(title: "没有匹配的路线", systemImage: "magnifyingglass")
                }
            }
            .navigationTitle("我的攻略")
            .searchable(text: $searchText, prompt: "搜索作品、角色或节点")
            .confirmationDialog(
                "删除这条路线？",
                isPresented: Binding(
                    get: { deletingRoute != nil },
                    set: { if !$0 { deletingRoute = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let route = deletingRoute {
                    Button("删除“\(route.title)”", role: .destructive) {
                        try? store.deleteRoute(id: route.id)
                        deletingRoute = nil
                    }
                }
                Button("取消", role: .cancel) { deletingRoute = nil }
            } message: {
                Text("路线及其全部本地节点将一并删除，此操作不可撤销。")
            }
        }
    }
}
