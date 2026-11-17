import SwiftUI

struct WorkCard: View {
    let work: WorkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: work.coverURL)
                    .aspectRatio(0.72, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let rating = work.rating {
                    Text(String(format: "%.1f", rating))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(7)
                }
            }
            Text(work.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text(work.source.displayName)
                if let date = work.releaseDate, !date.isEmpty {
                    Text("·")
                    Text(date)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(work.title)，\(work.source.displayName)")
    }
}

struct WorkRow: View {
    let work: WorkSummary
    var showsFavorite = false
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: work.coverURL, width: 78)
            VStack(alignment: .leading, spacing: 7) {
                Text(work.title)
                    .font(.headline)
                    .lineLimit(2)
                if let original = work.originalTitle, original != work.title {
                    Text(original)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !work.developerNames.isEmpty {
                    Text(work.developerNames.joined(separator: " / "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    if let rating = work.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.orange)
                    }
                    if let date = work.releaseDate { Text(date) }
                    Text(work.source.displayName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showsFavorite {
                Button {
                    model.toggleFavorite(work)
                } label: {
                    Image(systemName: model.isFavorite(work) ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isFavorite(work) ? .red : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AdaptiveWorkGrid: View {
    let works: [WorkSummary]
    var minimumWidth: CGFloat = 142

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumWidth, maximum: 190), spacing: 16, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(works) { work in
                NavigationLink(value: work) {
                    WorkCard(work: work)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    FavoriteButton(work: work)
                    if let url = work.coverURL {
                        ShareLink(item: url)
                    }
                }
            }
        }
    }
}

struct FavoriteButton: View {
    let work: WorkSummary
    @EnvironmentObject private var model: AppModel
    @StateObject private var profile = ProfileStore.shared

    var body: some View {
        Button {
            model.toggleFavorite(work)
            let favorite = model.isFavorite(work)
            Task { try? await profile.setFavorite(favorite, for: work) }
        } label: {
            Label(
                model.isFavorite(work) ? "取消收藏" : "收藏",
                systemImage: model.isFavorite(work) ? "heart.slash" : "heart"
            )
        }
    }
}
