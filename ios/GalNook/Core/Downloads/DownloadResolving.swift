import Foundation

/// Turns a resource page or share link into a downloadable URL.
/// Implementations can perform authentication or resolve expiring net-disk URLs.
public protocol DownloadResolving: Sendable {
    func resolve(_ resource: GameResource) async throws -> ResolvedDownload
}

public struct DirectDownloadResolver: DownloadResolving {
    public init() {}

    public func resolve(_ resource: GameResource) async throws -> ResolvedDownload {
        guard let url = resource.directURL else {
            throw DownloadError.missingDirectURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedURL(url)
        }

        let urlName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let proposedName = resource.fileName?.isEmpty == false
            ? resource.fileName!
            : (urlName.isEmpty ? resource.title : urlName)
        return ResolvedDownload(
            url: url,
            fileName: DownloadFilename.sanitize(proposedName),
            fileSize: resource.fileSize,
            headers: resource.downloadHeaders
        )
    }
}
