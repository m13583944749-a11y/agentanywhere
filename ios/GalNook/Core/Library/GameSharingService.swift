import Foundation

public enum GameShareFormat: Sendable {
    case folder
    case zip
}

public struct GameSharePackage: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let isTemporary: Bool

    public init(url: URL, isTemporary: Bool) {
        self.url = url
        self.isTemporary = isTemporary
    }

    public func cleanup() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

public enum GameSharingError: LocalizedError {
    case gameDirectoryMissing
    case mutableFileChanged(String)

    public var errorDescription: String? {
        switch self {
        case .gameDirectoryMissing:
            "游戏文件夹不存在，无法分享"
        case .mutableFileChanged(let path):
            "导出期间文件发生变化：\(path)。请停止写入后重试"
        }
    }
}

/// Prepares an application-owned game folder for UIActivityViewController.
/// ZIP output uses the standard ZIP format with UTF-8 names and ZIP64 for large games.
public struct GameSharingService: Sendable {
    public let store: GameLibraryStore

    public init(store: GameLibraryStore = GameLibraryStore()) {
        self.store = store
    }

    public func package(game: LocalGame, format: GameShareFormat) throws -> GameSharePackage {
        let folder = try store.gameURL(for: game)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GameSharingError.gameDirectoryMissing
        }
        guard folder.standardizedFileURL.path != store.gamesDirectory.standardizedFileURL.path else {
            throw GameLibraryError.unsupportedShareRoot
        }

        switch format {
        case .folder:
            return GameSharePackage(url: folder, isTemporary: false)
        case .zip:
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("GalNookShare", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            let filename = GalFormatters.safeFileName(game.title) + ".zip"
            let output = temporaryRoot.appendingPathComponent(filename)
            do {
                try ZipArchiveWriter.write(folder: folder, to: output)
                return GameSharePackage(url: output, isTemporary: true)
            } catch {
                try? FileManager.default.removeItem(at: temporaryRoot)
                throw error
            }
        }
    }
}

private final class ZipArchiveWriter {
    private struct Record {
        let name: Data
        let crc32: UInt32
        let size: UInt64
        let offset: UInt64
        let isDirectory: Bool
        let modificationDate: Date
    }

    private let output: FileHandle
    private var records: [Record] = []

    private init(output: FileHandle) {
        self.output = output
    }

    static func write(folder: URL, to outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        let writer = ZipArchiveWriter(output: handle)
        do {
            try writer.addContents(of: folder)
            try writer.finish()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func addContents(of folder: URL) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys
        ) else {
            throw GameSharingError.gameDirectoryMissing
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let relative = Self.relativePath(of: url, root: folder)
            guard !relative.isEmpty else { continue }
            let isDirectory = values.isDirectory == true
            let name = isDirectory && !relative.hasSuffix("/") ? relative + "/" : relative
            guard let nameData = name.data(using: .utf8), nameData.count <= Int(UInt16.max) else {
                throw GameLibraryError.invalidRelativePath(relative)
            }
            let date = values.contentModificationDate ?? .now
            if isDirectory {
                try writeEntry(
                    name: nameData,
                    source: nil,
                    expectedSize: 0,
                    modificationDate: date
                )
            } else {
                let size = UInt64(max(0, values.fileSize ?? 0))
                try writeEntry(
                    name: nameData,
                    source: url,
                    expectedSize: size,
                    modificationDate: date
                )
            }
        }
    }

