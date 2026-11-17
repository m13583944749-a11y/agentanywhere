import Foundation

public enum LibraryImportMode: Sendable {
    case folders
    case files
}

public struct ImportedGameContainer: Sendable {
    public var url: URL
    public var sourceArchive: String?

    public init(url: URL, sourceArchive: String? = nil) {
        self.url = url
        self.sourceArchive = sourceArchive
    }
}

public enum GameLibraryError: LocalizedError {
    case directoryNotFound(URL)
    case invalidRelativePath(String)
    case emptyGameName
    case launchFileNotFound(String)
    case nothingImported
    case unsupportedShareRoot

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let url):
            "目录不存在或不可读取：\(url.lastPathComponent)"
        case .invalidRelativePath(let path):
            "无效的游戏相对路径：\(path)"
        case .emptyGameName:
            "游戏名称不能为空"
        case .launchFileNotFound(let path):
            "启动文件不存在：\(path)"
        case .nothingImported:
            "没有选择可导入的内容"
        case .unsupportedShareRoot:
            "该游戏不在游戏库目录中，无法分享"
        }
    }
}

/// Resolves persisted relative paths without allowing them to escape the games folder.
public struct GameLibraryStore: Sendable {
    public let gamesDirectory: URL

    public init(gamesDirectory: URL = AppFileLocations.games) {
        self.gamesDirectory = gamesDirectory.standardizedFileURL
    }

    public func gameURL(for game: LocalGame) throws -> URL {
        try url(forRelativePath: game.rootPath, allowRoot: true)
    }

    public func launchURL(for game: LocalGame) throws -> URL? {
        guard let launchPath = game.launchPath,
              !launchPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let root = try gameURL(for: game)
        let url = try Self.resolve(launchPath, in: root, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw GameLibraryError.launchFileNotFound(launchPath)
        }
        // .app is a directory package but remains a valid launch candidate.
        if isDirectory.boolValue && url.pathExtension.lowercased() != "app" {
            throw GameLibraryError.launchFileNotFound(launchPath)
        }
        return url
    }

    public func delete(_ game: LocalGame) throws {
        let url = try url(forRelativePath: game.rootPath, allowRoot: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func relativePath(of url: URL) throws -> String {
        try Self.relativePath(of: url, root: gamesDirectory)
    }

    public static func relativePath(of url: URL, root: URL) throws -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            throw GameLibraryError.invalidRelativePath(path)
        }
        return String(path.dropFirst(prefix.count))
    }

    private func url(forRelativePath path: String, allowRoot: Bool) throws -> URL {
        try Self.resolve(path, in: gamesDirectory, allowRoot: allowRoot)
    }

    private static func resolve(_ path: String, in root: URL, allowRoot: Bool) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            if allowRoot { return root.standardizedFileURL }
            throw GameLibraryError.invalidRelativePath(path)
        }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\\") else {
            throw GameLibraryError.invalidRelativePath(path)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(""), !components.contains(".") else {
            throw GameLibraryError.invalidRelativePath(path)
        }
        let url = root.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard url.path.hasPrefix(prefix) else {
            throw GameLibraryError.invalidRelativePath(path)
        }
        return url
    }
}

/// Copies security-scoped imports into application-owned storage. Archive extraction is
/// deliberately done after copying policy has selected a unique destination folder.
public struct GameLibraryImporter: Sendable {
    public init() {}

    public func importItems(
        _ sourceURLs: [URL],
        mode: LibraryImportMode,
        gamesDirectory: URL = AppFileLocations.games
    ) async throws -> [ImportedGameContainer] {
        guard !sourceURLs.isEmpty else { throw GameLibraryError.nothingImported }
        let root = gamesDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var created: [ImportedGameContainer] = []
        do {
            switch mode {
            case .folders:
                for source in sourceURLs {
                    try Task.checkCancellation()
                    created.append(try await importOne(source, gamesRoot: root))
                }
            case .files:
                if sourceURLs.count == 1, let source = sourceURLs.first {
                    created.append(try await importOne(source, gamesRoot: root))
                } else {
                    created.append(try importFileGroup(sourceURLs, gamesRoot: root))
                }
            }
            return created
        } catch {
            // Do not leave half-imported containers after a failed multi-selection.
            for item in created {
                try? FileManager.default.removeItem(at: item.url)
            }
            throw error
        }
    }

    private func importOne(_ source: URL, gamesRoot: URL) async throws -> ImportedGameContainer {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw GameLibraryError.directoryNotFound(source)
        }

        if isDirectory.boolValue {
            let destination = uniqueDestination(named: source.lastPathComponent, gamesRoot: gamesRoot)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return ImportedGameContainer(url: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        if Self.archiveExtensions.contains(source.pathExtension.lowercased()) {
            let destination = uniqueDestination(
                named: source.deletingPathExtension().lastPathComponent,
                gamesRoot: gamesRoot
            )
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try await ArchiveService().extractArchive(at: source, to: destination)
                return ImportedGameContainer(url: destination, sourceArchive: source.lastPathComponent)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        let folderName = Self.preferredFolderName(for: source)
        let destination = uniqueDestination(named: folderName, gamesRoot: gamesRoot)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: source,
                to: destination.appendingPathComponent(source.lastPathComponent)
            )
            return ImportedGameContainer(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func importFileGroup(_ sources: [URL], gamesRoot: URL) throws -> ImportedGameContainer {
        let parents = Set(sources.map { $0.deletingLastPathComponent().standardizedFileURL })
        let parentName = parents.count == 1 ? parents.first?.lastPathComponent ?? "" : ""
        let usableParentName = parentName.isEmpty || parentName == "/" ? "导入游戏" : parentName
        let destination = uniqueDestination(named: usableParentName, gamesRoot: gamesRoot)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in sources {
                try FileManager.default.copyItem(
                    at: source,
                    to: destination.appendingPathComponent(source.lastPathComponent)
                )
            }
            return ImportedGameContainer(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func uniqueDestination(named proposedName: String, gamesRoot: URL) -> URL {
        let cleaned = GalFormatters.safeFileName(proposedName)
        let base = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "导入游戏" : cleaned
        var candidate = gamesRoot.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = gamesRoot.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func preferredFolderName(for source: URL) -> String {
        let genericNames: Set<String> = [
            "nscript.dat", "0.txt", "arc.nsa", "game.exe", "start.exe",
            "index.html", "game.ini", "rpg_rt.exe"
        ]
        if genericNames.contains(source.lastPathComponent.lowercased()) {
            let parent = source.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty && parent != "/" { return parent }
        }
        let name = source.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "导入游戏" : name
    }

    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "lz4"]
}
