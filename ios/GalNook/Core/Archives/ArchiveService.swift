import Foundation
import SWCompression

/// Formats recognized by `ArchiveService`. Magic bytes take precedence over the file extension.
public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip
    case rar
    case sevenZip = "7z"
    case lz4
}

public enum ArchiveError: Error, Equatable {
    case emptyArchive
    case unknownFormat(fileName: String?)
    /// RAR has no decoder in SWCompression 4.8.6; a separate `ArchiveBackend` can supply one.
    case unsupportedFormat(format: ArchiveFormat, reason: String)
    case invalidArchive(format: ArchiveFormat, reason: String)
    case passwordRequired(format: ArchiveFormat)
    case passwordUnsupported(format: ArchiveFormat)
    case unsafeEntryPath(String)
    case symbolicLinkNotAllowed(String)
    case unsupportedEntryType(path: String, type: String)
    case missingEntryData(String)
    case destinationNotDirectory(String)
    case fileSystemError(path: String, reason: String)
    case cancelled
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyArchive:
            return "压缩包为空。"
        case let .unknownFormat(fileName):
            return "无法识别压缩包格式\(fileName.map { "：\($0)" } ?? "")。"
        case let .unsupportedFormat(format, reason):
            return "不支持 \(format.rawValue) 解压：\(reason)"
        case let .invalidArchive(format, reason):
            return "\(format.rawValue) 压缩包无效或已损坏：\(reason)"
        case let .passwordRequired(format):
            return "\(format.rawValue) 已加密；SWCompression 4.8.6 不支持解密。"
        case let .passwordUnsupported(format):
            return "SWCompression 4.8.6 不支持使用密码解压 \(format.rawValue)。"
        case let .unsafeEntryPath(path):
            return "压缩包包含不安全的绝对路径或路径穿越：\(path)"
        case let .symbolicLinkNotAllowed(path):
            return "不允许通过符号链接解压：\(path)"
        case let .unsupportedEntryType(path, type):
            return "不允许解压类型为 \(type) 的条目：\(path)"
        case let .missingEntryData(path):
            return "压缩包条目缺少文件数据：\(path)"
        case let .destinationNotDirectory(path):
            return "目标位置不是目录：\(path)"
        case let .fileSystemError(path, reason):
            return "写入 \(path) 失败：\(reason)"
        case .cancelled:
            return "解压已取消。"
        }
    }
}

public struct ArchiveProgress: Equatable, Sendable {
    /// Progress is measured in entries because SWCompression's Data API has no byte-stream callback.
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64
    public let currentEntry: String?

    public var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return 0 }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }

    public init(completedUnitCount: Int64, totalUnitCount: Int64, currentEntry: String? = nil) {
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.currentEntry = currentEntry
    }
}

public struct ArchiveExtractionResult: Equatable, @unchecked Sendable {
    public let format: ArchiveFormat
    public let destinationURL: URL
    public let fileURLs: [URL]
    public let entryCount: Int

    public init(format: ArchiveFormat, destinationURL: URL, fileURLs: [URL], entryCount: Int) {
        self.format = format
        self.destinationURL = destinationURL
        self.fileURLs = fileURLs
        self.entryCount = entryCount
    }
}

/// Decoded representation used by container backends. The service performs all path checks and file writes.
public struct ArchiveEntry: Sendable {
    public enum Kind: Sendable, Equatable {
        case regular
        case directory
        case symbolicLink
        case hardLink
        case other(String)
    }

    public let path: String
    public let kind: Kind
    public let data: Data?

    public init(path: String, kind: Kind, data: Data?) {
        self.path = path
        self.kind = kind
        self.data = data
    }
}

/// An independently replaceable container decoder, intended for a RAR implementation or another ZIP/7z decoder.
/// Implementations may support passwords; SWCompression's ZIP and 7z backends do not.
public protocol ArchiveBackend: Sendable {
    var format: ArchiveFormat { get }
    func readEntries(from data: Data, password: String?) throws -> [ArchiveEntry]
}

