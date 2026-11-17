import Foundation
import SWCompression

internal struct ZipArchiveBackend: ArchiveBackend {
    let format: ArchiveFormat = .zip

    func readEntries(from data: Data, password: String?) throws -> [ArchiveEntry] {
        do {
            return try ZipContainer.open(container: data).map { entry in
                ArchiveEntry(
                    path: entry.info.name,
                    kind: archiveEntryKind(entry.info.type),
                    data: entry.data
                )
            }
        } catch let error as ZipError {
            if case .encryptionNotSupported = error {
                throw password == nil
                    ? ArchiveError.passwordRequired(format: .zip)
                    : ArchiveError.passwordUnsupported(format: .zip)
            }
            let reason: String
            if case .wrongCRC(_) = error {
                reason = "wrongCRC"
            } else {
                reason = String(describing: error)
            }
            throw ArchiveError.invalidArchive(format: .zip, reason: reason)
        } catch let error as DataError {
            throw ArchiveError.invalidArchive(format: .zip, reason: archiveDataErrorReason(error))
        } catch {
            throw ArchiveError.invalidArchive(format: .zip, reason: String(describing: error))
        }
    }
}

internal struct SevenZipArchiveBackend: ArchiveBackend {
    let format: ArchiveFormat = .sevenZip

    func readEntries(from data: Data, password: String?) throws -> [ArchiveEntry] {
        do {
            return try SevenZipContainer.open(container: data).map { entry in
                if entry.info.isAnti {
                    throw ArchiveError.unsupportedEntryType(path: entry.info.name, type: "anti-file")
                }
                return ArchiveEntry(
                    path: entry.info.name,
                    kind: archiveEntryKind(entry.info.type),
                    data: entry.data
                )
            }
        } catch let error as SevenZipError {
            if case .encryptionNotSupported = error {
                throw password == nil
                    ? ArchiveError.passwordRequired(format: .sevenZip)
                    : ArchiveError.passwordUnsupported(format: .sevenZip)
            }
            throw ArchiveError.invalidArchive(format: .sevenZip, reason: String(describing: error))
        } catch let error as ArchiveError {
            throw error
        } catch let error as DataError {
            throw ArchiveError.invalidArchive(format: .sevenZip, reason: archiveDataErrorReason(error))
        } catch {
            throw ArchiveError.invalidArchive(format: .sevenZip, reason: String(describing: error))
        }
    }
}

internal func archiveDataErrorReason(_ error: DataError) -> String {
    if case .checksumMismatch(_) = error { return "checksumMismatch" }
    return String(describing: error)
}

/// SWCompression 4.8.6 exposes `ContainerEntryType`; only regular files/directories are safe to materialize.
internal func archiveEntryKind(_ type: ContainerEntryType) -> ArchiveEntry.Kind {
    switch type {
    case .regular, .contiguous:
        return .regular
    case .directory:
        return .directory
    case .symbolicLink:
        return .symbolicLink
    case .hardLink:
        return .hardLink
    case .blockSpecial:
        return .other("blockSpecial")
    case .characterSpecial:
        return .other("characterSpecial")
    case .fifo:
        return .other("fifo")
    case .socket:
        return .other("socket")
    case .unknown:
        return .other("unknown")
    }
}
