import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ResourcesView: View {
    let work: WorkSummary
    @StateObject private var viewModel = ResourcesViewModel()
    @State private var showsAddResource = false
    @State private var safariURL: URL?
    @State private var copiedText: String?
    @State private var expandedGroups = Set<String>()
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("仅看适合咔咔喵", isOn: $viewModel.compatibleOnly)
                    .font(.subheadline)
                Spacer()
                Button { showsAddResource = true } label: {
                    Label("添加", systemImage: "plus")
                }
            }
            HStack {
                Text("共 \(viewModel.filtered.count) 条资源 · \(viewModel.groups.count) 个资源站")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.testSpeeds()
                } label: {
                    if viewModel.isSpeedTesting {
                        HStack(spacing: 5) { ProgressView().controlSize(.small); Text("测速中…") }
                    } else {
                        Label("开始测速", systemImage: "speedometer")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSpeedTesting || viewModel.filtered.isEmpty)
            }
            if viewModel.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在聚合下载线路，首次查询可能需要 15–30 秒…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            }
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !viewModel.apkGroups.isEmpty {
                Text("可能含有 APK 的资源站")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                ForEach(viewModel.apkGroups) { group in
                    resourceGroup(group)
                }
            }
            if !viewModel.otherGroups.isEmpty {
                Text("其他资源站")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(viewModel.otherGroups) { group in
                    resourceGroup(group)
                }
            }
            if !viewModel.isLoading, viewModel.filtered.isEmpty {
                EmptyStateView(
                    title: viewModel.compatibleOnly ? "没有明确兼容的资源" : "暂无下载线路",
                    systemImage: "arrow.down.to.line",
                    description: "可以添加自己的直链或网盘链接，也可以关闭兼容筛选查看全部结果。",
                    actionTitle: "添加下载链接",
                    action: { showsAddResource = true }
                )
            }
        }
        .task { viewModel.load(work) }
        .refreshable { viewModel.load(work) }
        .sheet(isPresented: $showsAddResource) {
            AddResourceView(work: work) { viewModel.addManual($0) }
        }
        .sheet(item: Binding<URL?>(get: { safariURL }, set: { safariURL = $0 })) { SafariView(url: $0) }
        .alert("已复制", isPresented: Binding(get: { copiedText != nil }, set: { if !$0 { copiedText = nil } })) {
            Button("好") {}
        } message: { Text(copiedText ?? "") }
    }

    @ViewBuilder
    private func resourceGroup(_ group: ResourcesViewModel.ResourceGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        VStack(spacing: 0) {
            Button {
                if isExpanded { expandedGroups.remove(group.id) }
                else { expandedGroups.insert(group.id) }
            } label: {
                HStack {
                    Text(group.sourceName).font(.headline)
                    Spacer()
                    Text("\(group.resources.count) 条")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Divider()
                VStack(spacing: 10) {
                    ForEach(group.resources) { resource in
                        ResourceRow(
                            resource: resource,
                            speed: viewModel.speedResult(for: resource),
                            open: { safariURL = $0 },
                            copy: { text in
                                UIPasteboard.general.string = text
                                copiedText = text
                            },
                            download: {
                                if DownloadActions.shared.enqueue(resource) {
                                    model.selectedTab = .downloads
                                } else if let url = resource.preferredURL {
                                    safariURL = url
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ResourceRow: View {
    let resource: GameResource
    var speed: ResourceSpeedResult?
    let open: (URL) -> Void
    let copy: (String) -> Void
    let download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: resource.isAndroidPackage ? "shippingbox" : "arrow.down.doc")
                    .font(.title2)
                    .foregroundStyle(resource.isAndroidPackage ? .orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(resource.title).font(.headline)
                    Text("\(resource.sourceName) · \(resource.provider.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if resource.engine != .unknown {
                        Text(resource.engine.displayName)
                            .font(.caption2)
                            .padding(5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    if let speed {
                        Text(speed.summary)
                            .font(.caption2)
                            .foregroundStyle(speed.error == nil ? .green : .secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                if let name = resource.fileName { Label(name, systemImage: "doc") }
                if let size = resource.fileSize, size > 0 { Label(GalFormatters.bytes(size), systemImage: "externaldrive") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            if resource.isAndroidPackage {
                Label("安卓 APK 不能直接导入咔咔喵", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if resource.engine.supportedByKrKrCat {
                Label("可下载后分享至咔咔喵", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let note = resource.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let password = resource.sharePassword ?? resource.extractionPassword {
                Button { copy(password) } label: {
                    Label("提取/解压密码：\(password)", systemImage: "key")
                        .font(.caption)
                }
            }
            HStack {
                if resource.directURL != nil || resource.shareURL != nil {
                    Button("下载", action: download).buttonStyle(.borderedProminent)
                }
                if let url = resource.pageURL ?? resource.shareURL {
                    Button("打开页面") { open(url) }.buttonStyle(.bordered)
                }
                if let url = resource.preferredURL { ShareLink(item: url) }
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AddResourceView: View {
    let work: WorkSummary
    let onAdd: (GameResource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var urlText = ""
    @State private var password = ""
    @State private var engine = GameEngine.unknown
    @State private var platform = GamePlatform.unknown
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("资源名称", text: $title)
                TextField("https://…", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("提取码或解压密码（可空）", text: $password)
                Picker("游戏引擎", selection: $engine) {
                    ForEach(GameEngine.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("平台", selection: $platform) {
                    ForEach(GamePlatform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("添加下载链接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { add() }.disabled(urlText.isEmpty)
                }
            }
        }
    }

    private func add() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            error = "请输入完整有效的 URL"
            return
        }
        let provider = PanProvider.detect(url: url)
        let resource = GameResource(
            workID: work.id,
            title: title.nilIfBlank ?? work.title,
            sourceName: "手动添加",
            pageURL: provider == .other ? url : nil,
            shareURL: provider == .other || provider == .direct ? nil : url,
            directURL: provider == .direct ? url : nil,
            sharePassword: password.nilIfBlank,
            platform: platform,
            engine: engine,
            isAndroidPackage: url.pathExtension.lowercased() == "apk"
        )
        onAdd(resource)
        dismiss()
    }
}
