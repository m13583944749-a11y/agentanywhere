import Foundation

public enum DownloadState: String, Codable, Sendable {
    case resolving
    case waiting
    case downloading
    case paused
    case extracting
    case completed
    case failed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .resolving, .waiting, .downloading, .extracting: true
        default: false
        }
    }
}

public struct DownloadTask: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var resource: GameResource
    public var state: DownloadState
    public var fileName: String
    public var relativePath: String?
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var bytesPerSecond: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var retryCount: Int
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        resource: GameResource,
        state: DownloadState = .waiting,
        fileName: String? = nil,
        relativePath: String? = nil,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        retryCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.resource = resource
        self.state = state
        self.fileName = fileName ?? resource.fileName ?? resource.title
        self.relativePath = relativePath
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.bytesPerSecond = bytesPerSecond
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.retryCount = retryCount
        self.errorMessage = errorMessage
    }

    public var progress: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public var remainingSeconds: TimeInterval? {
        guard bytesPerSecond > 0, totalBytes > downloadedBytes else { return nil }
        return TimeInterval(totalBytes - downloadedBytes) / bytesPerSecond
    }
}

public struct DownloadSettings: Hashable, Codable, Sendable {
    public var maximumConcurrent: Int
    public var connectionsPerFile: Int
    public var maximumRetries: Int
    public var allowsCellular: Bool
    public var automaticallyExtract: Bool
    public var deleteArchiveAfterExtraction: Bool

    public init(
        maximumConcurrent: Int = 2,
        connectionsPerFile: Int = 1,
        maximumRetries: Int = 3,
        allowsCellular: Bool = false,
        automaticallyExtract: Bool = false,
        deleteArchiveAfterExtraction: Bool = false
    ) {
        self.maximumConcurrent = min(8, max(1, maximumConcurrent))
        self.connectionsPerFile = min(16, max(1, connectionsPerFile))
        self.maximumRetries = min(10, max(0, maximumRetries))
        self.allowsCellular = allowsCellular
        self.automaticallyExtract = automaticallyExtract
        self.deleteArchiveAfterExtraction = deleteArchiveAfterExtraction
    }
}
