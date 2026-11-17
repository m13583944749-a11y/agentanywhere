import SwiftUI

struct WalkthroughReaderView: View {
    let walkthrough: Walkthrough
    @State private var textSize: Double = 17
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var paragraphs: [String] {
        walkthrough.content.components(separatedBy: .newlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        if paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                            Spacer().frame(height: 2)
                        } else {
                            Text(highlighted(paragraph))
                                .font(.system(size: textSize))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .background(match(paragraph) ? Color.yellow.opacity(0.18) : .clear)
                                .id(index)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(walkthrough.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "在攻略中查找")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        textSize = max(13, textSize - 1)
                    } label: { Image(systemName: "textformat.size.smaller") }
                    Button {
                        textSize = min(28, textSize + 1)
                    } label: { Image(systemName: "textformat.size.larger") }
                    if let url = walkthrough.sourceURL {
                        ShareLink(item: url)
                    } else {
                        ShareLink(item: walkthrough.content)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if !searchText.isEmpty {
                        Button("跳到首个结果") {
                            if let index = paragraphs.firstIndex(where: match) {
                                withAnimation { proxy.scrollTo(index, anchor: .center) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func match(_ text: String) -> Bool {
        !searchText.isEmpty && text.localizedCaseInsensitiveContains(searchText)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !searchText.isEmpty,
              let range = result.range(of: searchText, options: .caseInsensitive) else { return result }
        result[range].backgroundColor = .yellow.opacity(0.35)
        return result
    }
}
