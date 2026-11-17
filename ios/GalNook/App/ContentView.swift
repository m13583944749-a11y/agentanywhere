import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var downloads = DownloadManager()

    var body: some View {
        TabView(selection: $model.selectedTab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(AppTab.home)
            RoutesView()
                .tabItem { Label("攻略", systemImage: "map") }
                .tag(AppTab.routes)
            DownloadCenterView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(AppTab.downloads)
            LibraryView()
                .tabItem { Label("游戏库", systemImage: "books.vertical") }
                .tag(AppTab.library)
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .environmentObject(downloads)
        .task {
            DownloadActions.shared.register { resource in
                _ = downloads.enqueue(resource)
            }
            let panResolver = PanResolverActor()
            let adapter = PanDownloadResolverAdapter(resolver: panResolver)
            for provider in [PanProvider.quark, .uc, .baidu, .oneOneFive, .pan123, .lanzou] {
                downloads.registerResolver(adapter, for: provider)
            }
            await downloads.load()
            downloads.updateSettings(model.settings.download)
        }
        .onChange(of: model.settings.download) { downloads.updateSettings($0) }
        .sheet(isPresented: Binding(
            get: { !model.settings.acceptedDisclaimer },
            set: { _ in }
        )) {
            DisclaimerView()
                .interactiveDismissDisabled()
        }
    }
}
