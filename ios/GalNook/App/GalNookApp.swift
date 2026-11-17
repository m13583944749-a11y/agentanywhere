import SwiftUI

@main
struct GalNookApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(model.accentColor)
                .preferredColorScheme(model.colorScheme)
                .task { model.load() }
                .alert("提示", isPresented: Binding(
                    get: { model.presentedError != nil },
                    set: { if !$0 { model.presentedError = nil } }
                )) {
                    Button("好") { model.presentedError = nil }
                } message: {
                    Text(model.presentedError ?? "")
                }
        }
    }
}

private extension AppModel {
    var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var accentColor: Color {
        switch settings.accentColor {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .green: .green
        case .orange: .orange
        }
    }
}
