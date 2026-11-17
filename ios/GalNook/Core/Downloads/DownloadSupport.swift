import Foundation

public enum DownloadError: LocalizedError, Sendable {
    case missingDirectURL
    case unsupportedURL(URL)
    case noResolver(PanProvider)
    case invalidResponse
    case httpStatus(Int)
    case invalidContentRange(String)
    case unexpectedContentType(String)
    case incompleteDownload(expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case .missingDirectURL:
            return "资源没有可下载的直链"
        case .unsupportedURL(let url):
            return "不支持的下载地址：\(url.absoluteString)"
        case .noResolver(let provider):
            return "尚未注册 \(provider.displayName) 下载解析器"
        case .invalidResponse:
            return "下载服务器返回了无效响应"
        case .httpStatus(let status):
            return "下载失败（HTTP \(status)）"
        case .invalidContentRange(let value):
            return "服务器返回了无效的 Content-Range：\(value)"
        case .unexpectedContentType(let value):
            return "下载地址返回的是网页（\(value)），不是游戏文件。请回到资源页，点“打开页面”并在网站内获取真实下载链接。"
        case .incompleteDownload(let expected, let actual):
            return "下载数据不完整：应为 \(expected) 字节，实际为 \(actual) 字节"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .httpStatus(let status):
            return status == 408 || status == 429 || status >= 500
        case .incompleteDownload, .invalidResponse, .invalidContentRange:
            return true
        case .missingDirectURL, .unsupportedURL, .noResolver, .unexpectedContentType:
            return false
        }
    }
}

enum DownloadFilename {
    private static let invalidCharacters: CharacterSet = {
        var characters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        characters.formUnion(.controlCharacters)
        return characters
    }()

    static func sanitize(_ proposedName: String, fallback: String = "download") -> String {
        // A resolver is untrusted input: never allow it to choose a directory.
        let slashNormalized = proposedName.replacingOccurrences(of: "\\", with: "/")
        let component = slashNormalized.split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        var name = component.components(separatedBy: invalidCharacters).joined(separator: "_")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = fallback
        }

        let nsName = name as NSString
        let pathExtension = nsName.pathExtension
        var baseName = pathExtension.isEmpty ? name : nsName.deletingPathExtension
        let safeExtension = truncateUTF8(pathExtension, limit: 40)
        baseName = truncateUTF8(baseName, limit: 160)
        if baseName.isEmpty { baseName = fallback }

        let reservedNames: Set<String> = [
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4",
            "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2",
            "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]
        if reservedNames.contains(baseName.uppercased()) {
            baseName = "_" + baseName
        }
        return safeExtension.isEmpty ? baseName : "\(baseName).\(safeExtension)"
    }

    static func uniqueDestination(
        fileName: String,
        directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let safeName = sanitize(fileName)
        let nsName = safeName as NSString
        let pathExtension = nsName.pathExtension
        let baseName = pathExtension.isEmpty ? safeName : nsName.deletingPathExtension
        var candidate = directory.appendingPathComponent(safeName, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let candidateName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    private static func truncateUTF8(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = String()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let width = String(scalar).utf8.count
            guard byteCount + width <= limit else { break }
            result.unicodeScalars.append(scalar)
            byteCount += width
        }
        return result
    }
}

struct DownloadResumeMetadata: Codable, Sendable {
    var eTag: String?
    var lastModified: String?
    var totalBytes: Int64
}

struct DownloadProgress: Sendable {
    var downloadedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double
}

struct DownloadEngineResult: Sendable {
    var downloadedBytes: Int64
    var totalBytes: Int64
}

enum DownloadFileSupport {
    static func partialURL(for id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).partial", isDirectory: false)
    }

    static func metadataURL(for id: UUID, directory: URL) -> URL {
        partialURL(for: id, directory: directory).appendingPathExtension("json")
    }

    static func fileSize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    static func loadMetadata(_ url: URL) -> DownloadResumeMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DownloadResumeMetadata.self, from: data)
    }

    static func saveMetadata(_ metadata: DownloadResumeMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    static func removePartialAndMetadata(for id: UUID, directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partialURL(for: id, directory: directory))
        try? fileManager.removeItem(at: metadataURL(for: id, directory: directory))
    }
}
