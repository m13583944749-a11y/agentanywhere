import Foundation

/// Recursively scans an imported game library and reports the actual root of each game.
/// Paths in a result are relative to the scanned library root; launch paths are relative
/// to the corresponding game root.
public struct GameLibraryScanner: Sendable {
    public init() {}

    public func scan(directory rootURL: URL) throws -> [EngineDetectionResult] {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GameLibraryError.directoryNotFound(root)
        }
        return try scanDirectory(root, relativePath: "")
    }

    /// Detects one imported container. If an archive added one wrapper directory, the
    /// returned rootRelativePath points at the real game inside that wrapper.
    public func detect(at directoryURL: URL) throws -> EngineDetectionResult {
        let results = try scan(directory: directoryURL)
        if results.count == 1, let result = results.first {
            return result
        }
        if results.isEmpty {
            return EngineDetectionResult(
                engine: .unknown,
                rootRelativePath: "",
                launchRelativePath: nil,
                evidence: ["目录为空"]
            )
        }
        return EngineDetectionResult(
            engine: .unknown,
            rootRelativePath: "",
            launchRelativePath: nil,
            evidence: ["包含多个游戏，请使用 scan(directory:) 分别读取检测结果"]
        )
    }

    /// Returns useful, existing files for the manual launch-file picker.
    public func launchCandidates(at directoryURL: URL) -> [String] {
        guard let snapshot = try? Snapshot(root: directoryURL.standardizedFileURL) else {
            return []
        }
        let executableExtensions: Set<String> = [
            "exe", "bat", "cmd", "sh", "command", "app", "apk", "xp3",
            "html", "htm", "dat", "nsa", "py", "rpa", "rpyc", "rpy",
            "rgssad", "rgss2a", "rgss3a", "ini"
        ]
        return snapshot.files
            .filter { entry in
                let name = entry.lowerName
                if executableExtensions.contains(entry.pathExtension) { return true }
                return ["nscript.dat", "0.txt", "game.ini", "rpg_rt.ldb"].contains(name)
            }
            .sorted { lhs, rhs in
                let leftRank = Self.launchRank(lhs.relativePath)
                let rightRank = Self.launchRank(rhs.relativePath)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            .map(\.relativePath)
    }

    private func scanDirectory(_ directory: URL, relativePath: String) throws -> [EngineDetectionResult] {
        let snapshot = try Snapshot(root: directory)
        let direct = Self.inspect(snapshot, rootRelativePath: relativePath)
        if direct.engine != .unknown {
            return [direct]
        }

        var nestedResults: [EngineDetectionResult] = []
        for child in snapshot.directDirectories {
            let childRelative = Self.join(relativePath, child.lastPathComponent)
            let childResults = try scanDirectory(child, relativePath: childRelative)
            if childResults.contains(where: { $0.engine != .unknown }) {
                nestedResults.append(contentsOf: childResults)
            } else if let childSnapshot = try? Snapshot(root: child), childSnapshot.hasSubstantiveContent {
                // Keep an unrecognized game at its import/container root instead
                // of leaking an arbitrary nested resource directory as the game root.
                nestedResults.append(Self.inspect(childSnapshot, rootRelativePath: childRelative))
            }
        }
        if nestedResults.contains(where: { $0.engine != .unknown }) {
            return nestedResults
        }

        // Keep an unrecognized import visible and editable instead of silently dropping it.
        if snapshot.hasSubstantiveContent {
            return [direct]
        }
        return []
    }

    private static func inspect(_ snapshot: Snapshot, rootRelativePath: String) -> EngineDetectionResult {
        if let result = renpy(snapshot, root: rootRelativePath) { return result }
        if let result = rpgMaker(snapshot, root: rootRelativePath) { return result }
        if let result = unity(snapshot, root: rootRelativePath) { return result }
        if let result = tyrano(snapshot, root: rootRelativePath) { return result }
        if let result = artemis(snapshot, root: rootRelativePath) { return result }
        if let result = onscripter(snapshot, root: rootRelativePath) { return result }
        if let result = kirikiri(snapshot, root: rootRelativePath) { return result }

        return EngineDetectionResult(
            engine: .unknown,
            rootRelativePath: rootRelativePath,
            launchRelativePath: bestExecutable(snapshot, rootOnly: true)?.relativePath,
            evidence: ["未发现已知引擎特征"]
        )
    }

    private static func kirikiri(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        let archives = snapshot.rootFiles.filter { $0.pathExtension == "xp3" }
        guard !archives.isEmpty else { return nil }

        let nativeLaunch = bestExecutable(snapshot, rootOnly: true, extensions: ["exe", "bat", "cmd", "sh", "command"])
        let namedArchive = archives.first {
            ["data.xp3", "game.xp3", "start.xp3", "startup.xp3", "启动游戏.xp3"].contains($0.lowerName)
        }
        // A lone/named XP3 is itself a valid launch candidate on mobile Kirikiri ports.
        // Requiring either that or a native launcher avoids treating random XP3 patches as games.
        guard nativeLaunch != nil || namedArchive != nil || archives.count == 1 else { return nil }

        let launch = nativeLaunch ?? namedArchive ?? archives.sorted { $0.relativePath < $1.relativePath }.first
        var evidence = archives.map { "KrKr 资源包：\($0.relativePath)" }
        if let launch {
            evidence.append("启动候选：\(launch.relativePath)")
        }
        if snapshot.file("system.tjs") != nil || snapshot.file("startup.tjs") != nil {
            evidence.append("发现 Kirikiri 脚本")
        }
        return EngineDetectionResult(
            engine: .kirikiri,
            rootRelativePath: root,
            launchRelativePath: launch?.relativePath,
            evidence: evidence
        )
    }

    private static func onscripter(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        let markers = ["nscript.dat", "0.txt", "arc.nsa"].compactMap { snapshot.file($0) }
        guard !markers.isEmpty else { return nil }
        let launch = snapshot.file("nscript.dat") ?? snapshot.file("0.txt") ?? snapshot.file("arc.nsa")
        return EngineDetectionResult(
            engine: .onscripter,
            rootRelativePath: root,
            launchRelativePath: launch?.relativePath,
            evidence: markers.map { "ONS 脚本/资源：\($0.relativePath)" }
        )
    }

    private static func renpy(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        let gameFiles = snapshot.files.filter { entry in
            guard entry.lowerPath.hasPrefix("game/") else { return false }
            return ["rpa", "rpyc", "rpy"].contains(entry.pathExtension)
        }
        let hasRuntime = snapshot.directories.contains("renpy") || snapshot.file("renpy.exe") != nil
        guard !gameFiles.isEmpty, hasRuntime else { return nil }

        let native = bestExecutable(snapshot, rootOnly: true, extensions: ["exe", "sh", "command", "py", "app"])
        let script = snapshot.file("game/script.rpy")
        let launch = native ?? script ?? gameFiles.sorted {
            let ranks = ["rpy": 0, "rpa": 1, "rpyc": 2]
            let left = ranks[$0.pathExtension] ?? 3
            let right = ranks[$1.pathExtension] ?? 3
            if left != right { return left < right }
            return $0.relativePath < $1.relativePath
        }.first
        var evidence = ["Ren'Py 运行库：renpy"]
        evidence.append(contentsOf: gameFiles.prefix(4).map { "Ren'Py 游戏文件：\($0.relativePath)" })
        if gameFiles.count > 4 { evidence.append("另有 \(gameFiles.count - 4) 个 Ren'Py 游戏文件") }
        if let launch { evidence.append("启动候选：\(launch.relativePath)") }
        return EngineDetectionResult(
            engine: .renpy,
            rootRelativePath: root,
            launchRelativePath: launch?.relativePath,
            evidence: evidence
        )
    }

    private static func artemis(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        let archives = snapshot.rootFiles.filter { $0.pathExtension == "pfs" }
        let runtime = snapshot.rootFiles.first {
            $0.lowerName.hasPrefix("artemis") && ["exe", "dll"].contains($0.pathExtension)
        }
        let executable = bestExecutable(snapshot, rootOnly: true, extensions: ["exe"])
        guard executable != nil, runtime != nil || !archives.isEmpty else { return nil }

        var evidence = archives.map { "Artemis 资源包：\($0.relativePath)" }
        if let runtime { evidence.append("Artemis 运行库：\(runtime.relativePath)") }
        let launch = executable ?? archives.first
        if let launch { evidence.append("启动候选：\(launch.relativePath)") }
        return EngineDetectionResult(
            engine: .artemis,
            rootRelativePath: root,
            launchRelativePath: launch?.relativePath,
            evidence: evidence
        )
    }

    private static func tyrano(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        let index = snapshot.file("index.html")
        let scenarios = snapshot.files.filter {
            $0.lowerPath.hasPrefix("data/scenario/") && $0.pathExtension == "ks"
        }
        let runtime = snapshot.files.first {
            let name = $0.lowerName
            return name == "tyrano.js" || name == "tyrano_script.js" || name == "tyrano.core.js"
        } ?? (snapshot.directories.contains("tyrano") ? snapshot.file("tyrano") : nil)
        guard index != nil, !scenarios.isEmpty || runtime != nil else { return nil }

        var evidence = ["Tyrano 页面：\(index?.relativePath ?? "index.html")"]
        if let runtime { evidence.append("Tyrano 运行库：\(runtime.relativePath)") }
        if let scenario = scenarios.first { evidence.append("Tyrano 场景：\(scenario.relativePath)") }
        return EngineDetectionResult(
            engine: .tyrano,
            rootRelativePath: root,
            launchRelativePath: index?.relativePath,
            evidence: evidence
        )
    }

    private static func unity(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        let dataDirectories = snapshot.directories.filter { path in
            !path.contains("/") && path.hasSuffix("_data")
        }
        let unityPlayer = snapshot.file("UnityPlayer.dll")
        let gameAssembly = snapshot.file("GameAssembly.dll")
        let hasDataContent = snapshot.files.contains { entry in
            guard let directory = dataDirectories.first(where: { entry.lowerPath.hasPrefix($0 + "/") }) else {
                return false
            }
            let remainder = String(entry.lowerPath.dropFirst(directory.count + 1))
            return remainder == "globalgamemanagers" || remainder == "level0" || remainder == "data.unity3d"
        }
        let executable = bestExecutable(snapshot, rootOnly: true, extensions: ["exe", "app"])
        guard executable != nil, unityPlayer != nil || (gameAssembly != nil && !dataDirectories.isEmpty) || hasDataContent else {
            return nil
        }

        var evidence: [String] = []
        if let unityPlayer { evidence.append("Unity 运行库：\(unityPlayer.relativePath)") }
        if let gameAssembly { evidence.append("Unity IL2CPP：\(gameAssembly.relativePath)") }
        evidence.append(contentsOf: dataDirectories.sorted().map { "Unity 数据目录：\($0)" })
        if let executable { evidence.append("启动候选：\(executable.relativePath)") }
        return EngineDetectionResult(
            engine: .unity,
            rootRelativePath: root,
            launchRelativePath: executable?.relativePath,
            evidence: evidence
        )
    }

    private static func rpgMaker(_ snapshot: Snapshot, root: String) -> EngineDetectionResult? {
        if let executable = snapshot.file("RPG_RT.exe"), let database = snapshot.file("RPG_RT.ldb") {
            return EngineDetectionResult(
                engine: .rpgMaker,
                rootRelativePath: root,
                launchRelativePath: executable.relativePath,
                evidence: ["RPG Maker 2000/2003：\(executable.relativePath)", "数据库：\(database.relativePath)"]
            )
        }

        let encryptedArchive = snapshot.rootFiles.first {
            ["rgssad", "rgss2a", "rgss3a"].contains($0.pathExtension)
        }
        let dataSystem = snapshot.files.first {
            guard $0.lowerPath.hasPrefix("data/system.") else { return false }
            return ["rxdata", "rvdata", "rvdata2"].contains($0.pathExtension)
        }
        if let gameINI = snapshot.file("Game.ini"), encryptedArchive != nil || dataSystem != nil {
            let launch = snapshot.file("Game.exe") ?? bestExecutable(snapshot, rootOnly: true, extensions: ["exe"]) ?? gameINI
            var evidence = ["RPG Maker 配置：\(gameINI.relativePath)"]
            if let encryptedArchive { evidence.append("RPG Maker 资源：\(encryptedArchive.relativePath)") }
            if let dataSystem { evidence.append("RPG Maker 数据库：\(dataSystem.relativePath)") }
            return EngineDetectionResult(
                engine: .rpgMaker,
                rootRelativePath: root,
                launchRelativePath: launch.relativePath,
                evidence: evidence
            )
        }

        let webPrefixes = ["www/", ""]
        for prefix in webPrefixes {
            guard let index = snapshot.file(prefix + "index.html") else { continue }
            let system = snapshot.file(prefix + "data/System.json")
            let runtime = ["js/rpg_core.js", "js/rmmz_core.js", "js/rpg_managers.js", "js/rmmz_managers.js"]
                .compactMap { snapshot.file(prefix + $0) }
                .first
            guard system != nil || runtime != nil else { continue }
            var evidence = ["RPG Maker MV/MZ 页面：\(index.relativePath)"]
            if let system { evidence.append("RPG Maker 数据库：\(system.relativePath)") }
            if let runtime { evidence.append("RPG Maker 运行库：\(runtime.relativePath)") }
            return EngineDetectionResult(
                engine: .rpgMaker,
                rootRelativePath: root,
                launchRelativePath: index.relativePath,
                evidence: evidence
            )
        }
        return nil
    }

    private static func bestExecutable(
        _ snapshot: Snapshot,
        rootOnly: Bool,
        extensions: Set<String>? = nil
    ) -> Entry? {
        (rootOnly ? snapshot.rootFiles : snapshot.files)
            .filter { entry in
                guard let extensions else {
                    return ["exe", "bat", "cmd", "sh", "command", "app", "html"].contains(entry.pathExtension)
                }
                return extensions.contains(entry.pathExtension)
            }
            .filter { entry in
                let name = entry.lowerName
                return !name.hasPrefix("unins") && !name.hasPrefix("uninstall") && !name.hasPrefix("setup")
            }
            .sorted { lhs, rhs in
                let left = launchRank(lhs.relativePath)
                let right = launchRank(rhs.relativePath)
                if left != right { return left < right }
                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            .first
    }

    private static func launchRank(_ path: String) -> Int {
        let name = path.split(separator: "/").last?.lowercased() ?? path.lowercased()
        switch name {
        case "start.exe", "game.exe", "krkr.exe", "kirikiri.exe", "rpg_rt.exe": return 0
        case "start.bat", "run.bat", "start.sh", "run.sh", "index.html": return 1
        case "nscript.dat", "0.txt", "data.xp3", "game.xp3", "启动游戏.xp3": return 2
        default:
            switch URL(fileURLWithPath: name).pathExtension.lowercased() {
            case "exe", "app": return 3
            case "sh", "command", "bat", "cmd": return 4
            case "xp3": return 5
            case "html", "htm": return 6
            default: return 10
            }
        }
    }

    private static func join(_ parent: String, _ child: String) -> String {
        parent.isEmpty ? child : parent + "/" + child
    }
}

private struct GameEntry {
    let url: URL
    let relativePath: String
    let lowerPath: String
    let lowerName: String
    let pathExtension: String

    init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
        self.lowerPath = relativePath.lowercased()
        self.lowerName = url.lastPathComponent.lowercased()
        self.pathExtension = url.pathExtension.lowercased()
    }
}

