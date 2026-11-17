import Foundation

public actor JSONStore<Value: Codable & Sendable> {
    private let fileURL: URL
    private let defaultValue: Value
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, defaultValue: Value) {
        self.fileURL = fileURL
        self.defaultValue = defaultValue
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> Value {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return defaultValue }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            let backupURL = fileURL.appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return defaultValue
        }
    }

    public func save(_ value: Value) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        // Foundation's atomic writer creates a sibling temporary file and
        // replaces the destination on both Apple platforms and corelibs.
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum AppFileLocations {
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalNook", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var downloads: URL {
        let url = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var games: URL {
        let url = documents.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var state: URL {
        applicationSupport.appendingPathComponent("state.json")
    }
}
