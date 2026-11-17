import SwiftUI

struct RouteDetailView: View {
    let routeID: String
    let store: RouteStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalRoute
    @State private var isEditing = false
    @State private var editingNode: RouteNode?
    @State private var addingNode = false
    @State private var confirmDelete = false
    @State private var showsOverlay = false
    @State private var errorMessage: String?

    init(routeID: String, store: RouteStore) {
        self.routeID = routeID
        self.store = store
        _draft = State(initialValue: store.route(id: routeID) ?? LocalRoute(
            id: routeID,
            workID: "",
            workTitle: "",
            character: "",
            title: "路线",
            walkthroughID: "local"
        ))
    }

    var body: some View {
        List {
            Section("路线信息") {
                if isEditing {
                    TextField("路线名称", text: $draft.title)
                    TextField("作品名称", text: $draft.workTitle)
                    TextField("角色", text: $draft.character)
                    Picker("游玩状态", selection: $draft.status) {
                        ForEach(RouteStatus.allCases, id: \.self) { status in
                            Text(RouteStatus.displayName(for: status)).tag(status)
                        }
                    }
                } else {
                    if !draft.workTitle.isEmpty {
                        LabeledContent("作品", value: draft.workTitle)
                    }
                    if !draft.character.isEmpty {
                        LabeledContent("角色", value: draft.character)
                    }
                    LabeledContent("状态", value: draft.displayStatus)
                    if let sourceURL = draft.sourceURL {
                        Link(destination: sourceURL) {
                            Label("查看原始攻略", systemImage: "safari")
                        }
                    }
                }
            }

            Section {
                if draft.nodes.isEmpty {
                    Text(isEditing ? "还没有节点，点下方“新增节点”开始编辑。" : "这条路线还没有节点。")
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.nodes) { node in
                    if isEditing {
                        Button {
                            editingNode = node
                        } label: {
                            RouteNodeRow(node: node, isEditing: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        RouteNodeRow(node: node, isEditing: false)
                    }
                }
                .onDelete(perform: isEditing ? deleteNodes : nil)
                .onMove(perform: isEditing ? moveNodes : nil)
            } header: {
                HStack {
                    Text("路线节点 · \(draft.nodes.count)")
                    if isEditing {
                        Spacer()
                        Button("新增节点") { addingNode = true }
                    }
                }
            }

            if isEditing {
                Section {
                    Button("删除整条路线", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle(draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: draft.shareText)
                if !isEditing {
                    Button {
                        withAnimation { showsOverlay.toggle() }
                    } label: {
                        Image(systemName: "rectangle.inset.filled.and.person.filled")
                    }
                    .accessibilityLabel("应用内浮层")
                }
                if isEditing {
                    Button("保存") { saveChanges() }
                }
                Button(isEditing ? "完成" : "编辑") {
                    if isEditing { saveChanges() }
                    isEditing.toggle()
                }
            }
        }
        .onDisappear {
            if isEditing && !confirmDelete { saveChanges() }
        }
        .sheet(item: $editingNode) { node in
            RouteNodeEditorView(node: node, isNew: false) { updated in
                guard let index = draft.nodes.firstIndex(where: { $0.id == updated.id }) else { return }
                draft.nodes[index] = updated.normalized(order: index)
                saveChanges()
            }
        }
        .sheet(isPresented: $addingNode) {
            RouteNodeEditorView(
                node: RouteNode(label: "", kind: .option, order: draft.nodes.count),
                isNew: true
            ) { node in
                draft.nodes.append(node.normalized(order: draft.nodes.count))
                saveChanges()
            }
        }
        .confirmationDialog("删除这条路线？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do {
                    try store.deleteRoute(id: routeID)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除路线及全部节点，此操作不可撤销。")
        }
        .errorAlert(message: $errorMessage)
        .overlay {
            if showsOverlay {
                WalkthroughOverlayView(route: draft, isPresented: $showsOverlay)
            }
        }
    }

    private func deleteNodes(at offsets: IndexSet) {
        draft.nodes.remove(atOffsets: offsets)
        renumberNodes()
        saveChanges()
    }

    private func moveNodes(from source: IndexSet, to destination: Int) {
        draft.nodes.move(fromOffsets: source, toOffset: destination)
        renumberNodes()
        saveChanges()
    }

    private func renumberNodes() {
        for index in draft.nodes.indices { draft.nodes[index].order = index }
    }

    private func saveChanges() {
        guard store.route(id: routeID) != nil else { return }
        do {
            try store.updateRoute(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RouteNodeRow: View {
    let node: RouteNode
    let isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(node.kind.displayName, systemImage: node.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(node.kind == .ending ? Color.accentColor : .secondary)
                Spacer()
                if isEditing {
                    Text("\(node.order + 1)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(node.label)
                .font(node.kind == .ending ? .headline : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !node.condition.isEmpty {
                Label("条件：\(node.condition)", systemImage: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !node.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(node.alternatives, id: \.self) { alternative in
                        Text("其他选项：\(alternative)").font(.footnote)
                    }
                }
                .foregroundStyle(.secondary)
            }
            if !node.notes.isEmpty {
                Text("备注：\(node.notes)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .textSelection(.enabled)
    }
}
