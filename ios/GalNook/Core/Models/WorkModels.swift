import Foundation

public enum WorkSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case nextMoe
    case vndb
    case ymgal
    case cnGal
    case searchGal
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nextMoe: "NextMoe"
        case .vndb: "VNDB"
        case .ymgal: "月幕 Galgame"
        case .cnGal: "CnGal"
        case .searchGal: "SearchGal"
        case .local: "本地"
        }
    }
}

public struct WorkSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(source.rawValue):\(sourceID)" }
    public var source: WorkSource
    public var sourceID: String
    public var title: String
    public var originalTitle: String?
    public var coverURL: URL?
    public var releaseDate: String?
    public var rating: Double?
    public var ratingCount: Int?
    public var developerNames: [String]
    public var tags: [String]

    public init(
        source: WorkSource,
        sourceID: String,
        title: String,
        originalTitle: String? = nil,
        coverURL: URL? = nil,
        releaseDate: String? = nil,
        rating: Double? = nil,
        ratingCount: Int? = nil,
        developerNames: [String] = [],
        tags: [String] = []
    ) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.originalTitle = originalTitle
        self.coverURL = coverURL
        self.releaseDate = releaseDate
        self.rating = rating
        self.ratingCount = ratingCount
        self.developerNames = developerNames
        self.tags = tags
    }

    public var searchableText: String {
        [title, originalTitle ?? "", developerNames.joined(separator: " "), tags.joined(separator: " ")]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct WorkDetail: Identifiable, Hashable, Codable, Sendable {
    public var id: String { summary.id }
    public var summary: WorkSummary
    public var aliases: [String]
    public var description: String?
    public var publishers: [String]
    public var links: [ExternalLink]
    public var characters: [GameCharacter]
    public var comments: [RemoteComment]
    public var staff: [StaffMember]
    public var screenshots: [URL]
    public var relatedWorkIDs: [String]
    public var relatedWorks: [WorkSummary]

    public init(
        summary: WorkSummary,
        aliases: [String] = [],
        description: String? = nil,
        publishers: [String] = [],
        links: [ExternalLink] = [],
        characters: [GameCharacter] = [],
        comments: [RemoteComment] = [],
        staff: [StaffMember] = [],
        screenshots: [URL] = [],
        relatedWorkIDs: [String] = [],
        relatedWorks: [WorkSummary] = []
    ) {
        self.summary = summary
        self.aliases = aliases
        self.description = description
        self.publishers = publishers
        self.links = links
        self.characters = characters
        self.comments = comments
        self.staff = staff
        self.screenshots = screenshots
        self.relatedWorkIDs = relatedWorkIDs
        self.relatedWorks = relatedWorks
    }
}

public struct GameCharacter: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var originalName: String?
    public var role: String?
    public var description: String?
    public var imageURL: URL?
    public var birthday: String?
    public var bloodType: String?
    public var height: String?
    public var measurements: String?
    public var voiceActor: String?

    public init(
        id: String,
        name: String,
        originalName: String? = nil,
        role: String? = nil,
        description: String? = nil,
        imageURL: URL? = nil,
        birthday: String? = nil,
        bloodType: String? = nil,
        height: String? = nil,
        measurements: String? = nil,
        voiceActor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.originalName = originalName
        self.role = role
        self.description = description
        self.imageURL = imageURL
        self.birthday = birthday
        self.bloodType = bloodType
        self.height = height
        self.measurements = measurements
        self.voiceActor = voiceActor
    }
}

public struct StaffMember: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(name):\(role)" }
    public var name: String
    public var role: String

    public init(name: String, role: String) {
        self.name = name
        self.role = role
    }
}

public struct ExternalLink: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(title):\(url.absoluteString)" }
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public struct RemoteComment: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var author: String
    public var content: String
    public var translatedContent: String?
    public var rating: Double?
    public var createdAt: String?
    public var hasSpoilers: Bool

    public init(id: String, author: String, content: String, translatedContent: String? = nil, rating: Double? = nil, createdAt: String? = nil, hasSpoilers: Bool = false) {
        self.id = id
        self.author = author
        self.content = content
        self.translatedContent = translatedContent
        self.rating = rating
        self.createdAt = createdAt
        self.hasSpoilers = hasSpoilers
    }
}

public struct Walkthrough: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var workID: String
    public var title: String
    public var content: String
    public var sourceURL: URL?
    public var isAdultOnly: Bool
    public var updatedAt: Date?

    public init(
        id: String,
        workID: String,
        title: String,
        content: String,
        sourceURL: URL? = nil,
        isAdultOnly: Bool = false,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.workID = workID
        self.title = title
        self.content = content
        self.sourceURL = sourceURL
        self.isAdultOnly = isAdultOnly
        self.updatedAt = updatedAt
    }
}

public struct WorkPage: Sendable {
    public var items: [WorkSummary]
    public var page: Int
    public var hasMore: Bool
    public var nextCursor: String?

    public init(items: [WorkSummary], page: Int, hasMore: Bool, nextCursor: String? = nil) {
        self.items = items
        self.page = page
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

public enum WorkSort: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case popularity
    case nextMoeRating
    case vndbRating
    case erogameRating
    case releaseDate

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .popularity: "热度"
        case .nextMoeRating: "NextMoe 评分"
        case .vndbRating: "VNDB 评分"
        case .erogameRating: "批评空间评分"
        case .releaseDate: "发售日期"
        }
    }
}

public struct WorkFilter: Hashable, Codable, Sendable {
    public var language: String?
    public var platform: String?
    public var year: Int?
    public var minimumScore: Double?
    public var tagID: String?
    public var tagName: String?

    public init(language: String? = nil, platform: String? = nil, year: Int? = nil, minimumScore: Double? = nil, tagID: String? = nil, tagName: String? = nil) {
        self.language = language
        self.platform = platform
        self.year = year
        self.minimumScore = minimumScore
        self.tagID = tagID
        self.tagName = tagName
    }

    public var isActive: Bool {
        language != nil || platform != nil || year != nil || minimumScore != nil || tagID != nil
    }
}

public struct CatalogTag: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isSexual: Bool

    public init(id: String, name: String, isSexual: Bool = false) {
        self.id = id
        self.name = name
        self.isSexual = isSexual
    }
}

public enum WorkQuery: Hashable, Sendable {
    case popular
    case latest
    case highlyRated
    case random
    case search(String)
    case tag(String)
    case company(String)
    case advanced(search: String?, sort: WorkSort, filter: WorkFilter)
}
