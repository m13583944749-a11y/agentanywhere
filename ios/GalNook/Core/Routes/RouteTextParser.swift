import Foundation

public struct RouteSection: Hashable, Sendable {
    public var title: String
    public var nodes: [RouteNode]

    public init(title: String, nodes: [RouteNode]) {
        self.title = title
        self.nodes = nodes
    }

    public var isEnding: Bool {
        let value = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return value.contains("结局") || value.contains("end")
    }
}

public enum RouteTextParser {
    /// Parses the NextMoe plain-text shape: `##` sections, `•` options,
    /// `条件：`, `备注：` and `其他选项：`. Metadata following an option is
    /// attached to that option; metadata before it is attached to the next one.
    public static func parse(_ text: String) -> [RouteSection] {
        var sections: [RouteSection] = []
        var sectionTitle = "攻略"
        var hasExplicitSection = false
        var nodes: [RouteNode] = []
        var pendingCondition = ""
        var pendingNotes = ""
        var pendingAlternatives: [String] = []

        func appendCondition(_ value: String, to node: inout RouteNode) {
            node.condition = joined(node.condition, value)
        }

        func appendNotes(_ value: String, to node: inout RouteNode) {
            node.notes = joined(node.notes, value)
        }

        func appendAlternative(_ value: String, to node: inout RouteNode) {
            if !value.isEmpty, !node.alternatives.contains(value) {
                node.alternatives.append(value)
            }
        }

        func takePending() -> (condition: String, notes: String, alternatives: [String]) {
            let result = (pendingCondition, pendingNotes, pendingAlternatives)
            pendingCondition = ""
            pendingNotes = ""
            pendingAlternatives = []
            return result
        }

        func finishSection() {
            if !pendingCondition.isEmpty || !pendingNotes.isEmpty || !pendingAlternatives.isEmpty {
                if nodes.isEmpty {
                    let node = RouteNode(
                        label: sectionTitle.isEmpty ? "注意事项" : sectionTitle,
                        kind: .note,
                        condition: pendingCondition,
                        notes: pendingNotes,
                        stepType: .note,
                        alternatives: pendingAlternatives
                    )
                    nodes.append(node)
                } else {
                    var last = nodes.removeLast()
                    appendCondition(pendingCondition, to: &last)
                    appendNotes(pendingNotes, to: &last)
                    pendingAlternatives.forEach { appendAlternative($0, to: &last) }
                    nodes.append(last)
                }
                pendingCondition = ""
                pendingNotes = ""
                pendingAlternatives = []
            }
            if hasExplicitSection || !nodes.isEmpty {
                let normalized = nodes.enumerated().map { index, node in
                    node.normalized(order: index)
                }.filter { !$0.label.isEmpty }
                if hasExplicitSection || !normalized.isEmpty {
                    sections.append(RouteSection(title: sectionTitle, nodes: normalized))
                }
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("##") {
                finishSection()
                sectionTitle = String(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                if sectionTitle.isEmpty { sectionTitle = "攻略" }
                hasExplicitSection = true
                nodes = []
                pendingCondition = ""
                pendingNotes = ""
                pendingAlternatives = []
                continue
            }

            if line.hasPrefix("•") || line.hasPrefix("●") {
                let label = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { continue }
                let pending = takePending()
                let kind: RouteNodeKind = RouteSection(title: sectionTitle, nodes: []).isEnding ? .ending : .option
                nodes.append(RouteNode(
                    label: label,
                    kind: kind,
                    condition: pending.condition,
                    order: nodes.count,
                    notes: pending.notes,
                    stepType: kind.preferredStepType,
                    alternatives: pending.alternatives
                ))
                continue
            }

            if let value = metadataValue(line, names: ["条件", "达成条件"]) {
                pendingCondition = joined(pendingCondition, value)
                continue
            }
            if let value = metadataValue(line, names: ["备注", "注意", "注意事项"]) {
                if nodes.isEmpty {
                    pendingNotes = joined(pendingNotes, value)
                } else {
                    var last = nodes.removeLast()
                    appendNotes(value, to: &last)
                    nodes.append(last)
                }
                continue
            }
            if let value = metadataValue(line, names: ["其他选项", "其它选项"]) {
                if nodes.isEmpty {
                    if !pendingAlternatives.contains(value) { pendingAlternatives.append(value) }
                } else {
                    var last = nodes.removeLast()
                    appendAlternative(value, to: &last)
                    nodes.append(last)
                }
                continue
            }

            let pending = takePending()
            nodes.append(RouteNode(
                label: line,
                kind: .note,
                condition: pending.condition,
                order: nodes.count,
                notes: pending.notes,
                stepType: .note,
                alternatives: pending.alternatives
            ))
        }
        finishSection()
        return sections
    }

    public static func sections(for character: String, in sections: [RouteSection]) -> [RouteSection] {
        let needle = folded(character)
        guard !needle.isEmpty else { return sections }
        let exact = sections.filter { folded($0.title) == needle }
        if !exact.isEmpty { return exact }
        let related = sections.filter {
            let title = folded($0.title)
            return title.contains(needle) || needle.contains(title)
        }
        return related.isEmpty ? sections : related
    }

    private static func metadataValue(_ line: String, names: [String]) -> String? {
        for name in names {
            for separator in ["：", ":"] {
                let prefix = name + separator
                if line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if right.isEmpty { return left }
        if left.isEmpty { return right }
        if left == right || left.contains(right) { return left }
        return left + "\n" + right
    }

    private static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
