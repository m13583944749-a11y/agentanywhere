import Foundation

public enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值") }
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_992 {
                return String(format: "%.0f", value)
            }
            return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    public var int: Int? {
        guard let double, double.isFinite, double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    public var int64: Int64? {
        guard let double, double.isFinite, double >= -9_223_372_036_854_775_000, double <= 9_223_372_036_854_775_000 else { return nil }
        return Int64(double)
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    public var url: URL? {
        guard var value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        return URL(string: value)
    }

    public subscript(key: String) -> JSONValue? { object?[key] }
    public subscript(index: Int) -> JSONValue? { array?[safe: index] }

    public func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string?.nilIfBlank { return value }
        }
        return nil
    }

    public func dig(_ path: String...) -> JSONValue? {
        var current: JSONValue? = self
        for component in path {
            if let index = Int(component) { current = current?[index] }
            else { current = current?[component] }
        }
        return current
    }

    public static func objectValue(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
