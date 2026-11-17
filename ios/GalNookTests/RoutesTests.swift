import XCTest
@testable import GalNook

final class RoutesTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalNookRoutesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testParserBuildsEditableNodesWithMetadata() {
        let sections = RouteTextParser.parse(sampleText)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "共通线")
        XCTAssertEqual(sections[0].nodes.count, 1)
        let option = sections[0].nodes[0]
        XCTAssertEqual(option.label, "选择帮助")
        XCTAssertEqual(option.kind, .option)
        XCTAssertEqual(option.stepType, .choice)
        XCTAssertEqual(option.condition, "完成序章")
        XCTAssertEqual(option.notes, "影响后续好感")
        XCTAssertEqual(option.alternatives, ["离开"])

        XCTAssertEqual(sections[1].title, "结衣 END")
        XCTAssertEqual(sections[1].nodes.count, 1)
        XCTAssertEqual(sections[1].nodes[0].kind, .ending)
        XCTAssertEqual(sections[1].nodes[0].stepType, .ending)
        XCTAssertEqual(sections[1].nodes[0].notes, "建议最后阅读")
        XCTAssertEqual(RouteTextParser.sections(for: "结衣", in: sections).count, 1)
        XCTAssertEqual(RouteTextParser.sections(for: "未收录角色", in: sections).count, 2)
    }

    @MainActor
    func testImportRouteCreatesSelectedRoutesAndPersistsAtomically() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("state/routes.json")
        let store = RouteStore(fileURL: fileURL)
        let imported = try store.importRoute(
            sampleWalkthrough,
            workTitle: "测试作品",
            characters: ["共通线", "结衣"]
        )

        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(store.routes.count, 2)
        XCTAssertEqual(imported[0].workID, "work-1")
        XCTAssertEqual(imported[0].workTitle, "测试作品")
        XCTAssertEqual(imported[0].walkthroughID, "wt-1")
        XCTAssertEqual(imported[0].sourceURL, URL(string: "https://example.com/wt/1"))
        XCTAssertEqual(imported[1].character, "结衣")
        XCTAssertEqual(imported[1].nodes.map(\.kind), [.ending])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let restored = RouteStore(fileURL: fileURL)
        XCTAssertEqual(restored.routes.count, 2)
        XCTAssertEqual(restored.route(id: imported[0].id)?.nodes[0].condition, "完成序章")
        XCTAssertEqual(restored.route(id: imported[1].id)?.nodes[0].label, "结衣结局")
    }

    @MainActor
    func testReimportKeepsRouteIdentityAndStatusButRefreshesNodes() async throws {
        let store = RouteStore(fileURL: temporaryRoot.appendingPathComponent("routes.json"))
        let first = try XCTUnwrap(try store.importRoute(
            sampleWalkthrough,
            workTitle: "测试作品",
            characters: ["结衣"]
        ).first)
        var changed = first
        changed.status = "played"
        try store.updateRoute(changed)
        let updatedWalkthrough = Walkthrough(
            id: "wt-1",
            workID: "work-1",
            title: "完整攻略",
            content: "## 结衣 END\n• 新结衣结局\n备注：新版内容",
            sourceURL: URL(string: "https://example.com/wt/1")
        )

        let second = try XCTUnwrap(try store.importRoute(
            updatedWalkthrough,
            workTitle: "测试作品",
            characters: ["结衣"]
        ).first)

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.status, "played")
        XCTAssertEqual(second.title, "完整攻略")
        XCTAssertEqual(second.nodes.map(\.label), ["新结衣结局"])
        XCTAssertEqual(second.nodes[0].notes, "新版内容")
        XCTAssertEqual(store.routes.count, 1)
    }

    @MainActor
    func testImportSelectedNodesUsesSameEditableRouteModel() async throws {
        let store = RouteStore(fileURL: temporaryRoot.appendingPathComponent("routes.json"))
        let sections = RouteTextParser.parse(sampleText)
        let selected = sections[0].nodes

        let route = try store.importNodes(
            selected,
            walkthrough: sampleWalkthrough,
            workTitle: "测试作品",
            character: "共通线"
        )

        XCTAssertEqual(route.nodes.map(\.label), ["选择帮助"])
        XCTAssertEqual(route.nodes[0].alternatives, ["离开"])
        XCTAssertEqual(store.routes.count, 1)
        XCTAssertTrue(try store.importRoute(sampleWalkthrough, workTitle: "测试作品", characters: []).isEmpty)
        XCTAssertEqual(store.routes.count, 1)
    }

    @MainActor
    func testCRUDMoveEditDeleteAndReload() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: fileURL)
        let route = try store.createRoute(
            workID: "local-work",
            workTitle: "本地作品",
            character: "自定义角色",
            title: "本地路线",
            nodes: [
                RouteNode(label: "A", kind: .option),
                RouteNode(label: "B", kind: .note)
            ]
        )
        let third = try store.addNode(RouteNode(label: "C", kind: .ending), to: route.id)
        var changedB = route.nodes[1]
        changedB.label = "B2"
        changedB.condition = "完成 A"
        changedB.alternatives = ["B 替代"]
        try store.updateNode(changedB, in: route.id)
        try store.moveNodes(in: route.id, from: IndexSet(integer: 2), to: 0)

        var restored = RouteStore(fileURL: fileURL)
        XCTAssertEqual(restored.route(id: route.id)?.nodes.map(\.label), ["C", "A", "B2"])
        XCTAssertEqual(restored.route(id: route.id)?.nodes.map(\.order), [0, 1, 2])
        XCTAssertEqual(restored.route(id: route.id)?.nodes[2].condition, "完成 A")

        try restored.deleteNode(id: route.nodes[0].id, from: route.id)
        XCTAssertEqual(restored.route(id: route.id)?.nodes.map(\.label), ["C", "B2"])
        XCTAssertEqual(restored.route(id: route.id)?.nodes.map(\.order), [0, 1])
        XCTAssertEqual(third.kind, .ending)

        var metadata = try XCTUnwrap(restored.route(id: route.id))
        metadata.title = "修改后的路线"
        metadata.status = "played"
        try restored.updateRoute(metadata)
        XCTAssertEqual(restored.route(id: route.id)?.title, "修改后的路线")
        XCTAssertEqual(restored.route(id: route.id)?.status, "played")

        try restored.deleteRoute(id: route.id)
        XCTAssertTrue(restored.routes.isEmpty)
        XCTAssertTrue(RouteStore(fileURL: fileURL).routes.isEmpty)
    }

    @MainActor
    func testShareTextContainsAllEditableContent() async throws {
        let store = RouteStore(fileURL: temporaryRoot.appendingPathComponent("routes.json"))
        let route = try store.createRoute(
            workID: "work-1",
            workTitle: "测试作品",
            character: "结衣",
            title: "结衣路线",
            status: "playing",
            sourceURL: URL(string: "https://example.com/wt/1"),
            walkthroughID: "wt-1",
            nodes: [RouteNode(
                label: "结衣结局",
                kind: .ending,
                condition: "全部前置完成",
                notes: "推荐最后",
                alternatives: ["普通结局"]
            )]
        )

        let text = route.shareText
        for expected in [
            "# 结衣路线", "作品：测试作品", "角色：结衣", "状态：在玩",
            "来源：https://example.com/wt/1", "## 结衣结局",
            "条件：全部前置完成", "备注：推荐最后", "其他选项：普通结局"
        ] {
            XCTAssertTrue(text.contains(expected), "分享文本缺少 \(expected)")
        }
    }

    @MainActor
    func testCorruptedJSONIsMovedAsideInsteadOfDeletingUserContent() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("routes.json")
        try Data("not-json".utf8).write(to: fileURL)

        let store = RouteStore(fileURL: fileURL)

        XCTAssertTrue(store.routes.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.hasPrefix("routes.json.corrupted-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private var sampleText: String {
        "## 共通线\n条件：完成序章\n• 选择帮助\n备注：影响后续好感\n其他选项：离开\n\n## 结衣 END\n• 结衣结局\n备注：建议最后阅读"
    }

    private var sampleWalkthrough: Walkthrough {
        Walkthrough(
            id: "wt-1",
            workID: "work-1",
            title: "完整攻略",
            content: sampleText,
            sourceURL: URL(string: "https://example.com/wt/1")
        )
    }
}
