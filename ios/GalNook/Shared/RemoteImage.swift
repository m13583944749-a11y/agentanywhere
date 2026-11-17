import SwiftUI

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var showsPlaceholderIcon = true

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case .empty:
                placeholder
                    .overlay { ProgressView().controlSize(.small) }
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            case .failure:
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if showsPlaceholderIcon {
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
        RemoteImage(url: url)
            .frame(width: width, height: width / aspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}
