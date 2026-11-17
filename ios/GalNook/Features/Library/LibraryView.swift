import SwiftUI
import UniformTypeIdentifiers

public struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var viewModel = LibraryViewModel()
    @State private var importMode: LibraryImportMode?
    @State private var selectedGame: LocalGame?
    @State private var deletingGame: LocalGame?

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("游戏库")
                .navigationBarTitleDisplayMode(.large)
                .searchable(
                    text: $viewModel.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索名称、引擎或目录"
                )
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .top, spacing: 0) { filterBar }
                .overlay { busyOverlay }
                .fileImporter(
                    isPresented: importerIsPresented,
                    allowedContentTypes: importMode == .folders ? [.folder] : [.item],
                    allowsMultipleSelection: true,
                    onCompletion: handleImport
                )
                .sheet(item: $viewModel.sharePackage, onDismiss: viewModel.dismissShare) { package in
                    ActivityViewController(activityItems: [package.url], completion: viewModel.dismissShare)
                        .ignoresSafeArea()
                }
                .confirmationDialog(
                    "删除游戏？",
                    isPresented: Binding(
                        get: { deletingGame != nil },
                        set: { if !$0 { deletingGame = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("删除文件夹和记录", role: .destructive) {
                        if let deletingGame {
                            viewModel.delete(deletingGame, model: model)
                        }
                        deletingGame = nil
                    }
                    Button("取消", role: .cancel) { deletingGame = nil }
                } message: {
                    Text("将删除“\(deletingGame?.title ?? "")”的整个游戏文件夹，此操作不会影响其他游戏。")
                }
                .alert("游戏库提示", isPresented: errorIsPresented) {
                    Button("好") { viewModel.errorMessage = nil }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
                .navigationDestination(isPresented: Binding(
                    get: { selectedGame != nil },
                    set: { if !$0 { selectedGame = nil } }
                )) {
                    if let selectedGame {
                        LibraryGameDetailView(game: selectedGame, viewModel: viewModel)
                    }
                }
                .task { await viewModel.refresh(model: model) }
        }
    }

    @ViewBuilder
    private var content: some View {
        let games = viewModel.filteredGames(from: model.games)
        if games.isEmpty {
            emptyView
        } else if viewModel.layout == .grid {
            gameGrid(games)
        } else {
            gameList(games)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    viewModel.selectedEngine = nil
                } label: {
                    if viewModel.selectedEngine == nil {
                        Label("全部引擎", systemImage: "checkmark")
                    } else {
                        Text("全部引擎")
                    }
                }
                ForEach(GameEngine.allCases) { engine in
                    Button {
                        viewModel.selectedEngine = engine
                    } label: {
                        if viewModel.selectedEngine == engine {
                            Label(engine.displayName, systemImage: "checkmark")
                        } else {
                            Text(engine.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(viewModel.selectedEngine?.displayName ?? "全部引擎")
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }

            Spacer()
            Text("\(viewModel.filteredGames(from: model.games).count) 个游戏")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewModel.layout = viewModel.layout == .grid ? .list : .grid
            } label: {
                Image(systemName: viewModel.layout == .grid ? "list.bullet" : "square.grid.2x2")
            }
            .accessibilityLabel(viewModel.layout == .grid ? "切换为列表" : "切换为网格")

            Menu {
                Button {
                    importMode = .folders
                } label: {
                    Label("导入文件夹", systemImage: "folder")
                }
                Button {
                    importMode = .files
                } label: {
                    Label("导入文件或压缩包", systemImage: "doc.zipper")
                }
                Divider()
                Button {
                    Task { await viewModel.refresh(model: model) }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("导入游戏")
        }
    }

    private func gameGrid(_ games: [LocalGame]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 14)],
                spacing: 16
            ) {
                ForEach(games) { game in
                    Button { selectedGame = game } label: {
                        LibraryGameCard(game: game)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { gameMenu(game) }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func gameList(_ games: [LocalGame]) -> some View {
        List(games) { game in
            Button { selectedGame = game } label: {
                LibraryGameRow(game: game)
            }
            .buttonStyle(.plain)
            .contextMenu { gameMenu(game) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { deletingGame = game } label: {
                    Label("删除", systemImage: "trash")
                }
                Button { viewModel.share(game, format: .folder) } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .leading) {
                Button { selectedGame = game } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func gameMenu(_ game: LocalGame) -> some View {
        Button { selectedGame = game } label: {
            Label("详情与修改", systemImage: "pencil")
        }
        Button { viewModel.share(game, format: .folder) } label: {
            Label("分享完整文件夹给咔咔喵", systemImage: "folder")
        }
        Button { viewModel.share(game, format: .zip) } label: {
            Label("导出 ZIP 分享给咔咔喵", systemImage: "doc.zipper")
        }
        Divider()
        Button(role: .destructive) { deletingGame = game } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: model.games.isEmpty ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.games.isEmpty ? "还没有游戏" : "没有匹配的游戏")
                .font(.title2.weight(.semibold))
            Text(model.games.isEmpty
                 ? "导入文件夹，或选择启动文件、资源文件和压缩包。导入后会自动识别引擎。"
                 : "试试其他关键词或清除引擎筛选。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if model.games.isEmpty {
                HStack {
                    Button("导入文件夹") { importMode = .folders }
                        .buttonStyle(.borderedProminent)
                    Button("导入文件") { importMode = .files }
                        .buttonStyle(.bordered)
                }
            } else {
                Button("清除筛选") {
                    viewModel.searchText = ""
                    viewModel.selectedEngine = nil
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if let message = viewModel.busyMessage {
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .font(.subheadline)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 8)
        }
    }

    private var importerIsPresented: Binding<Bool> {
        Binding(
            get: { importMode != nil },
            set: { if !$0 { importMode = nil } }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let mode = importMode ?? .files
        importMode = nil
        switch result {
        case .success(let urls):
            viewModel.importURLs(urls, mode: mode, model: model)
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private struct LibraryGameCard: View {
    let game: LocalGame

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryCoverPlaceholder(title: game.title)
                .frame(height: 116)
            VStack(alignment: .leading, spacing: 5) {
                Text(game.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(game.engine.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: game.engine.supportedByKrKrCat ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(game.engine.supportedByKrKrCat ? .green : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(game.engine.supportedByKrKrCat ? "咔咔喵支持" : "咔咔喵未声明支持")
                    .font(.caption2)
                    .foregroundStyle(game.engine.supportedByKrKrCat ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryGameRow: View {
    let game: LocalGame

    var body: some View {
        HStack(spacing: 12) {
            LibraryCoverPlaceholder(title: game.title)
                .frame(width: 58, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(game.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(game.engine.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(
                    game.engine.supportedByKrKrCat ? "咔咔喵支持" : "咔咔喵未声明支持",
                    systemImage: game.engine.supportedByKrKrCat ? "checkmark.circle.fill" : "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(game.engine.supportedByKrKrCat ? .green : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct LibraryCoverPlaceholder: View {
    let title: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.purple.opacity(0.78), Color.blue.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 38))
                .foregroundStyle(.white.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            Text(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
