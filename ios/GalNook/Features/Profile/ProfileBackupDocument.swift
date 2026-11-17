import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct ProfileBackupDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }
    public static var writableContentTypes: [UTType] { [.json] }

    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ProfileStoreError.invalidBackup("文件没有可读取的 JSON 内容。")
        }
        self.data = data
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
