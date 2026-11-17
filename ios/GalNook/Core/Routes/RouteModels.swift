import Foundation

public enum RouteNodeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ending
    case option
    case note

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ending: "结局"
        case .option: "选项"
        case .note: "注意事项"
        }
    }

    public var systemImage: String {
        switch self {
        case .ending: "flag.checkered"
        case .option: "list.bullet"
        case .note: "exclamationmark.bubble"
        }
    }

    public var preferredStepType: RouteStepType {
        switch self {
        case .ending: .ending
        case .option: .choice
        case .note: .note
        }
    }
}

public enum RouteStepType: String, Codable, CaseIterable, Sendable {
    case ending
    case choice
    case note
}

public struct RouteNode: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var label: String
    public var kind: RouteNodeKind
    public var condition: String
    public var order: Int
    public var notes: String
    public var stepType: RouteStepType
    public var alternatives: [String]

    public init(
        id: String = UUID().uuidString,
        label: String,
        kind: RouteNodeKind = .note,
        condition: String = "",
        order: Int = 0,
        notes: String = "",
        stepType: RouteStepType? = nil,
        alternatives: [String] = []
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.condition = condition
        self.order = order
        self.notes = notes
        self.stepType = stepType ?? kind.preferredStepType
        self.alternatives = alternatives
    }

    public func normalized(order: Int? = nil) -> RouteNode {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.condition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.order = order ?? self.order
        copy.alternatives = alternatives.reduce(into: [String]()) { result, item in
            let value = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !result.contains(value) { result.append(value) }
        }
        return copy
    }
}

public struct LocalRoute: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var workID: String
    public var workTitle: String
    public var character: String
    public var title: String
    public var status: String
    public var sourceURL: URL?
    public var walkthroughID: String
    public var updatedAt: Date
    public var nodes: [RouteNode]

    public init(
        id: String = UUID().uuidString,
        workID: String,
        workTitle: String,
        character: String,
        title: String,
        status: String = "none",
        sourceURL: URL? = nil,
        walkthroughID: String,
        updatedAt: Date = .now,
        nodes: [RouteNode] = []
    ) {
        self.id = id
        self.workID = workID
        self.workTitle = workTitle
        self.character = character
        self.title = title
        self.status = status
        self.sourceURL = sourceURL
        self.walkthroughID = walkthroughID
        self.updatedAt = updatedAt
        self.nodes = nodes
    }

    public var displayStatus: String { RouteStatus.displayName(for: status) }

    public var shareText: String { RouteTextFormatter.shareText(for: self) }

    public func normalized() -> LocalRoute {
        var copy = self
        copy.workTitle = workTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.character = character.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.status = RouteStatus.allCases.contains(status) ? status : "none"
        let cleaned = nodes.map { $0.normalized() }.filter { !$0.label.isEmpty }
        copy.nodes = cleaned.enumerated().map { index, node in
            node.normalized(order: index)
        }
        return copy
    }
}

public enum RouteStatus {
    public static let allCases = ["none", "playing", "played", "dropped"]

    public static func displayName(for value: String) -> String {
        switch value {
        case "playing": "在玩"
        case "played": "已玩"
        case "dropped": "弃坑"
        default: "未标记"
        }
    }
}

public enum RouteTextFormatter {
    public static func shareText(for route: LocalRoute) -> String {
        var lines = ["# \(route.title)", ""]
        if !route.workTitle.isEmpty { lines.append("作品：\(route.workTitle)") }
        if !route.character.isEmpty { lines.append("角色：\(route.character)") }
        lines.append("状态：\(route.displayStatus)")
        if let sourceURL = route.sourceURL { lines.append("来源：\(sourceURL.absoluteString)") }
        lines.append("")

        for node in route.nodes.sorted(by: { $0.order < $1.order }) {
            let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            switch node.kind {
            case .ending:
                lines.append("## \(label)")
            case .option:
                lines.append("• \(label)")
            case .note:
                lines.append(label)
            }
            if !node.condition.isEmpty { lines.append("  条件：\(node.condition)") }
            if !node.notes.isEmpty { lines.append("  备注：\(node.notes)") }
            for alternative in node.alternatives {
                lines.append("  其他选项：\(alternative)")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
