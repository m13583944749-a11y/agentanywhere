import XCTest
@testable import GalNook

final class ArchiveTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    func testFormatDetectionUsesMagicBeforeExtension() throws {
        XCTAssertEqual(try ArchiveService.detectFormat(
            data: Data([0x50, 0x4B, 0x03, 0x04]), fileName: "wrong.rar"), .zip)
        XCTAssertEqual(try ArchiveService.detectFormat(
            data: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])), .rar)
        XCTAssertEqual(try ArchiveService.detectFormat(
            data: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])), .sevenZip)
        XCTAssertEqual(try ArchiveService.detectFormat(
            data: Data([0x04, 0x22, 0x4D, 0x18])), .lz4)
        XCTAssertEqual(try ArchiveService.detectFormat(
            data: Data([0x50, 0x2A, 0x4D, 0x18])), .lz4)
        XCTAssertEqual(try ArchiveService.detectFormat(data: Data([0]), fileName: "a.7z"), .sevenZip)
        XCTAssertThrowsError(try ArchiveService.detectFormat(data: Data([0]), fileName: "a.bin"))
        XCTAssertThrowsError(try ArchiveService.detectFormat(data: Data()))
    }

    func testStoredZipExtractionFromDataAndFile() async throws {
        let payload = Data("Hello, ZIP!".utf8)
        let archive = TestZIP.make(entries: [
            .init(name: "folder/", data: Data(), kind: .directory),
            .init(name: "folder/message.txt", data: payload, kind: .regular)
        ])
        let destination = temporaryURL.appendingPathComponent("data-output")
        let recorder = ProgressRecorder()
        let service = ArchiveService()

        let result = try await service.extractArchive(
            data: archive,
            suggestedName: "sample.zip",
            to: destination,
            progress: { recorder.append($0) }
        )

        XCTAssertEqual(result.format, .zip)
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("folder/message.txt")), payload)
        XCTAssertEqual(recorder.values.last?.fractionCompleted, 1)
        XCTAssertEqual(recorder.values.last?.currentEntry, "folder/message.txt")

        let source = temporaryURL.appendingPathComponent("sample.zip")
        try archive.write(to: source)
        let fileResult = try await service.extractArchive(
            at: source,
            to: temporaryURL.appendingPathComponent("file-output")
        )
        XCTAssertEqual(fileResult.fileURLs.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: fileResult.destinationURL.appendingPathComponent("folder/message.txt")),
            payload
        )
    }

    func testDeflatedZipFixture() async throws {
        let archive = Data(base64Encoded: TestFixtures.deflatedZip)!
        let destination = temporaryURL.appendingPathComponent("deflated-output")
        _ = try await ArchiveService().extractArchive(
            data: archive,
            suggestedName: "deflated.zip",
            to: destination
        )
        var repeated = Data("Deflated ZIP payload: ".utf8)
        for _ in 0..<100 { repeated.append(Data("abcde".utf8)) }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("deflated/message.txt")),
            repeated
        )
    }

    func testRealSevenZipFixture() async throws {
        let archive = Data(base64Encoded: TestFixtures.sevenZip)!
        let destination = temporaryURL.appendingPathComponent("7z-output")
        let result = try await ArchiveService().extractArchive(
            data: archive,
            suggestedName: "fixture.7z",
            to: destination
        )
        XCTAssertEqual(result.format, .sevenZip)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("nested/hello.txt")),
            Data("Hello, 7z!\n".utf8)
        )
    }

    func testRealLZ4AndConcatenatedFrames() async throws {
        let frame = Data(base64Encoded: TestFixtures.lz4Frame)!
        var archive = frame
        archive.append(frame)
        let destination = temporaryURL.appendingPathComponent("lz4-output")
        let result = try await ArchiveService().extractArchive(
            data: archive,
            suggestedName: "message.txt.lz4",
            to: destination
        )
        XCTAssertEqual(result.format, .lz4)
        XCTAssertEqual(result.fileURLs.count, 1)
        XCTAssertEqual(result.fileURLs[0].lastPathComponent, "message.txt")
        XCTAssertEqual(
            try Data(contentsOf: result.fileURLs[0]),
            Data("Hello, LZ4 frame!\nHello, LZ4 frame!\n".utf8)
        )
    }

    func testZipSlipAbsoluteAndWindowsPathsAreRejectedBeforeWriting() async {
        for path in ["../escape.txt", "..\\escape.txt", "/absolute.txt", "C:\\escape.txt"] {
            let archive = TestZIP.make(entries: [.init(name: path, data: Data("bad".utf8), kind: .regular)])
            let destination = temporaryURL.appendingPathComponent(UUID().uuidString)
            await assertArchiveError(.unsafeEntryPath(path)) {
                _ = try await ArchiveService().extractArchive(
                    data: archive,
                    suggestedName: "unsafe.zip",
                    to: destination
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.deletingLastPathComponent()
            .appendingPathComponent("escape.txt").path))
    }

    func testZipSymbolicLinkEntryIsRejected() async {
        let archive = TestZIP.make(entries: [
            .init(name: "link", data: Data("../escape".utf8), kind: .symbolicLink)
        ])
        await assertArchiveError(.symbolicLinkNotAllowed("link")) {
            _ = try await ArchiveService().extractArchive(
                data: archive,
                suggestedName: "link.zip",
                to: temporaryURL.appendingPathComponent("link-output")
            )
        }
    }

    func testExistingDestinationSymlinkIsRejected() async throws {
        let outside = temporaryURL.appendingPathComponent("outside")
        let destination = temporaryURL.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: destination.appendingPathComponent("link").path,
            withDestinationPath: outside.path
        )
        let archive = TestZIP.make(entries: [
            .init(name: "link/escaped.txt", data: Data("bad".utf8), kind: .regular)
        ])

        do {
            _ = try await ArchiveService().extractArchive(
                data: archive,
                suggestedName: "link.zip",
                to: destination
            )
            XCTFail("Expected symbolicLinkNotAllowed")
        } catch let error as ArchiveError {
            guard case .symbolicLinkNotAllowed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
    }

    func testEncryptedZipHasExplicitPasswordErrors() async {
        let archive = TestZIP.make(entries: [
            .init(name: "secret.txt", data: Data("not really encrypted".utf8), kind: .regular, flags: 1)
        ])
        await assertArchiveError(.passwordRequired(format: .zip)) {
            _ = try await ArchiveService().extractArchive(
                data: archive,
                suggestedName: "secret.zip",
                to: temporaryURL.appendingPathComponent("without-password")
            )
        }
        await assertArchiveError(.passwordUnsupported(format: .zip)) {
            _ = try await ArchiveService().extractArchive(
                data: archive,
                suggestedName: "secret.zip",
                to: temporaryURL.appendingPathComponent("with-password"),
                password: "secret"
            )
        }
    }

    func testEncryptedSevenZipHasExplicitPasswordErrors() async {
        let archive = Data(base64Encoded: TestFixtures.encryptedSevenZip)!
        await assertArchiveError(.passwordRequired(format: .sevenZip)) {
            _ = try await ArchiveService().extractArchive(
                data: archive,
                suggestedName: "secret.7z",
                to: temporaryURL.appendingPathComponent("7z-without-password")
            )
        }
        await assertArchiveError(.passwordUnsupported(format: .sevenZip)) {
            _ = try await ArchiveService().extractArchive(
                data: archive,
                suggestedName: "secret.7z",
                to: temporaryURL.appendingPathComponent("7z-with-password"),
                password: "secret"
            )
        }
    }

    func testRARIsExplicitlyUnsupportedAndCanUseIndependentBackend() async throws {
        let rar = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
        do {
            _ = try await ArchiveService().extractArchive(
                data: rar,
                suggestedName: "game.rar",
                to: temporaryURL.appendingPathComponent("rar-default")
            )
            XCTFail("Expected unsupportedFormat")
        } catch let error as ArchiveError {
            guard case let .unsupportedFormat(format, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(format, .rar)
        }

        let destination = temporaryURL.appendingPathComponent("rar-custom")
        let result = try await ArchiveService(additionalBackends: [StubRARBackend()]).extractArchive(
            data: rar,
            suggestedName: "game.rar",
            to: destination
        )
        XCTAssertEqual(result.format, .rar)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("from-rar.txt")), Data("ok".utf8))
    }

    func testCancellationAndLZ4PasswordError() async throws {
        let service = ArchiveService()
        let archive = TestZIP.make(entries: [
            .init(name: "file.txt", data: Data("content".utf8), kind: .regular)
        ])
        await assertArchiveError(.cancelled) {
            _ = try await service.extractArchive(
                data: archive,
                suggestedName: "cancel.zip",
                to: temporaryURL.appendingPathComponent("cancelled"),
                progress: { _ in service.cancel() }
            )
        }

        let frame = Data(base64Encoded: TestFixtures.lz4Frame)!
        await assertArchiveError(.passwordUnsupported(format: .lz4)) {
            _ = try await ArchiveService().extractArchive(
                data: frame,
                suggestedName: "frame.lz4",
                to: temporaryURL.appendingPathComponent("lz4-password"),
                password: "unused"
            )
        }
    }

    private func assertArchiveError(
        _ expected: ArchiveError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as ArchiveError {
            XCTAssertTrue(error == expected, "Expected \(expected), got \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArchiveProgress] = []

    var values: [ArchiveProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: ArchiveProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}

private struct StubRARBackend: ArchiveBackend {
    let format: ArchiveFormat = .rar

    func readEntries(from data: Data, password: String?) throws -> [ArchiveEntry] {
        [ArchiveEntry(path: "from-rar.txt", kind: .regular, data: Data("ok".utf8))]
    }
}

private enum TestFixtures {
    // Python zipfile, ZIP_DEFLATED, containing deflated/message.txt.
    static let deflatedZip = "UEsDBBQAAAAIAK0Ecl30IDNYIQAAAAoCAAAUAAAAZGVmbGF0ZWQvbWVzc2FnZS50eHRzSU3LSSxJTVGI8gxQKEiszMlPTLFSSExKTkkdJUYUAQBQSwECFAMUAAAACACtBHJd9CAzWCEAAAAKAgAAFAAAAAAAAAAAAAAAgAEAAAAAZGVmbGF0ZWQvbWVzc2FnZS50eHRQSwUGAAAAAAEAAQBCAAAAUwAAAAAA"
    // py7zr LZMA2 archive (without a Delta filter) containing nested/hello.txt = "Hello, 7z!\n".
    static let sevenZip = "N3q8ryccAAR1m1YCbwAAAAAAAAAUAAAAAAAAANhZ700BAApIZWxsbywgN3ohCgDgAF4AWF0AAIEzB64Pzt0HYQkqrtOqTJkVBr3mSIPRx5GoIFTjjZFksOgXvGRsIquFb0qmYjxbMN3ziFk7oqA8WHgrqJHznShNsDoLHKbKAvxY6wBEdrd1ULIXciAAAAAXBg8BCWAABwsBAAEhIQEYDF8AAA=="
    // Password-protected py7zr archive; SWCompression rejects its encrypted header/coder.
    static let encryptedSevenZip = "N3q8ryccAAT9p9mNbwAAAAAAAAAoAAAAAAAAAAHupJIBAApIZWxsbywgN3ohCgBV0ILtu1fX2UxmVwstuFRA7Fl8wYzCYJXA1zUqk0t7/EYTqZ/pmFyK803aSGSY8UEp9pTiXmb7omVnqwwx1WFl3vXjcJzLpoDlzSu4yy0igzbhITsiS6NW2MOIyi3ZlJAXBg8BCWAABwsBAAEkBvEHARJTD1CUOd0J1fl8mvdanaAcHcwMVwAA"
    // Standard LZ4 frame containing "Hello, LZ4 frame!\n".
    static let lz4Frame = "BCJNGGhAEgAAAAAAAADZEgAAgEhlbGxvLCBMWjQgZnJhbWUhCgAAAAA="
}

private struct TestZIPEntry {
    enum Kind {
        case regular
        case directory
        case symbolicLink
    }

    let name: String
    let data: Data
    let kind: Kind
    var flags: UInt16 = 0
}

/// Minimal standards-compliant stored-ZIP writer used only to make test inputs.
private enum TestZIP {
    static func make(entries: [TestZIPEntry]) -> Data {
        var local = Data()
        var central = Data()
        var centralRecords: [Data] = []

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(local.count)
            append(UInt32(0x04034B50), to: &local)
            append(UInt16(20), to: &local)
            append(entry.flags, to: &local)
            append(UInt16(0), to: &local) // Stored, no compression.
            append(UInt16(0), to: &local)
            append(UInt16(0), to: &local)
            append(crc, to: &local)
            append(UInt32(entry.data.count), to: &local)
            append(UInt32(entry.data.count), to: &local)
            append(UInt16(name.count), to: &local)
            append(UInt16(0), to: &local)
            local.append(name)
            local.append(entry.data)

            var record = Data()
            append(UInt32(0x02014B50), to: &record)
            append(UInt16(0x0314), to: &record) // UNIX, ZIP 2.0.
            append(UInt16(20), to: &record)
            append(entry.flags, to: &record)
            append(UInt16(0), to: &record)
            append(UInt16(0), to: &record)
            append(UInt16(0), to: &record)
            append(crc, to: &record)
            append(UInt32(entry.data.count), to: &record)
            append(UInt32(entry.data.count), to: &record)
            append(UInt16(name.count), to: &record)
            append(UInt16(0), to: &record)
            append(UInt16(0), to: &record)
            append(UInt16(0), to: &record)
            append(UInt16(0), to: &record)
            append(externalAttributes(for: entry.kind), to: &record)
            append(offset, to: &record)
            record.append(name)
            centralRecords.append(record)
        }

        for record in centralRecords { central.append(record) }
        var archive = local
        archive.append(central)
        append(UInt32(0x06054B50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(entries.count), to: &archive)
        append(UInt16(entries.count), to: &archive)
        append(UInt32(central.count), to: &archive)
        append(UInt32(local.count), to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }

    private static func externalAttributes(for kind: TestZIPEntry.Kind) -> UInt32 {
        switch kind {
        case .regular: return UInt32(0o100644) << 16
        case .directory: return (UInt32(0o040755) << 16) | 0x10
        case .symbolicLink: return UInt32(0o120777) << 16
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
            }
        }
        return crc ^ UInt32.max
    }
}
