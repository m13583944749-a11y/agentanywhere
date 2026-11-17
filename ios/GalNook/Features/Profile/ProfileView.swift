import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum ProfileRecordFilter: Hashable {
    case all
    case state(WorkRecordState)
}

@MainActor
public struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store: ProfileStore

    @State private var draftName: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedSection = 0
    @State private var recordFilter = ProfileRecordFilter.all
    @State private var editingRecord: WorkRecord?
    @State private var editingReview: WorkReview?
    @State private var revealedSpoilers = Set<UUID>()
    @State private var importPresented = false
    @State private var exportPresented = false
    @State private var exportDocument: ProfileBackupDocument?
    @State private var isBusy = false
    @State private var errorMessage: String?

    public init(store: ProfileStore = .shared) {
        _store = StateObject(wrappedValue: store)
        _draftName = State(initialValue: store.displayName)
    }

    private var filteredRecords: [WorkRecord] {
        switch recordFilter {
        case .all:
            store.records
        case .state(let state):
            store.records(state: state)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                profileSection
                statisticsSection
                contentSection
                Section("更多") {
                    NavigationLink("收藏与浏览历史") { FavoritesView() }
                    NavigationLink("应用设置") { SettingsView() }
                }
            }
            .navigationTitle("个人资料")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            prepareExport()
                        } label: {
                            Label("导出完整备份", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            importPresented = true
                        } label: {
                            Label("导入完整备份", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("备份与恢复")
                }
            }
            .sheet(item: $editingRecord) { record in
                RecordEditorView(work: record.work, store: store)
            }
            .sheet(item: $editingReview) { review in
                ReviewEditorView(work: review.work, review: review, store: store)
            }
            .navigationDestination(for: WorkSummary.self) { work in
                WorkDetailView(work: work)
            }
            .fileImporter(
                isPresented: $importPresented,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .fileExporter(
                isPresented: $exportPresented,
                document: exportDocument,
                contentType: .json,
                defaultFilename: backupFilename
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await store.load()
                draftName = store.displayName
            }
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                ProfileAvatarImage(data: store.avatarData())
                    .id(store.avatarRevision)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("显示名", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit(saveDisplayName)
                            .onChange(of: draftName) { newValue in
                                let limited = String(newValue.prefix(ProfileStore.displayNameLimit))
                                if limited != newValue { draftName = limited }
                            }
                        Button("保存", action: saveDisplayName)
                            .disabled(isBusy || draftName == store.displayName)
                    }
                    Text("最多 \(ProfileStore.displayNameLimit) 字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(store.avatarFileName == nil ? "选择头像" : "更换头像", systemImage: "photo")
                }
                .disabled(isBusy)
                .onChange(of: selectedPhoto) { item in
                    guard let item else { return }
                    importAvatar(item)
                }
                if store.avatarFileName != nil {
                    Spacer()
                    Button("移除头像", role: .destructive) {
                        perform { try await store.removeAvatar() }
                    }
                    .disabled(isBusy)
                }
            }
        } header: {
            Text("我的资料")
        } footer: {
            Text("头像与资料保存在本机应用支持目录，并包含在 JSON 备份中。")
        }
    }

    private var statisticsSection: some View {
        Section {
            HStack(spacing: 0) {
                ProfileStatistic(value: model.favoriteWorks.count, title: "收藏", systemImage: "heart.fill")
                ProfileStatistic(value: store.playedCount, title: "已玩", systemImage: "checkmark.circle.fill")
                ProfileStatistic(value: store.reviewCount, title: "评论", systemImage: "text.bubble.fill")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        Section {
            Picker("内容", selection: $selectedSection) {
                Text("记录 \(store.records.count)").tag(0)
                Text("评论 \(store.reviews.count)").tag(1)
            }
            .pickerStyle(.segmented)

            if selectedSection == 0 {
                Picker("状态筛选", selection: $recordFilter) {
                    Text("全部状态").tag(ProfileRecordFilter.all)
                    ForEach(WorkRecordState.allCases) { state in
                        Text(state.displayName).tag(ProfileRecordFilter.state(state))
                    }
                }
            }
        }

        if selectedSection == 0 {
            Section(filteredRecords.isEmpty ? "游玩记录" : "游玩记录 · \(filteredRecords.count)") {
                if filteredRecords.isEmpty {
                    EmptyStateView(
                        title: "暂无记录",
                        systemImage: "gamecontroller",
                        description: "在作品详情页编辑游玩状态后，记录会显示在这里。"
                    )
                } else {
                    ForEach(filteredRecords) { record in
                        recordRow(record)
                    }
                }
            }
        } else {
            Section(store.reviews.isEmpty ? "我的评论" : "我的评论 · \(store.reviews.count)") {
                if store.reviews.isEmpty {
                    EmptyStateView(
                        title: "暂无评论",
                        systemImage: "text.bubble",
                        description: "评论由作品页的评论编辑器创建。"
                    )
                } else {
                    ForEach(store.reviews) { review in
                        reviewRow(review)
                    }
                }
            }
        }
    }

    private func recordRow(_ record: WorkRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: record.work) {
                WorkRow(work: record.work)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Label(record.state.displayName, systemImage: record.state.systemImage)
                    .foregroundStyle(record.state == .played ? Color.green : Color.accentColor)
                if let score = record.score {
                    Label("\(score) 分", systemImage: "star.fill")
                        .foregroundStyle(.orange)
                }
                if record.favorite {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                }
                Spacer()
                Button("编辑") { editingRecord = record }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                perform { try await store.deleteRecord(for: record.work) }
            }
            Button("编辑") { editingRecord = record }
                .tint(.accentColor)
        }
    }

    private func reviewRow(_ review: WorkReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: review.work) {
                HStack(spacing: 10) {
                    RemoteImage(url: review.work.coverURL)
                        .frame(width: 42, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(review.work.title).font(.headline).lineLimit(2)
                        Text(review.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                if let score = review.score {
                    Label("\(score) 分", systemImage: "star.fill").foregroundStyle(.orange)
                }
                if review.spoiler {
                    Label("剧透", systemImage: "eye.slash").foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑") { editingReview = review }
            }
            .font(.caption)

            if review.spoiler && !revealedSpoilers.contains(review.id) {
                Button("包含剧透，点击显示") {
                    revealedSpoilers.insert(review.id)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text(review.content)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if review.spoiler {
                    Button("隐藏剧透") { revealedSpoilers.remove(review.id) }
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 5)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                perform { try await store.deleteReview(review) }
            }
            Button("编辑") { editingReview = review }
                .tint(.accentColor)
        }
    }

    private var backupFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "GalNook-Profile-\(formatter.string(from: Date())).json"
    }

    private func saveDisplayName() {
        perform {
            try await store.updateDisplayName(draftName)
            draftName = store.displayName
        }
    }

    private func importAvatar(_ item: PhotosPickerItem) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ProfileStoreError.avatarUnavailable
                }
                try await store.updateAvatar(data: data)
                selectedPhoto = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func prepareExport() {
        do {
            exportDocument = ProfileBackupDocument(data: try store.exportBackup())
            exportPresented = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            perform {
                try await store.importBackup(from: url)
                draftName = store.displayName
                revealedSpoilers.removeAll()
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

private struct ProfileAvatarImage: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(7)
            }
        }
        .frame(width: 76, height: 76)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.quaternary, lineWidth: 0.5) }
        .accessibilityLabel("本地头像")
    }
}

private struct ProfileStatistic: View {
    let value: Int
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(Color.accentColor)
            Text("\(value)").font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