    private func writeEntry(
        name: Data,
        source: URL?,
        expectedSize: UInt64,
        modificationDate: Date
    ) throws {
        let offset = try currentOffset()
        let needsZip64 = expectedSize >= UInt64(UInt32.max)
        let extra = needsZip64 ? Self.zip64SizesExtra(expectedSize) : Data()

        try writeUInt32(0x0403_4B50)
        try writeUInt16(needsZip64 ? 45 : 20)
        try writeUInt16(0x0800) // UTF-8 file names
        try writeUInt16(0) // Stored; no lossy or platform-specific compression.
        let (time, date) = Self.dosTimeAndDate(modificationDate)
        try writeUInt16(time)
        try writeUInt16(date)
        try writeUInt32(0) // CRC and sizes are patched after streaming the file.
        try writeUInt32(needsZip64 ? UInt32.max : 0)
        try writeUInt32(needsZip64 ? UInt32.max : 0)
        try writeUInt16(UInt16(name.count))
        try writeUInt16(UInt16(extra.count))
        try writeData(name)
        try writeData(extra)

        var crc: UInt32 = 0
        var actualSize: UInt64 = 0
        if let source {
            let input = try FileHandle(forReadingFrom: source)
            do {
                crc = 0xFFFF_FFFF
                while true {
                    let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    crc = CRC32.update(crc, bytes: data)
                    try writeData(data)
                    actualSize += UInt64(data.count)
                }
                crc ^= 0xFFFF_FFFF
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
        }
        guard actualSize == expectedSize else {
            throw GameSharingError.mutableFileChanged(source?.lastPathComponent ?? nameDescription(name))
        }

        let end = try currentOffset()
        try output.seek(toOffset: offset + 14)
        try writeUInt32(crc)
        if needsZip64 {
            try writeUInt32(UInt32.max)
            try writeUInt32(UInt32.max)
        } else {
            try writeUInt32(UInt32(actualSize))
            try writeUInt32(UInt32(actualSize))
        }
        try output.seek(toOffset: end)
        records.append(Record(
            name: name,
            crc32: crc,
            size: actualSize,
            offset: offset,
            isDirectory: source == nil,
            modificationDate: modificationDate
        ))
    }

    private func finish() throws {
        let centralOffset = try currentOffset()
        for record in records {
            let size64 = record.size >= UInt64(UInt32.max)
            let offset64 = record.offset >= UInt64(UInt32.max)
            let extra = Self.zip64CentralExtra(
                size: record.size,
                offset: record.offset,
                includesSizes: size64,
                includesOffset: offset64
            )

            try writeUInt32(0x0201_4B50)
            try writeUInt16(0x0314) // Unix, spec 2.0; attributes below are portable.
            try writeUInt16(size64 || offset64 ? 45 : 20)
            try writeUInt16(0x0800)
            try writeUInt16(0)
            let (time, date) = Self.dosTimeAndDate(record.modificationDate)
            try writeUInt16(time)
            try writeUInt16(date)
            try writeUInt32(record.crc32)
            try writeUInt32(size64 ? UInt32.max : UInt32(record.size))
            try writeUInt32(size64 ? UInt32.max : UInt32(record.size))
            try writeUInt16(UInt16(record.name.count))
            try writeUInt16(UInt16(extra.count))
            try writeUInt16(0) // File comment length
            try writeUInt16(0) // Disk number
            try writeUInt16(0) // Internal attributes
            if record.isDirectory {
                try writeUInt32(0x10 | (0o040755 << 16))
            } else {
                try writeUInt32(UInt32(0o100644) << 16)
            }
            try writeUInt32(offset64 ? UInt32.max : UInt32(record.offset))
            try writeData(record.name)
            try writeData(extra)
        }
        let centralEnd = try currentOffset()
        let centralSize = centralEnd - centralOffset
        let count = records.count
        let needsZip64End = count >= Int(UInt16.max) || centralOffset >= UInt64(UInt32.max) || centralSize >= UInt64(UInt32.max)

        if needsZip64End {
            let zip64EndOffset = try currentOffset()
            try writeUInt32(0x0606_4B50)
            try writeUInt64(44)
            try writeUInt16(0x0314)
            try writeUInt16(45)
            try writeUInt32(0)
            try writeUInt32(0)
            try writeUInt64(UInt64(count))
            try writeUInt64(UInt64(count))
            try writeUInt64(centralSize)
            try writeUInt64(centralOffset)

            try writeUInt32(0x0706_4B50)
            try writeUInt32(0)
            try writeUInt64(zip64EndOffset)
            try writeUInt32(1)
        }

        try writeUInt32(0x0605_4B50)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(count >= Int(UInt16.max) ? UInt16.max : UInt16(count))
        try writeUInt16(count >= Int(UInt16.max) ? UInt16.max : UInt16(count))
        try writeUInt32(centralSize >= UInt64(UInt32.max) ? UInt32.max : UInt32(centralSize))
        try writeUInt32(centralOffset >= UInt64(UInt32.max) ? UInt32.max : UInt32(centralOffset))
        try writeUInt16(0)
    }

    private func currentOffset() throws -> UInt64 {
        try output.seekToEnd()
    }

    private func writeData(_ data: Data) throws {
        try output.write(contentsOf: data)
    }

    private func writeUInt16(_ value: UInt16) throws { try writeInteger(value) }
    private func writeUInt32(_ value: UInt32) throws { try writeInteger(value) }
    private func writeUInt64(_ value: UInt64) throws { try writeInteger(value) }

    private func writeInteger<T: FixedWidthInteger>(_ value: T) throws {
        var littleEndian = value.littleEndian
        try writeData(Data(bytes: &littleEndian, count: MemoryLayout<T>.size))
    }

    private static func zip64SizesExtra(_ size: UInt64) -> Data {
        var data = Data()
        appendUInt16(0x0001, to: &data)
        appendUInt16(16, to: &data)
        appendUInt64(size, to: &data)
        appendUInt64(size, to: &data)
        return data
    }

    private static func zip64CentralExtra(
        size: UInt64,
        offset: UInt64,
        includesSizes: Bool,
        includesOffset: Bool
    ) -> Data {
        guard includesSizes || includesOffset else { return Data() }
        var data = Data()
        let payloadSize = (includesSizes ? 16 : 0) + (includesOffset ? 8 : 0)
        appendUInt16(0x0001, to: &data)
        appendUInt16(UInt16(payloadSize), to: &data)
        if includesSizes {
            appendUInt64(size, to: &data)
            appendUInt64(size, to: &data)
        }
        if includesOffset { appendUInt64(offset, to: &data) }
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var value = value.littleEndian
        data.append(Data(bytes: &value, count: 2))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var value = value.littleEndian
        data.append(Data(bytes: &value, count: 8))
    }

    private static func dosTimeAndDate(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = min(2107, max(1980, components.year ?? 1980))
        let month = min(12, max(1, components.month ?? 1))
        let day = min(31, max(1, components.day ?? 1))
        let hour = min(23, max(0, components.hour ?? 0))
        let minute = min(59, max(0, components.minute ?? 0))
        let second = min(59, max(0, components.second ?? 0))
        let dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        return (dosTime, dosDate)
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    private func nameDescription(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "未知文件"
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func update(_ initial: UInt32, bytes: Data) -> UInt32 {
        var crc = initial
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<buffer.count {
                crc = table[Int((crc ^ UInt32(base[index])) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc
    }
}
