import SwiftUI

struct WorkDetailView: View {
    let work: WorkSummary
    @EnvironmentObject private var model: AppModel
    @StateObject private var viewModel = WorkDetailViewModel()
    @StateObject private var profile = ProfileStore.shared
    @State private var selection = 0
    @State private var showsRecordEditor = false
    @State private var showsReviewEditor = false
    @State private var importingWalkthrough: Walkthrough?
    @State private var safariURL: URL?
    @State private var expandsDescription = false

    private var displayed: WorkSummary { viewModel.detail?.summary ?? work }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack {
                    Button { showsRecordEditor = true } label: {
                        Label("我的记录", systemImage: "list.clipboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { showsReviewEditor = true } label: {
                        Label("写评论", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Picker("内容", selection: $selection) {
                    Text("简介").tag(0)
                    Text("角色 \(viewModel.characters.count)").tag(1)
                    Text("攻略 \(viewModel.walkthroughs.count)").tag(2)
                    Text("资源").tag(3)
                    Text("评论").tag(4)
                }
                .pickerStyle(.segmented)
                switch selection {
                case 0: overview
                case 1: characters
                case 2: walkthroughs
                case 3: ResourcesView(work: displayed)
                default: comments
                }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(displayed.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                FavoriteButton(work: displayed)
                if let url = viewModel.detail?.links.first?.url {
                    ShareLink(item: url)
                }
            }
        }
        .task {
            model.recordVisit(work)
            viewModel.load(work)
            await profile.load()
        }
        .refreshable { viewModel.load(work) }
        .sheet(item: Binding<URL?>(
            get: { safariURL },
            set: { safariURL = $0 }
        )) { url in SafariView(url: url) }
        .sheet(isPresented: $showsRecordEditor, onDismiss: synchronizeFavorite) {
            RecordEditorView(work: displayed)
        }
        .sheet(isPresented: $showsReviewEditor) {
            ReviewEditorView(work: displayed)
        }
        .sheet(item: $importingWalkthrough) { item in
            RouteImportSheet(walkthrough: item, workTitle: displayed.title, characters: viewModel.characters.map(\.name))
        }
        .navigationDestination(for: GameCharacter.self) { CharacterDetailView(character: $0) }
        .navigationDestination(for: Walkthrough.self) { WalkthroughReaderView(walkthrough: $0) }
    }

    private func synchronizeFavorite() {
        let recordFavorite = profile.record(for: displayed)?.favorite ?? false
        if recordFavorite != model.isFavorite(displayed) {
            model.toggleFavorite(displayed)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(url: displayed.coverURL, width: 132)
            VStack(alignment: .leading, spacing: 9) {
                Text(displayed.title).font(.title3.bold())
                if let original = displayed.originalTitle, original != displayed.title {
                    Text(original).font(.caption).foregroundStyle(.secondary)
                }
                if !displayed.developerNames.isEmpty {
                    Label(displayed.developerNames.joined(separator: " / "), systemImage: "building.2")
                        .font(.subheadline)
                }
                if let date = displayed.releaseDate { Label(date, systemImage: "calendar").font(.subheadline) }
                HStack {
                    Label(GalFormatters.rating(displayed.rating), systemImage: "star.fill")
                        .foregroundStyle(.orange)
                    if let count = displayed.ratingCount { Text("(\(count) 人)") }
                }
                .font(.subheadline)
                Text(displayed.source.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var overview: some View {
        if viewModel.isLoading, viewModel.detail == nil { ProgressView().frame(maxWidth: .infinity) }
        if let error = viewModel.errorMessage, viewModel.detail == nil {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        }
        if let description = viewModel.detail?.description, !description.isEmpty {
            Text(description)
                .lineLimit(expandsDescription ? nil : 8)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(expandsDescription ? "收起" : "展开全部") { withAnimation { expandsDescription.toggle() } }
                .font(.subheadline)
        } else if !viewModel.isLoading {
            Text("暂无简介").foregroundStyle(.secondary)
        }
        if !displayed.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(displayed.tags, id: \.self) { tag in
                        Text(tag).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                }
            }
        }
        if let screenshots = viewModel.detail?.screenshots, !screenshots.isEmpty {
            SectionHeader(title: "画面预览")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(screenshots, id: \.self) { url in
                        RemoteImage(url: url)
                            .frame(width: 280, height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { safariURL = url }
                    }
                }
            }
        }
        if let staff = viewModel.detail?.staff, !staff.isEmpty {
            SectionHeader(title: "制作人员")
            ForEach(staff) { person in
                HStack { Text(person.role).foregroundStyle(.secondary); Spacer(); Text(person.name) }
                    .font(.subheadline)
                Divider()
            }
        }
        if let related = viewModel.detail?.relatedWorks, !related.isEmpty {
            SectionHeader(title: "关联作品")
            ForEach(related) { item in
                NavigationLink(value: item) {
                    WorkRow(work: item)
                }
                .buttonStyle(.plain)
            }
        }
        if let links = viewModel.detail?.links, !links.isEmpty {
            SectionHeader(title: "相关链接")
            ForEach(links) { link in
                Button { safariURL = link.url } label: {
                    Label(link.title, systemImage: "safari").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var characters: some View {
        Group {
            if viewModel.characters.isEmpty {
                EmptyStateView(title: "暂无角色资料", systemImage: "person.2")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) {
                    ForEach(viewModel.characters) { character in
                        NavigationLink(value: character) {
                            VStack {
                                RemoteImage(url: character.imageURL)
                                    .frame(height: 190)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(character.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                if let voice = character.voiceActor {
                                    Text(voice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var comments: some View {
        Group {
            if let comments = viewModel.detail?.comments, !comments.isEmpty {
                ForEach(comments) { RemoteCommentRow(comment: $0) }
            } else {
                Text("暂无远程评论").foregroundStyle(.secondary)
            }
            HStack {
                Text("我的评论").font(.title3.bold())
                Spacer()
                Button { showsReviewEditor = true } label: { Label("新增", systemImage: "plus") }
            }
            let localReviews = profile.reviews(for: displayed)
            if localReviews.isEmpty {
                Text("还没有本机评论").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(localReviews) { review in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if let score = review.score { Label("\(score) 分", systemImage: "star.fill").foregroundStyle(.orange) }
                            Spacer()
                            Text(review.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if review.spoiler { Label("此评论包含剧透", systemImage: "exclamationmark.triangle").font(.caption) }
                        Text(review.content).lineSpacing(5).textSelection(.enabled)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var walkthroughs: some View {
        Group {
            if viewModel.walkthroughs.isEmpty {
                EmptyStateView(title: "暂无攻略", systemImage: "map", description: "该来源没有返回攻略，仍可查看角色、简介和下载资源。")
            } else {
                ForEach(viewModel.walkthroughs) { item in
                    HStack(spacing: 8) {
                        NavigationLink(value: item) {
                            HStack {
                                Label(item.title, systemImage: "map")
                                Spacer()
                                if item.isAdultOnly { Text("R18").font(.caption2).foregroundStyle(.red) }
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            importingWalkthrough = item
                        } label: {
                            Label("导入", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

private struct RemoteCommentRow: View {
    let comment: RemoteComment
    @State private var expanded = false
    @State private var showsTranslation = true
    @State private var revealsSpoilers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(comment.author).font(.subheadline.weight(.semibold))
                if let rating = comment.rating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let date = comment.createdAt { Text(date).font(.caption2).foregroundStyle(.secondary) }
            }
            if comment.hasSpoilers, !revealsSpoilers {
                Button("包含剧透，点击显示") { revealsSpoilers = true }
                    .font(.subheadline)
            } else {
                let text = showsTranslation ? (comment.translatedContent ?? comment.content) : comment.content
                Text(text)
                    .lineLimit(expanded ? nil : 5)
                    .lineSpacing(5)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                HStack {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }
                    if comment.translatedContent != nil {
                        Button(showsTranslation ? "查看原文" : "查看译文") { showsTranslation.toggle() }
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
