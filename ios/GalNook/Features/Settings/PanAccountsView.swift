import SwiftUI

struct PanAccountsView: View {
    private let store = PanAccountStore()
    @State private var values: [String: String] = [:]
    @State private var savedAccount: String?

    private let accounts: [(key: String, name: String, note: String)] = [
        (PanAccountStore.quark, "夸克网盘", "游客解析失败或达到限制时需要 Cookie"),
        (PanAccountStore.uc, "UC 网盘", "使用桌面端登录后的完整 Cookie"),
        (PanAccountStore.baidu, "百度网盘", "部分分享和下载需要有效 Cookie"),
        (PanAccountStore.pan115, "115", "需要登录后的完整 Cookie"),
        (PanAccountStore.pan123, "123 云盘 Cookie", "可留空；签名令牌在下方单独填写"),
        (PanAccountStore.ilanzou, "蓝奏优享版", "仅在对应分享要求登录时填写"),
        (PanAccountStore.xunlei, "迅雷云盘", "仅保存账号，当前无内置直链客户端"),
        (PanAccountStore.caiyun, "139 和彩云", "仅保存账号，当前无内置直链客户端"),
        (PanAccountStore.guangya, "光年 Pan", "仅保存账号，当前无内置直链客户端")
    ]

    var body: some View {
        List {
            Section {
                Text("Cookie 和 Token 仅保存到本机钥匙串，不写入作品缓存、设置 JSON 或备份。应用不要求也不保存网盘密码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.key) { account in
                Section {
                    SecureField("完整 Cookie", text: Binding(
                        get: { values[account.key] ?? "" },
                        set: { values[account.key] = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    HStack {
                        Button(values[account.key]?.isEmpty == false ? "保存" : "已保存") {
                            _ = store.setCookie(values[account.key], for: account.key)
                            savedAccount = account.key
                        }
                        .disabled(values[account.key]?.isEmpty != false)
                        Button("退出并清除", role: .destructive) {
                            _ = store.removeAccount(account.key)
                            values[account.key] = ""
                        }
                        .disabled((values[account.key] ?? "").isEmpty)
                    }
                } header: {
                    Text(account.name)
                } footer: {
                    Text(account.note)
                }
            }
            Section("123 authorToken") {
                SecureField("localStorage.authorToken", text: Binding(
                    get: { values[PanAccountStore.pan123Token] ?? "" },
                    set: { values[PanAccountStore.pan123Token] = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button("保存 Token") {
                    _ = store.setPan123AuthorToken(values[PanAccountStore.pan123Token])
                    savedAccount = PanAccountStore.pan123Token
                }
            }
        }
        .navigationTitle("网盘账号")
        .task {
            for account in accounts { values[account.key] = store.value(for: account.key) ?? "" }
            values[PanAccountStore.pan123Token] = store.pan123AuthorToken ?? ""
        }
        .alert("已保存到钥匙串", isPresented: Binding(get: { savedAccount != nil }, set: { if !$0 { savedAccount = nil } })) {
            Button("好") {}
        }
    }
}
