import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsAdultConfirmation = false
    @State private var ymgalSecret = ""
    @State private var searchGalBase = "https://vercel.api.searchgal.top"
    @State private var cacheSize = "计算中…"
    @State private var showsCacheCleared = false
    private let keychain = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                sourcesSection
                displaySection
                contentSection
                downloadSection
                panSection
                storageSection
                aboutSection
            }
            .navigationTitle("设置")
            .onChange(of: model.settings) { settings in
                model.settingsChanged()
                UserDefaults.standard.set(settings.onlySearchGalResources, forKey: "only_searchgal")
            }
            .task {
                ymgalSecret = keychain.string(for: "ymgal.clientSecret") ?? ""
                searchGalBase = keychain.string(for: "searchgal.baseURL") ?? "https://vercel.api.searchgal.top"
                UserDefaults.standard.set(model.settings.onlySearchGalResources, forKey: "only_searchgal")
                calculateCacheSize()
            }
            .alert("显示成人内容？", isPresented: $showsAdultConfirmation) {
                Button("取消", role: .cancel) {}
                Button("确认显示") {
                    model.settings.confirmedAdultContent = true
                    model.settings.showsAdultContent = true
                }
            } message: { Text("开启后，支持该参数的查询会包含 NSFW 作品。关闭可随时恢复过滤。") }
            .alert("缓存已清理", isPresented: $showsCacheCleared) { Button("好") {} }
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach([WorkSource.nextMoe, .vndb, .ymgal, .cnGal]) { source in
                Toggle(source.displayName, isOn: Binding(
                    get: { model.settings.enabledSources.contains(source) },
                    set: { enabled in
                        if enabled { model.settings.enabledSources.insert(source) }
                        else if model.settings.enabledSources.count > 1 { model.settings.enabledSources.remove(source) }
                    }
                ))
            }
            Toggle("仅使用指定 SearchGal 实例", isOn: $model.settings.onlySearchGalResources)
            TextField("SearchGal 实例地址", text: $searchGalBase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: searchGalBase) { value in
                    let fallback = "https://vercel.api.searchgal.top"
                    keychain.setString(value.nilIfBlank ?? fallback, for: "searchgal.baseURL")
                }
            TextField("月幕 client_id（留空使用公共凭证）", text: Binding(
                get: { keychain.string(for: "ymgal.clientID") ?? "" },
                set: { keychain.setString($0.nilIfBlank, for: "ymgal.clientID") }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            SecureField("月幕 client_secret（留空使用公共凭证）", text: $ymgalSecret)
                .textInputAutocapitalization(.never)
                .onChange(of: ymgalSecret) { value in
                    keychain.setString(value.nilIfBlank, for: "ymgal.clientSecret")
                }
        } header: {
            Text("数据源")
        } footer: {
            Text("至少保留一个作品来源。月幕密钥仅存储在本机钥匙串，不会写入普通设置文件。")
        }
    }

    private var displaySection: some View {
        Section("外观") {
            Picker("外观模式", selection: $model.settings.appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("主题色", selection: $model.settings.accentColor) {
                ForEach(AccentColorPreference.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("加载作品图片", isOn: $model.settings.loadsImages)
        }
    }

    private var contentSection: some View {
        Section("内容与记录") {
            Toggle("显示 NSFW 作品", isOn: Binding(
                get: { model.settings.showsAdultContent },
                set: { enabled in
                    if enabled, !model.settings.confirmedAdultContent { showsAdultConfirmation = true }
                    else { model.settings.showsAdultContent = enabled }
                }
            ))
            NavigationLink("免责声明与使用说明") { DisclaimerDetailView() }
            Button("清空浏览记录") { model.clearHistory() }
                .disabled(model.history.isEmpty)
        }
    }

    private var downloadSection: some View {
        Section {
            Stepper("同时下载：\(model.settings.download.maximumConcurrent)", value: Binding(
                get: { model.settings.download.maximumConcurrent },
                set: { model.settings.download.maximumConcurrent = min(8, max(1, $0)) }
            ), in: 1...8)
            Stepper("单文件连接数：\(model.settings.download.connectionsPerFile)", value: Binding(
                get: { model.settings.download.connectionsPerFile },
                set: { model.settings.download.connectionsPerFile = min(16, max(1, $0)) }
            ), in: 1...16)
            Stepper("失败重试：\(model.settings.download.maximumRetries) 次", value: Binding(
                get: { model.settings.download.maximumRetries },
                set: { model.settings.download.maximumRetries = min(10, max(0, $0)) }
            ), in: 0...10)
            Toggle("允许蜂窝网络下载", isOn: $model.settings.download.allowsCellular)
            Toggle("下载后自动解压", isOn: $model.settings.download.automaticallyExtract)
            if model.settings.download.automaticallyExtract {
                Toggle("解压后删除原压缩包", isOn: $model.settings.download.deleteArchiveAfterExtraction)
            }
        } header: {
            Text("下载")
        } footer: {
            Text("多连接数用于支持 Range 的服务器；不支持时会自动使用普通下载。")
        }
    }

    private var panSection: some View {
        Section("网盘解析") {
            NavigationLink("解析分享链接") { PanResolverView() }
            NavigationLink("网盘账号与 Cookie") { PanAccountsView() }
            Text("直链解析会优先尝试免登录流程；遇到游客限制或 Cookie 失效时，可在账号页更新凭证。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("存储") {
            LabeledContent("图片缓存", value: cacheSize)
            Button("清理图片与临时缓存") {
                URLCache.shared.removeAllCachedResponses()
                try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory)
                calculateCacheSize()
                showsCacheCleared = true
            }
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
            LabeledContent("运行平台", value: "iOS / iPadOS 16+")
            Link("原 Android 项目", destination: URL(string: "https://github.com/Xiao-youyu/GalNook")!)
            Link("咔咔喵 App Store", destination: URL(string: "https://apps.apple.com/cn/app/id6796972501")!)
            Text("完整 iOS 复刻版。游戏运行由兼容的本地播放器完成。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func calculateCacheSize() {
        Task.detached {
            let bytes = URLCache.shared.currentDiskUsage
            let temporary = (try? FileManager.default.allocatedSizeOfDirectory(at: FileManager.default.temporaryDirectory)) ?? 0
            await MainActor.run { cacheSize = GalFormatters.bytes(Int64(bytes) + Int64(temporary)) }
        }
    }
}

private struct DisclaimerDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("服务性质").font(.title3.bold())
                Text("GalNook 提供第三方公开作品数据查询、链接管理、个人收藏、浏览记录与下载管理，不预置游戏内容。")
                Text("数据准确性").font(.title3.bold())
                Text("作品数据来自 NextMoe、VNDB、月幕、CnGal、SearchGal 等服务，可能延迟、缺失或由第三方维护。")
                Text("文件与凭证").font(.title3.bold())
                Text("下载文件保存在应用文档目录，删除应用会一并删除。网盘 Cookie、Token 和月幕密钥应保存在钥匙串中。")
                Text("播放器协作").font(.title3.bold())
                Text("KrKr、ONS、Ren’Py 游戏可通过系统分享导入咔咔喵；具体兼容性由游戏版本与播放器决定。")
            }
            .lineSpacing(5)
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("使用说明")
    }
}

private extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            total += UInt64(try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
