import SwiftUI

@MainActor
public struct RecordEditorView: View {
    let work: WorkSummary

    @StateObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var state: WorkRecordState
    @State private var score: Int?
    @State private var favorite: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(work: WorkSummary, store: ProfileStore = .shared) {
        self.work = work
        _store = StateObject(wrappedValue: store)
        let record = store.record(for: work)
        _state = State(initialValue: record?.state ?? .unmarked)
        _score = State(initialValue: record?.score)
        _favorite = State(initialValue: record?.favorite ?? false)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("作品") {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteImage(url: work.coverURL)
                            .frame(width: 64, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(work.title).font(.headline)
                            if let originalTitle = work.originalTitle,
                               originalTitle != work.title {
                                Text(originalTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(work.source.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("游玩记录") {
                    Picker("状态", selection: $state) {
                        ForEach(WorkRecordState.allCases) { state in
                            Label(state.displayName, systemImage: state.systemImage)
                                .tag(state)
                        }
                    }
                    Picker("评分", selection: $score) {
                        Text("未评分").tag(Int?.none)
                        ForEach(0...10, id: \.self) { value in
                            Text("\(value) 分").tag(Int?.some(value))
                        }
                    }
                    Toggle("收藏此作品", isOn: $favorite)
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("保存记录").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSaving || !store.isLoaded)
                }
            }
            .disabled(!store.isLoaded)
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(isSaving || !store.isLoaded)
                }
            }
            .task {
                await store.loadIfNeeded()
                synchronizeRecord()
            }
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

    private func synchronizeRecord() {
        let record = store.record(for: work)
        state = record?.state ?? .unmarked
        score = record?.score
        favorite = record?.favorite ?? false
    }

    private func save() {
        guard !isSaving, store.isLoaded else { return }
        isSaving = true
        Task {
            do {
                try await store.updateRecord(
                    for: work,
                    state: state,
                    score: score,
                    favorite: favorite
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
