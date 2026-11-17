import SafariServices
import SwiftUI
import WebKit

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = .systemPurple
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct WebView: UIViewRepresentable {
    let url: URL
    var onDownload: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onDownload: onDownload) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onDownload = onDownload
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onDownload: ((URL) -> Void)?

        init(onDownload: ((URL) -> Void)?) {
            self.onDownload = onDownload
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let archiveExtensions = ["zip", "rar", "7z", "lz4", "apk", "xp3"]
            if archiveExtensions.contains(url.pathExtension.lowercased()) {
                onDownload?(url)
                return .cancel
            }
            return .allow
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType] = []

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