public final class ArchiveService: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (ArchiveProgress) -> Void

    private let lock = NSLock()
    private var operations: [UUID: ArchiveCancellationToken] = [:]
    private var backends: [ArchiveFormat: any ArchiveBackend]

    /// - Parameter additionalBackends: Backends override a default backend with the same `format`.
    ///   Register a RAR backend here to enable RAR without changing extraction and safety logic.
    public init(additionalBackends: [any ArchiveBackend] = []) {
        var registered: [ArchiveFormat: any ArchiveBackend] = [
            .zip: ZipArchiveBackend(),
            .sevenZip: SevenZipArchiveBackend()
        ]
        for backend in additionalBackends {
            registered[backend.format] = backend
        }
        self.backends = registered
    }

    /// Cancels every extraction currently running on this service. Cooperative between library calls and entries.
    public func cancel() {
        let tokens: [ArchiveCancellationToken] = locked {
            Array(operations.values)
        }
        tokens.forEach { $0.cancel() }
    }

    /// Detects ZIP (including empty ZIP), RAR4/RAR5, 7z, normal/legacy/skippable LZ4 frames.
    /// If there is no known signature, `.zip`, `.rar`, `.7z`, and `.lz4` extensions are used.
    public static func detectFormat(data: Data, fileName: String? = nil) throws -> ArchiveFormat {
        guard !data.isEmpty else { throw ArchiveError.emptyArchive }
        let bytes = [UInt8](data.prefix(8))

        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
            bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
            bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) ||
            bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) {
            return .rar
        }
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZip
        }
        if bytes.starts(with: [0x04, 0x22, 0x4D, 0x18]) ||
            bytes.starts(with: [0x02, 0x21, 0x4C, 0x18]) ||
            (bytes.count >= 4 && bytes[1] == 0x2A && bytes[2] == 0x4D && bytes[3] == 0x18 &&
                (0x50...0x5F).contains(bytes[0])) {
            return .lz4
        }

        switch (fileName.map { ($0 as NSString).pathExtension.lowercased() }) {
        case "zip": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        case "lz4": return .lz4
        default: throw ArchiveError.unknownFormat(fileName: fileName)
        }
    }

    @discardableResult
    public func extractArchive(
        at sourceURL: URL,
        to destinationURL: URL,
        password: String? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> ArchiveExtractionResult {
        try await run { token in
            let data: Data
            do {
                data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            } catch {
                throw ArchiveError.fileSystemError(path: sourceURL.path, reason: error.localizedDescription)
            }
            return try self.extract(
                data,
                suggestedName: sourceURL.lastPathComponent,
                to: destinationURL,
                password: password,
                token: token,
                progress: progress
            )
        }
    }

    @discardableResult
    public func extractArchive(
        data: Data,
        suggestedName: String? = nil,
        to destinationURL: URL,
        password: String? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> ArchiveExtractionResult {
        try await run { token in
            try self.extract(
                data,
                suggestedName: suggestedName,
                to: destinationURL,
                password: password,
                token: token,
                progress: progress
            )
        }
    }

    private func run(
        operation: @escaping @Sendable (ArchiveCancellationToken) throws -> ArchiveExtractionResult
    ) async throws -> ArchiveExtractionResult {
        let id = UUID()
        let token = ArchiveCancellationToken()
        locked { operations[id] = token }

        let task = Task.detached(priority: nil) { () throws -> ArchiveExtractionResult in
            defer { self.locked { self.operations.removeValue(forKey: id) } }
            return try operation(token)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            token.cancel()
            task.cancel()
        }
    }

    private func extract(
        _ data: Data,
        suggestedName: String?,
        to destinationURL: URL,
        password: String?,
        token: ArchiveCancellationToken,
        progress: ProgressHandler?
    ) throws -> ArchiveExtractionResult {
        try token.checkCancelled()
        let format = try Self.detectFormat(data: data, fileName: suggestedName)
        progress?(ArchiveProgress(completedUnitCount: 0, totalUnitCount: 0))
        try token.checkCancelled()

        if format == .rar, backends[.rar] == nil {
            throw ArchiveError.unsupportedFormat(
                format: .rar,
                reason: "SWCompression 4.8.6 没有 RAR 解码器；请通过 ArchiveBackend 注册独立后端。"
            )
        }
        if format == .lz4 {
            if password != nil { throw ArchiveError.passwordUnsupported(format: .lz4) }
            return try extractLZ4(
                data,
                suggestedName: suggestedName,
                to: destinationURL,
                token: token,
                progress: progress
            )
        }
        guard let backend = backends[format] else {
            throw ArchiveError.unsupportedFormat(format: format, reason: "没有注册解压后端。")
        }

        let entries: [ArchiveEntry]
        do {
            entries = try backend.readEntries(from: data, password: password)
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.invalidArchive(format: format, reason: String(describing: error))
        }
        try token.checkCancelled()

        // Validate every entry before creating any output file.
        let plans = try entries.map { try ArchiveWritePlan(entry: $0) }
        let root = try prepareDestination(destinationURL)
        for plan in plans {
            try ArchiveFileWriter.checkPathIsSafe(plan: plan, root: root)
        }
        try writeEntries(
            plans,
            root: root,
            token: token,
            progress: progress
        )
        let files = plans.filter { $0.entry.kind == .regular }.map { root.appendingPathComponent($0.relativePath) }
        return ArchiveExtractionResult(
            format: format,
            destinationURL: root,
            fileURLs: files,
            entryCount: plans.count
        )
    }

    private func writeEntries(
        _ plans: [ArchiveWritePlan],
        root: URL,
        token: ArchiveCancellationToken,
        progress: ProgressHandler?
    ) throws {
        let total = Int64(plans.count)
        progress?(ArchiveProgress(completedUnitCount: 0, totalUnitCount: total))
        for (index, plan) in plans.enumerated() {
            try token.checkCancelled()
            progress?(ArchiveProgress(
                completedUnitCount: Int64(index),
                totalUnitCount: total,
                currentEntry: plan.entry.path
            ))
            try ArchiveFileWriter.write(plan: plan, root: root)
            try token.checkCancelled()
            progress?(ArchiveProgress(
                completedUnitCount: Int64(index + 1),
                totalUnitCount: total,
                currentEntry: plan.entry.path
            ))
        }
    }

    private func extractLZ4(
        _ data: Data,
        suggestedName: String?,
        to destinationURL: URL,
        token: ArchiveCancellationToken,
        progress: ProgressHandler?
    ) throws -> ArchiveExtractionResult {
        let frames: [Data]
        do {
            frames = try LZ4.multiDecompress(data: data)
        } catch let error as DataError {
            throw ArchiveError.invalidArchive(format: .lz4, reason: archiveDataErrorReason(error))
        } catch {
            throw ArchiveError.invalidArchive(format: .lz4, reason: String(describing: error))
        }
        try token.checkCancelled()
        var output = Data()
        for frame in frames { output.append(frame) }

        let name = lz4OutputName(suggestedName)
        let entry = ArchiveEntry(path: name, kind: .regular, data: output)
        let plan = try ArchiveWritePlan(entry: entry)
        let root = try prepareDestination(destinationURL)
        try ArchiveFileWriter.checkPathIsSafe(plan: plan, root: root)
        progress?(ArchiveProgress(completedUnitCount: 0, totalUnitCount: 1, currentEntry: name))
        try ArchiveFileWriter.write(plan: plan, root: root)
        try token.checkCancelled()
        progress?(ArchiveProgress(completedUnitCount: 1, totalUnitCount: 1, currentEntry: name))
        return ArchiveExtractionResult(
            format: .lz4,
            destinationURL: root,
            fileURLs: [root.appendingPathComponent(plan.relativePath)],
            entryCount: 1
        )
    }

    private func prepareDestination(_ url: URL) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ArchiveError.destinationNotDirectory(url.path)
        }
        if try ArchiveFileWriter.nodeKind(at: url) == .symbolicLink {
            throw ArchiveError.symbolicLinkNotAllowed(url.path)
        }
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.fileSystemError(path: url.path, reason: error.localizedDescription)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func lz4OutputName(_ suggestedName: String?) -> String {
        guard let suggestedName else { return "decompressed" }
        let name = URL(fileURLWithPath: suggestedName).lastPathComponent
        guard (name as NSString).pathExtension.lowercased() == "lz4" else { return "decompressed" }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "decompressed" : base
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

internal final class ArchiveCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancelled() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel || Task.isCancelled { throw ArchiveError.cancelled }
    }
}
