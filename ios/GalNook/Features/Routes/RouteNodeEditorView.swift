import SwiftUI

struct RouteNodeEditorView: View {
    let isNew: Bool
    let onSave: (RouteNode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var node: RouteNode
    @State private var alternativesText: String
    @State private var showValidation = false

    init(node: RouteNode, isNew: Bool, onSave: @escaping (RouteNode) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _node = State(initialValue: node)
        _alternativesText = State(initialValue: node.alternatives.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("节点内容") {
                    TextField("名称（如：结局 A / 选择帮助 / 注意事项）", text: $node.label, axis: .vertical)
                        .lineLimit(2...5)
                    Picker("类型", selection: $node.kind) {
                        ForEach(RouteNodeKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .onChange(of: node.kind) { newKind in
                        node.stepType = newKind.preferredStepType
                    }
                }

                Section("达成条件") {
                    TextField("完成前置剧情后可留空", text: $node.condition, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("其他选项（每行一个）") {
                    TextEditor(text: $alternativesText)
                        .frame(minHeight: 90)
                }

                Section("备注") {
                    TextEditor(text: $node.notes)
                        .frame(minHeight: 110)
                }

                if showValidation {
                    Section {
                        Text("请先填写节点名称。").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "新增节点" : "编辑节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "添加" : "保存") { save() }
                }
            }
        }
    }

    private func save() {
        var updated = node.normalized()
        updated.alternatives = alternativesText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !updated.label.isEmpty else {
            showValidation = true
            return
        }
        updated.stepType = updated.kind.preferredStepType
        onSave(updated)
        dismiss()
    }
}
