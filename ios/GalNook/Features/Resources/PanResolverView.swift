import SwiftUI
import UIKit

struct PanResolverView: View {
    @EnvironmentObject private var model: AppModel
    @State private var shareText = ""
    @State private var passcode = ""
    @State private var resolution: PanResolution?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var copiedURL = false
    private let resolver = PanResolverActor()

    var body: some View {
        Form {
            Section("分享链接") {
                TextField("https://pan.quark.cn/s/…", text: $shareText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(2...4)
                SecureField("提取码（可空）", text: $passcode)
                Button {
                    Task { await resolve() }
                } label: {
                    if isLoading { HStack { ProgressView(); Text("正在解析…") } }
                    else { Label("解析文件列表", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(isLoading || shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Section("解析失败") {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    Button("复制错误") { UIPasteboard.general.string = errorMessage }
                }
            }
            if let resolution {
                Section {
                    Text(resolution.note.isEmpty ? "共 \(resolution.files.count) 个文件" : resolution.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("\(resolution.site) · \(resolution.files.count) 个文件")
                }
                Section("文件") {
                    ForEach(resolution.files) { file in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(file.name).font(.headline)
                            if !file.size.isEmpty { Text(file.size).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("下载") { download(file) }
                                    .buttonStyle(.borderedProminent)
                                Button("复制直链") {
                                    UIPasteboard.general.string = file.url
                                    copiedURL = true
                                }
                                ShareLink(item: file.url)
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("支持范围") {
                Text("夸克、UC、百度、115、123、蓝奏及蓝奏优享版可尝试解析。迅雷、139、光年链接会保留原始页面入口，不伪造直链结果。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("网盘解析")
        .alert("直链已复制", isPresented: $copiedURL) { Button("好") {} }
    }

    private func resolve() async {
        guard let url = URL(string: shareText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "分享链接格式无效"
            return
        }
        isLoading = true
        errorMessage = nil
        resolution = nil
        do {
            resolution = try await resolver.resolve(shareURL: url, passcode: passcode.nilIfBlank)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func download(_ file: PanFile) {
        guard let resolved = file.resolvedDownload else {
            errorMessage = "该文件的下载地址无效"
            return
        }
        let resource = GameResource(
            title: file.name,
            sourceName: resolution?.site ?? "网盘",
            directURL: resolved.url,
            provider: .direct,
            fileName: file.name,
            fileSize: file.sizeBytes,
            downloadHeaders: resolved.headers
        )
        if DownloadActions.shared.enqueue(resource) {
            model.selectedTab = .downloads
        }
    }
}
