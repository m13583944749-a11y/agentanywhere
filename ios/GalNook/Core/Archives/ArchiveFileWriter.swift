import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

internal struct ArchiveWritePlan {
    let entry: ArchiveEntry
    let relativePath: String

    init(entry: ArchiveEntry) throws {
        self.entry = entry
        self.relativePath = try Self.validate(path: entry.path)

        switch entry.kind {
        case .regular, .directory:
            break
        case .symbolicLink:
            throw ArchiveError.symbolicLinkNotAllowed(entry.path)
        case .hardLink:
            throw ArchiveError.unsupportedEntryType(path: entry.path, type: "hardLink")
        case let .other(type):
            throw ArchiveError.unsupportedEntryType(path: entry.path, type: type)
        }
        if entry.kind == .regular, entry.data == nil {
            throw ArchiveError.missingEntryData(entry.path)
        }
    }

    /// Converts both slash styles to separators, then rejects traversal and absolute paths.
    private static func validate(path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else {
            throw ArchiveError.unsafeEntryPath(path)
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { throw ArchiveError.unsafeEntryPath(path) }

        let scalars = Array(normalized.unicodeScalars)
        if scalars.count >= 2,
           (scalars[0].value >= 65 && scalars[0].value <= 90 ||
            scalars[0].value >= 97 && scalars[0].value <= 122),
           scalars[1] == ":" {
            throw ArchiveError.unsafeEntryPath(path)
        }

        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { throw ArchiveError.unsafeEntryPath(path) }
            if component == "." { continue }
            components.append(String(component))
        }
        guard !components.isEmpty else { throw ArchiveError.unsafeEntryPath(path) }
        return components.joined(separator: "/")
    }
}

internal enum ArchiveFileWriter {
    internal enum NodeKind {
        case missing
        case regular
        case directory
        case symbolicLink
        case other
    }

    static func checkPathIsSafe(plan: ArchiveWritePlan, root: URL) throws {
        let components = plan.relativePath.split(separator: "/").map(String.init)
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            let kind = try nodeKind(at: current)
            if kind == .symbolicLink {
                throw ArchiveError.symbolicLinkNotAllowed(current.path)
            }
            if index < components.count - 1, kind != .missing, kind != .directory {
                throw ArchiveError.destinationNotDirectory(current.path)
            }
            if index == components.count - 1 {
                if plan.entry.kind == .directory, kind != .missing, kind != .directory {
                    throw ArchiveError.destinationNotDirectory(current.path)
                }
                if plan.entry.kind == .regular, kind == .directory {
                    throw ArchiveError.destinationNotDirectory(current.path)
                }
                if kind == .other {
                    throw ArchiveError.unsupportedEntryType(path: current.path, type: "filesystem-node")
                }
            }
        }

        let target = root.appendingPathComponent(plan.relativePath).standardizedFileURL
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ArchiveError.unsafeEntryPath(plan.entry.path)
        }
    }

    static func write(plan: ArchiveWritePlan, root: URL) throws {
        // Repeat the check immediately before each mutation to narrow symlink race windows.
        try checkPathIsSafe(plan: plan, root: root)
        let target = root.appendingPathComponent(plan.relativePath)
        let manager = FileManager.default

        do {
            switch plan.entry.kind {
            case .directory:
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            case .regular:
                guard let data = plan.entry.data else {
                    throw ArchiveError.missingEntryData(plan.entry.path)
                }
                try manager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Directory creation can encounter a link created after the first check.
                try checkPathIsSafe(plan: plan, root: root)
                try data.write(to: target, options: .atomic)
            default:
                throw ArchiveError.unsupportedEntryType(path: plan.entry.path, type: "invalid")
            }
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.fileSystemError(path: target.path, reason: error.localizedDescription)
        }
    }

    /// `lstat` does not follow a symbolic link, unlike a normal existence/resource-value query.
    static func nodeKind(at url: URL) throws -> NodeKind {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 {
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG): return .regular
            case mode_t(S_IFDIR): return .directory
            case mode_t(S_IFLNK): return .symbolicLink
            default: return .other
            }
        }
        let code = errno
        if code == ENOENT { return .missing }
        throw ArchiveError.fileSystemError(
            path: url.path,
            reason: String(cString: strerror(code))
        )
    }
}
