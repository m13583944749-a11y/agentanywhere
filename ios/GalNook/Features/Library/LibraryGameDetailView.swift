import SwiftUI

struct LibraryGameDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LibraryViewModel

    let game: LocalGame
    @State private var title: String
    @State private var engine: GameEngine
    @State private var launchPath: String
    @State private var detection: EngineDetectionResult?
    @State private var candidates: [String] = []
    @State private var confirmsDeletion = false

    init(game: LocalGame, viewModel: LibraryViewModel) {
        self.game = game
        self.viewModel = viewModel
        _title = State(initialValue: game.title)
        _engine = State(initialValue: game.engine)
        _launchPath = State(initialValue: game.launchPath ?? "")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    LibraryCoverPlaceholder(title: title.isEmpty ? game.title : title)
                        .frame(width: 86, height: 100)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(engine.displayName)
                            .font(.headline)
                        Label(
                            engine.supportedByKrKrCat ? "咔咔喵支持此引擎" : "咔咔喵未声明支持此引擎",
                            systemImage: engine.supportedByKrKrCat ? "checkmark.circle.fill" : "questionmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(engine.supportedByKrKrCat ? .green : .secondary)
                        Text("仍可通过系统分享面板导出完整文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            Section("手动修改") {
                TextField("游戏名称", text: $title)
                Picker("引擎", selection: $engine) {
                    ForEach(GameEngine.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                TextField("启动文件相对路径", text: $launchPath, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if !candidates.isEmpty {
                    Picker("现有启动候选", selection: $launchPath) {
                        Text("不指定启动文件").tag("")
                        ForEach(candidates, id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Button("保存修改") { save() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("识别证据") {
                if let detection {
                    LabeledContent("识别引擎", value: detection.engine.displayName)
                    ForEach(Array(detection.evidence.enumerated()), id: \.offset) { _, evidence in
                        Label(evidence, systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let launch = detection.launchRelativePath {
                        LabeledContent("自动启动文件", value: launch)
                    }
                } else {
                    HStack {
                        ProgressView()
                        Text("正在读取文件证据…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("存储") {
                LabeledContent("游戏目录") {
                    Text(game.rootPath.isEmpty ? "游戏库根目录" : game.rootPath)
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                }
                if let sourceArchive = game.sourceArchive {
                    LabeledContent("来源压缩包", value: sourceArchive)
                }
                if let url = viewModel.gameURL(for: game) {
                    ShareLink(item: url) {
                        Label("用系统分享面板分享文件夹", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("分享给咔咔喵") {
                Text("选择咔咔喵作为分享目标；ZIP 会包含完整游戏目录，不会只发送启动文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.share(game, format: .folder)
                } label: {
                    Label("分享完整文件夹", systemImage: "folder")
                }
                Button {
                    viewModel.share(game, format: .zip)
                } label: {
                    Label("生成 ZIP 并分享", systemImage: "doc.zipper")
                }
            }
            .disabled(viewModel.isBusy)

            Section {
                Button(role: .destructive) { confirmsDeletion = true } label: {
                    Label("删除游戏文件夹和记录", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task {
            async let detected = viewModel.detection(for: game)
            async let paths = viewModel.launchCandidates(for: game)
            detection = await detected
            candidates = await paths
        }
        .confirmationDialog("删除整个游戏文件夹？", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                viewModel.delete(game, model: model)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(game.rootPath.isEmpty ? game.title : game.rootPath)
        }
    }

    private func save() {
        if viewModel.update(
            game,
            title: title,
            engine: engine,
            launchPath: launchPath,
            model: model
        ) {
            dismiss()
        }
    }
}
