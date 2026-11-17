import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var viewModel = HomeViewModel()
    @State private var showsSourcePicker = false
    @State private var showsFilters = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !model.history.isEmpty, viewModel.searchText.isEmpty {
                        historySection
                    }
                    categoryPicker
                    if !viewModel.sourceFailures.isEmpty {
                        Label("部分来源不可用：\(viewModel.sourceFailures.joined(separator: "；"))", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    }
                    if viewModel.isLoading, viewModel.works.isEmpty {
                        ProgressView("正在加载作品…")
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else if let error = viewModel.errorMessage, viewModel.works.isEmpty {
                        ErrorStateView(message: error) { viewModel.reload() }
                    } else if viewModel.works.isEmpty, !viewModel.isLoading {
                        EmptyStateView(
                            title: viewModel.searchText.isEmpty ? "暂无作品" : "没有找到相关作品",
                            systemImage: "magnifyingglass",
                            description: "可以尝试其他关键词，或在数据源中启用更多来源。"
                        )
                    } else {
                        AdaptiveWorkGrid(works: viewModel.works)
                            .padding(.horizontal)
                        if viewModel.hasMore {
                            Button {
                                if let last = viewModel.works.last { viewModel.loadMoreIfNeeded(current: last) }
                            } label: {
                                if viewModel.isLoadingMore { ProgressView() } else { Text("加载更多") }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("GalNook")
            .searchable(text: $viewModel.searchText, prompt: "搜索作品、会社或原名")
            .onSubmit(of: .search) { viewModel.searchSubmitted() }
            .onChange(of: viewModel.searchText) { _ in viewModel.searchChanged() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.selectedTab = .downloads } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("下载中心")
                    Button { showsFilters = true } label: {
                        Image(systemName: viewModel.filter.isActive ? "slider.horizontal.3" : "slider.horizontal.3")
                            .overlay(alignment: .topTrailing) {
                                if viewModel.filter.isActive { Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -3) }
                            }
                    }
                    .accessibilityLabel("筛选与排序")
                    Button { showsSourcePicker = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("数据源")
                }
            }
            .refreshable { viewModel.reload() }
            .task {
                viewModel.configure(sources: model.settings.enabledSources, includeAdult: model.settings.showsAdultContent)
                if viewModel.works.isEmpty, !viewModel.isLoading { viewModel.reload() }
            }
            .onChange(of: model.settings.enabledSources) { sources in
                viewModel.configure(sources: sources, includeAdult: model.settings.showsAdultContent)
            }
            .navigationDestination(for: WorkSummary.self) { work in
                WorkDetailView(work: work)
            }
            .sheet(isPresented: $showsSourcePicker) { sourcePicker }
            .sheet(isPresented: $showsFilters) {
                WorkFilterView(viewModel: viewModel)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近浏览", subtitle: "\(model.history.count) 条", systemImage: "clock")
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(model.history.prefix(12)) { entry in
                        NavigationLink(value: entry.work) {
                            VStack {
                                CoverImage(url: entry.work.coverURL, width: 66)
                                Text(entry.work.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(HomeViewModel.Category.allCases) { category in
                    Button {
                        viewModel.selectCategory(category)
                    } label: {
                        Text(category.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(viewModel.category == category && viewModel.searchText.isEmpty ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
                            .foregroundStyle(viewModel.category == category && viewModel.searchText.isEmpty ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var sourcePicker: some View {
        NavigationStack {
            List {
                Section("作品来源") {
                    ForEach([WorkSource.nextMoe, .vndb, .ymgal, .cnGal]) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { model.settings.enabledSources.contains(source) },
                            set: { enabled in
                                if enabled { model.settings.enabledSources.insert(source) }
                                else if model.settings.enabledSources.count > 1 { model.settings.enabledSources.remove(source) }
                                model.settingsChanged()
                            }
                        ))
                    }
                }
                Section {
                    Text("月幕主要用于关键词搜索；首页推荐优先由 NextMoe、VNDB 和 CnGal 提供。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("数据源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { showsSourcePicker = false } }
        }
        .presentationDetents([.medium])
    }
}
