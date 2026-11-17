import Combine
import Foundation

public enum RouteStoreError: Error, LocalizedError {
    case routeNotFound
    case nodeNotFound

    public var errorDescription: String? {
        switch self {
        case .routeNotFound: "路线不存在或已被删除"
        case .nodeNotFound: "节点不存在或已被删除"
        }
    }
}

@MainActor
public final class RouteStore: ObservableObject {
    public static let shared = RouteStore()

    @Published public private(set) var routes: [LocalRoute] = []

    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL ?? AppFileLocations.applicationSupport.appendingPathComponent("routes.json")
        self.fileManager = fileManager
        load()
    }

    public func route(id: String) -> LocalRoute? {
        routes.first { $0.id == id }
    }

    @discardableResult
    public func createRoute(
        workID: String = "",
        workTitle: String = "",
        character: String = "",
        title: String = "新建路线",
        status: String = "none",
        sourceURL: URL? = nil,
        walkthroughID: String = "local",
        nodes: [RouteNode] = []
    ) throws -> LocalRoute {
        let route = LocalRoute(
            workID: workID,
            workTitle: workTitle,
            character: character,
            title: title,
            status: status,
            sourceURL: sourceURL,
            walkthroughID: walkthroughID,
            nodes: nodes
        ).normalized()
        try mutate { $0.append(route) }
        return route
    }

    /// Imports one editable route per selected character. Re-importing the same
    /// walkthrough and character updates nodes in place and preserves route id/status.
    @discardableResult
    public func importRoute(
        _ walkthrough: Walkthrough,
        workTitle: String,
        characters: [String]
    ) throws -> [LocalRoute] {
        let selectedCharacters = uniqueNames(characters)
        guard !selectedCharacters.isEmpty else { return [] }
        let sections = RouteTextParser.parse(walkthrough.content)
        var imported: [LocalRoute] = []
        try mutate { routes in
            for character in selectedCharacters {
                let nodes = RouteTextParser.sections(for: character, in: sections)
                    .flatMap(\.nodes)
                let route = upsert(
                    walkthrough: walkthrough,
                    workTitle: workTitle,
                    character: character,
                    nodes: nodes,
                    into: &routes
                )
                imported.append(route)
            }
        }
        return imported
    }

    /// Imports a caller-selected subset of nodes, useful for a character/node picker.
    @discardableResult
    public func importNodes(
        _ nodes: [RouteNode],
        walkthrough: Walkthrough,
        workTitle: String,
        character: String
    ) throws -> LocalRoute {
        let name = character.trimmingCharacters(in: .whitespacesAndNewlines)
        var imported: LocalRoute?
        try mutate { routes in
            imported = upsert(
                walkthrough: walkthrough,
                workTitle: workTitle,
                character: name,
                nodes: nodes,
                into: &routes
            )
        }
        guard let imported else { throw RouteStoreError.routeNotFound }
        return imported
    }

    public func updateRoute(_ route: LocalRoute) throws {
        var updated = route.normalized()
        updated.updatedAt = .now
        try mutate { routes in
            guard let index = routes.firstIndex(where: { $0.id == updated.id }) else {
                throw RouteStoreError.routeNotFound
            }
            routes[index] = updated
        }
    }

    @discardableResult
    public func addNode(_ node: RouteNode, to routeID: String) throws -> RouteNode {
        var inserted = node
        try mutate { routes in
            guard let index = routes.firstIndex(where: { $0.id == routeID }) else {
                throw RouteStoreError.routeNotFound
            }
            inserted.order = routes[index].nodes.count
            routes[index].nodes.append(inserted.normalized())
            routes[index].updatedAt = .now
        }
        return inserted
    }

    public func updateNode(_ node: RouteNode, in routeID: String) throws {
        try mutate { routes in
            guard let routeIndex = routes.firstIndex(where: { $0.id == routeID }) else {
                throw RouteStoreError.routeNotFound
            }
            guard let nodeIndex = routes[routeIndex].nodes.firstIndex(where: { $0.id == node.id }) else {
                throw RouteStoreError.nodeNotFound
            }
            routes[routeIndex].nodes[nodeIndex] = node.normalized(order: nodeIndex)
            routes[routeIndex].updatedAt = .now
        }
    }

    public func deleteNode(id: String, from routeID: String) throws {
        try mutate { routes in
            guard let index = routes.firstIndex(where: { $0.id == routeID }) else {
                throw RouteStoreError.routeNotFound
            }
            routes[index].nodes.removeAll { $0.id == id }
            routes[index].updatedAt = .now
        }
    }

    public func moveNodes(in routeID: String, from source: IndexSet, to destination: Int) throws {
        try mutate { routes in
            guard let index = routes.firstIndex(where: { $0.id == routeID }) else {
                throw RouteStoreError.routeNotFound
            }
            var reordered = routes[index].nodes
            let moving = source.sorted().map { reordered[$0] }
            for offset in source.sorted(by: >) { reordered.remove(at: offset) }
            let removedBeforeDestination = source.filter { $0 < destination }.count
            let insertionIndex = min(reordered.count, max(0, destination - removedBeforeDestination))
            reordered.insert(contentsOf: moving, at: insertionIndex)
            routes[index].nodes = reordered
            for nodeIndex in routes[index].nodes.indices {
                routes[index].nodes[nodeIndex].order = nodeIndex
            }
            routes[index].updatedAt = .now
        }
    }

    public func deleteRoute(id: String) throws {
        try mutate { routes in
            routes.removeAll { $0.id == id }
        }
    }

    private func upsert(
        walkthrough: Walkthrough,
        workTitle: String,
        character: String,
        nodes: [RouteNode],
        into routes: inout [LocalRoute]
    ) -> LocalRoute {
        let title = walkthrough.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (character.isEmpty ? "游戏攻略" : "\(character) 路线")
            : walkthrough.title
        if let index = routes.firstIndex(where: {
            $0.workID == walkthrough.workID &&
            $0.walkthroughID == walkthrough.id &&
            $0.character.caseInsensitiveCompare(character) == .orderedSame
        }) {
            var route = routes[index]
            route.workTitle = workTitle
            route.title = title
            route.sourceURL = walkthrough.sourceURL
            route.nodes = reconciled(nodes: nodes, with: route.nodes)
            route.updatedAt = .now
            routes[index] = route.normalized()
            return routes[index]
        }
        let route = LocalRoute(
            workID: walkthrough.workID,
            workTitle: workTitle,
            character: character,
            title: title,
            sourceURL: walkthrough.sourceURL,
            walkthroughID: walkthrough.id,
            nodes: reconciled(nodes: nodes, with: [])
        ).normalized()
        routes.append(route)
        return route
    }

    private func reconciled(nodes: [RouteNode], with oldNodes: [RouteNode]) -> [RouteNode] {
        nodes.enumerated().map { index, node in
            var copy = node.normalized(order: index)
            if index < oldNodes.count,
               oldNodes[index].label == copy.label,
               oldNodes[index].kind == copy.kind {
                copy.id = oldNodes[index].id
            } else {
                copy.id = UUID().uuidString
            }
            return copy
        }.filter { !$0.label.isEmpty }
    }

    private func uniqueNames(_ names: [String]) -> [String] {
        var folded = Set<String>()
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard folded.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private func mutate(_ change: (inout [LocalRoute]) throws -> Void) throws {
        let previous = routes
        do {
            try change(&routes)
            routes = routes.map { $0.normalized() }.sorted { $0.updatedAt > $1.updatedAt }
            try persist()
        } catch {
            routes = previous
            throw error
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            routes = try decoder.decode([LocalRoute].self, from: data)
                .map { $0.normalized() }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            let backup = fileURL.appendingPathExtension("corrupted-\(UUID().uuidString)")
            try? fileManager.moveItem(at: fileURL, to: backup)
            routes = []
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(routes)
        try data.write(to: fileURL, options: .atomic)
    }
}
