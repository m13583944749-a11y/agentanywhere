import SwiftUI

@MainActor
public struct ReviewEditorView: View {
    let work: WorkSummary

    @StateObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var reviewID: UUID
    @State private var score: Int?
    @State private var content: String
    @State private var spoiler: Bool
    @State private var createdAt: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let isEditing: Bool

    public init(
        work: WorkSummary,
        review: WorkReview? = nil,
        store: ProfileStore = .shared
    ) {
        self.work = work
        self.isEditing = review != nil
        _store = StateObject(wrappedValue: store)
        _reviewID = State(initialValue: review?.id ?? UUID())
        _score = State(initialValue: review?.score)
        _content = State(initialValue: review?.content ?? "")
        _spoiler = State(initialValue: review?.spoiler ?? false)
        _createdAt = State(initialValue: review?.createdAt ?? Date())
    }

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("评论作品") {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteImage(url: work.coverURL)
                            .frame(width: 56, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(work.title).font(.headline)
                            Text(work.source.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("评分与内容") {
                    Picker("评分", selection: $score) {
                        Text("未评分").tag(Int?.none)
                        ForEach(0...10, id: \.self) { value in
                            Text("\(value) 分").tag(Int?.some(value))
                        }
                    }
                    TextEditor(text: $content)
                        .frame(minHeight: 160)
                        .accessibilityLabel("评论内容")
                    Text("\(content.count) 字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Section {
                    Toggle("包含剧透", isOn: $spoiler)
                } footer: {
                    Text("剧透评论在个人页默认隐藏，点击后可以显示。")
                }

                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text(isEditing ? "保存修改" : "发布评论").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(trimmedContent.isEmpty || isSaving || !store.isLoaded)
                }
            }
            .disabled(!store.isLoaded)
            .navigationTitle(isEditing ? "编辑评论" : "写评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(trimmedContent.isEmpty || isSaving || !store.isLoaded)
                }
            }
            .task { await store.loadIfNeeded() }
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard !isSaving, store.isLoaded, !trimmedContent.isEmpty else { return }
        isSaving = true
        let review = WorkReview(
            id: reviewID,
            work: work,
            score: score,
            content: trimmedContent,
            spoiler: spoiler,
            createdAt: createdAt
        )
        Task {
            do {
                try await store.saveReview(review)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