private extension GameLibraryScanner {
    typealias Entry = GameEntry

    struct Snapshot {
        let root: URL
        let files: [GameEntry]
        let fileByPath: [String: GameEntry]
        let directories: Set<String>
        let directDirectories: [URL]
        let hasSubstantiveContent: Bool

        init(root: URL) throws {
            self.root = root
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw GameLibraryError.directoryNotFound(root)
            }

            var discoveredFiles: [GameEntry] = []
            var discoveredDirectories = Set<String>()
            var directDirectories: [URL] = []
            var substantiveContent = false

            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                throw GameLibraryError.directoryNotFound(root)
            }

            for case let url as URL in enumerator {
                let relativePath = Self.relativePath(of: url, root: root)
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
                if components.contains(where: { $0.lowercased() == "__macosx" }) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if url.lastPathComponent == ".DS_Store" { continue }

                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }

                // .app is a launchable package, not another game container to recurse into.
                if values.isDirectory == true && url.pathExtension.lowercased() != "app" {
                    discoveredDirectories.insert(relativePath.lowercased())
                    if !relativePath.contains("/") { directDirectories.append(url) }
                    substantiveContent = true
                    continue
                }

                discoveredFiles.append(GameEntry(url: url, relativePath: relativePath))
                substantiveContent = true
            }

            self.files = discoveredFiles.sorted {
                $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
            }
            var mapping: [String: GameEntry] = [:]
            for file in discoveredFiles where mapping[file.lowerPath] == nil {
                mapping[file.lowerPath] = file
            }
            self.fileByPath = mapping
            self.directories = discoveredDirectories
            self.directDirectories = directDirectories.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            self.hasSubstantiveContent = substantiveContent
        }

        var rootFiles: [GameEntry] { files.filter { !$0.relativePath.contains("/") } }

        func file(_ relativePath: String) -> GameEntry? {
            fileByPath[relativePath.lowercased()]
        }

        private static func relativePath(of url: URL, root: URL) -> String {
            let rootPath = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path != rootPath else { return "" }
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard path.hasPrefix(prefix) else { return url.lastPathComponent }
            return String(path.dropFirst(prefix.count))
        }
    }
}
