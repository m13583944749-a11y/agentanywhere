import SwiftUI

struct RouteImportSheet: View {
    let walkthrough: Walkthrough
    let workTitle: String
    let characters: [String]
    @StateObject private var store = RouteStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importsFullGuide = true
    @State private var selectedCharacters: Set<String> = []
    @State private var errorMessage: String?
    @State private var importedCount: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section("攻略") {
                    Text(walkthrough.title)
                    Text(workTitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("导入完整攻略", isOn: $importsFullGuide)
                } footer: {
                    Text("完整攻略保留全部章节；按角色导入时，只保留匹配角色名称的章节。")
                }
                if !importsFullGuide {
                    Section("选择角色") {
                        if characters.isEmpty {
                            Text("没有角色资料，请改为导入完整攻略。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(characters, id: \.self) { character in
                                Toggle(character, isOn: Binding(
                                    get: { selectedCharacters.contains(character) },
                                    set: { enabled in
                                        if enabled { selectedCharacters.insert(character) }
                                        else { selectedCharacters.remove(character) }
                                    }
                                ))
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("导入离线路线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importRoutes() }
                        .disabled(!importsFullGuide && selectedCharacters.isEmpty)
                }
            }
            .alert("导入完成", isPresented: Binding(get: { importedCount != nil }, set: { _ in })) {
                Button("完成") {
                    dismiss()
                }
            } message: {
                Text("已保存 \(importedCount ?? 0) 条可编辑路线，可在底部“攻略”中离线查看。")
            }
        }
    }

    private func importRoutes() {
        do {
            if importsFullGuide {
                let nodes = RouteTextParser.parse(walkthrough.content).flatMap(\.nodes)
                _ = try store.importNodes(nodes, walkthrough: walkthrough, workTitle: workTitle, character: "完整攻略")
                importedCount = 1
            } else {
                importedCount = try store.importRoute(walkthrough, workTitle: workTitle, characters: Array(selectedCharacters)).count
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
