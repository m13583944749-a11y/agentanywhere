import SwiftUI

struct DisclaimerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                    Text("欢迎使用 GalNook")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity)
                    Group {
                        Text("GalNook 是视觉小说信息索引与个人记录工具，提供作品资料、评分、角色与攻略查询，以及第三方资源链接管理。")
                        Text("应用不托管游戏本体。第三方作品信息、下载链接与资源内容均由对应服务提供；下载和运行能力取决于来源及你所使用的播放器。")
                        Text("iOS 版通过系统文件分享与咔咔喵等播放器协作，不包含 Android 的 GalBuilt 运行环境。请妥善保管自己的网盘凭证和游戏文件。")
                    }
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)
                    Button {
                        model.settings.acceptedDisclaimer = true
                        model.settingsChanged()
                    } label: {
                        Text("同意并继续")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)
                }
                .padding(24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationBarHidden(true)
        }
    }
}
