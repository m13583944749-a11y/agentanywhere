import Foundation

public enum GalFormatters {
    public static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter
    }()

    public static func bytes(_ value: Int64) -> String {
        byteCount.string(fromByteCount: value)
    }

    public static func speed(_ value: Double) -> String {
        "\(byteCount.string(fromByteCount: Int64(max(0, value))))/s"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    public static func rating(_ value: Double?) -> String {
        guard let value else { return "暂无评分" }
        return String(format: "%.1f", value)
    }

    public static func safeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "GalNook-Download" : String(cleaned.prefix(180))
    }
}

public extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
