import SwiftUI
import UIKit

@MainActor
private final class RemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false

    private static let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()

    private var task: Task<Void, Never>?
    private var loadedURL: URL?

    func load(_ url: URL?) {
        guard let url else {
            task?.cancel()
            image = nil
            isLoading = false
            loadedURL = nil
            return
        }
        if loadedURL == url, image != nil { return }
        if let cached = Self.memoryCache.object(forKey: url as NSURL) {
            task?.cancel()
            image = cached
            loadedURL = url
            isLoading = false
            return
        }

        task?.cancel()
        loadedURL = url
        image = nil
        isLoading = true
        task = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .returnCacheDataElseLoad
            // NextMoe's image CDN rejects generic URLSession clients with 403.
            request.setValue(
                "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let decoded = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                Self.memoryCache.setObject(decoded, forKey: url as NSURL, cost: data.count)
                guard !Task.isCancelled, self?.loadedURL == url else { return }
                self?.image = decoded
                self?.isLoading = false
            } catch {
                guard !Task.isCancelled, self?.loadedURL == url else { return }
                self?.image = nil
                self?.isLoading = false
                self?.loadedURL = nil
            }
        }
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var showsPlaceholderIcon = true
    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        ZStack {
            placeholder
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if loader.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: url) { loader.load(url) }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if showsPlaceholderIcon, loader.image == nil, !loader.isLoading {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CoverImage: View {
    let url: URL?
    var width: CGFloat = 112
    var aspectRatio: CGFloat = 0.72

    var body: some View {
        Color.clear
            .frame(width: width, height: width / aspectRatio)
            .overlay {
                RemoteImage(url: url)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}
