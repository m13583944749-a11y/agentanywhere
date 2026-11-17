import SwiftUI

struct WorkFilterView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss

    private let languages = [("ja", "日语"), ("zh-Hans", "简中"), ("zh-Hant", "繁中"), ("en", "英语"), ("ko", "韩语")]
    private let platforms = [("win", "Windows"), ("android", "Android"), ("ios", "iOS"), ("psv", "PS Vita"), ("ps4", "PS4"), ("switch", "Switch")]

    var body: some View {
        NavigationStack {
            Form {
                Section("排序") {
                    Picker("排序方式", selection: $viewModel.sortOption) {
                        ForEach(WorkSort.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("筛选") {
                    Picker("原始语言", selection: optionalString($viewModel.filter.language)) {
                        Text("全部").tag("")
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("平台", selection: optionalString($viewModel.filter.platform)) {
                        Text("全部").tag("")
                        ForEach(platforms, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("发行年份", selection: Binding(
                        get: { viewModel.filter.year ?? 0 },
                        set: { viewModel.filter.year = $0 == 0 ? nil : $0 }
                    )) {
                        Text("全部").tag(0)
                        ForEach(Array((2010...2026).reversed()), id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("最低评分", selection: Binding(
                        get: { viewModel.filter.minimumScore ?? 0 },
                        set: { viewModel.filter.minimumScore = $0 == 0 ? nil : $0 }
                    )) {
                        Text("不限").tag(0.0)
                        Text("6 分以上").tag(6.0)
                        Text("7 分以上").tag(7.0)
                        Text("8 分以上").tag(8.0)
                    }
                    Picker("标签", selection: Binding(
                        get: { viewModel.filter.tagID ?? "" },
                        set: { value in
                            viewModel.filter.tagID = value.isEmpty ? nil : value
                            viewModel.filter.tagName = viewModel.availableTags.first { $0.id == value }?.name
                        }
                    )) {
                        Text("全部").tag("")
                        ForEach(viewModel.availableTags) { tag in
                            Text(tag.name).tag(tag.id)
                        }
                    }
                }
                Section {
                    Button("重置全部", role: .destructive) {
                        viewModel.resetFilters()
                        dismiss()
                    }
                }
            }
            .navigationTitle("筛选与排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        viewModel.reload()
                        dismiss()
                    }
                }
            }
            .task { await viewModel.loadTags() }
        }
    }

    private func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
