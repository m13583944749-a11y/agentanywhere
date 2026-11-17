import Foundation

public enum WorkRecordState: String, Codable, CaseIterable, Identifiable, Sendable {
    case unmarked
    case playing
    case played
    case abandoned

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unmarked: "未标记"
        case .playing: "在玩"
        case .played: "已玩"
        case .abandoned: "弃坑"
        }
    }

    public var systemImage: String {
        switch self {
        case .unmarked: "circle"
        case .playing: "play.circle.fill"
        case .played: "checkmark.circle.fill"
        case .abandoned: "stop.circle"
        }
    }
}

public struct WorkRecord: Identifiable, Hashable, Codable, Sendable {
    public typealias State = WorkRecordState

    public var id: String { work.id }
    public var work: WorkSummary
    public var state: WorkRecordState
    /// `nil` means unrated; persisted values are validated in the closed range 0...10.
    public var score: Int?
    public var favorite: Bool
    public var updatedAt: Date

    public init(
        work: WorkSummary,
        state: WorkRecordState = .unmarked,
        score: Int? = nil,
        favorite: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.work = work
        self.state = state
        self.score = score
        self.favorite = favorite
        self.updatedAt = updatedAt
    }
}

public struct WorkReview: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var work: WorkSummary
    public var workID: String { work.id }
    /// `nil` means unrated; persisted values are validated in the closed range 0...10.
    public var score: Int?
    public var content: String
    public var spoiler: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        work: WorkSummary,
        score: Int? = nil,
        content: String,
        spoiler: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.work = work
        self.score = score
        self.content = content
        self.spoiler = spoiler
        self.createdAt = createdAt
    }
}

public struct ProfileSnapshot: Codable, Equatable, Sendable {
    public var displayName: String
    public var avatarFileName: String?
    public var records: [WorkRecord]
    public var reviews: [WorkReview]

    public init(
        displayName: String = "本地用户",
        avatarFileName: String? = nil,
        records: [WorkRecord] = [],
        reviews: [WorkReview] = []
    ) {
        self.displayName = displayName
        self.avatarFileName = avatarFileName
        self.records = records
        self.reviews = reviews
    }
}

public struct ProfileAvatarBackup: Codable, Equatable, Sendable {
    /// The original name is informational. Imports always generate a local safe name.
    public var fileName: String
    /// JSONEncoder stores this as Base64, making the JSON backup self-contained.
    public var data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public struct ProfileBackup: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var displayName: String
    public var avatar: ProfileAvatarBackup?
    public var records: [WorkRecord]
    public var reviews: [WorkReview]

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        displayName: String = "本地用户",
        avatar: ProfileAvatarBackup? = nil,
        records: [WorkRecord] = [],
        reviews: [WorkReview] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.displayName = displayName
        self.avatar = avatar
        self.records = records
        self.reviews = reviews
    }
}
