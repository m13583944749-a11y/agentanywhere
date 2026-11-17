import Combine
import Foundation

@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var tasks: [DownloadTask]

    public private(set) var settings: DownloadSettings

    private let session: URLSession
    private let store: JSONStore<[DownloadTask]>
    private let downloadsDirectory: URL
    private let partialDirectory: URL
    private let directResolver = DirectDownloadResolver()
    private var resolvers: [PanProvider: any DownloadResolving] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var persistenceDirty = false

    public init(
        session: URLSession = .shared,
        settings: DownloadSettings = DownloadSettings(),
        downloadsDirectory: URL = AppFileLocations.downloads,
        partialDirectory: URL = AppFileLocations.applicationSupport
            .appendingPathComponent("PartialDownloads", isDirectory: true),
        store: JSONStore<[DownloadTask]>? = nil
    ) {
        self.session = session
        self.settings = Self.normalized(settings)
        self.downloadsDirectory = downloadsDirectory
        self.partialDirectory = partialDirectory
        self.store = store ?? JSONStore(
            fileURL: AppFileLocations.applicationSupport.appendingPathComponent("download-tasks.json"),
            defaultValue: []
        )
        self.tasks = []
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
    }

    deinit {
        operations.values.forEach { $0.cancel() }
        persistenceTask?.cancel()
    }

    /// Restores task history. Downloads interrupted by process termination become
    /// paused when a partial file exists, and queued otherwise.
    public func load() async {
        let restored = await store.load()
        let existingIDs = Set(tasks.map(\.id))
        let normalized = restored.filter { !existingIDs.contains($0.id) }.map { task -> DownloadTask in
            var task = task
            task.bytesPerSecond = 0
            guard task.state != .completed else { return task }
            let partialSize = savedDownloadedBytes(for: task.id)
            task.downloadedBytes = partialSize
            switch task.state {
            case .resolving, .waiting, .downloading, .extracting:
                task.state = partialSize > 0 ? .paused : .waiting
            case .paused, .failed:
                break
            case .completed, .cancelled:
                break
            }
            if task.state != .failed { task.errorMessage = nil }
            return task
        }
        tasks.append(contentsOf: normalized)
        schedulePersistence()
        startAvailableDownloads()
    }

    /// Registers or replaces the resolver for a resource provider. Resolution is
    /// repeated for retries, allowing resolvers to refresh short-lived URLs.
    public func registerResolver(_ resolver: any DownloadResolving, for provider: PanProvider) {
        resolvers[provider] = resolver
    }

    public func updateSettings(_ settings: DownloadSettings) {
        self.settings = Self.normalized(settings)
        startAvailableDownloads()
    }

    @discardableResult
    public func enqueue(_ resource: GameResource) -> UUID {
        let proposedName = resource.fileName ?? resource.title
        let task = DownloadTask(
            resource: resource,
            state: .waiting,
            fileName: DownloadFilename.sanitize(proposedName),
            totalBytes: resource.fileSize ?? 0
        )
        tasks.append(task)
        schedulePersistence()
        startAvailableDownloads()
        return task.id
    }

    public func task(id: UUID) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    public func fileURL(for id: UUID) -> URL? {
        guard let task = task(id: id), task.state == .completed,
              let relativePath = task.relativePath else { return nil }
        return downloadsDirectory.appendingPathComponent(relativePath, isDirectory: false)
    }

    public func partialFileURL(for id: UUID) -> URL {
        DownloadFileSupport.partialURL(for: id, directory: partialDirectory)
    }

    /// Pauses network activity but deliberately keeps the .partial file and its
    /// validators so a later resume can issue a Range request.
    public func pause(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].state.isActive else { return }
        synchronizePartialBytes(at: index)
        tasks[index].state = .paused
        tasks[index].bytesPerSecond = 0
        tasks[index].errorMessage = nil
        tasks[index].updatedAt = .now
        operations[id]?.cancel()
        schedulePersistence()
    }

    public func resume(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].state == .paused else { return }
        synchronizePartialBytes(at: index)
        tasks[index].state = .waiting
        tasks[index].errorMessage = nil
        tasks[index].updatedAt = .now
        schedulePersistence()
        startAvailableDownloads()
    }

    /// Cancellation discards resumable state. Failed downloads, in contrast,
    /// retain their partial file for retry().
    public func cancel(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].state != .completed else { return }
        tasks[index].state = .cancelled
        tasks[index].downloadedBytes = 0
        tasks[index].bytesPerSecond = 0
        tasks[index].errorMessage = nil
        tasks[index].updatedAt = .now
        if let operation = operations[id] {
            operation.cancel()
        } else {
            DownloadFileSupport.removePartialAndMetadata(for: id, directory: partialDirectory)
            startAvailableDownloads()
        }
        schedulePersistence()
    }

    public func retry(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].state == .failed || tasks[index].state == .cancelled else { return }
        tasks[index].state = .waiting
        tasks[index].retryCount = 0
        tasks[index].errorMessage = nil
        tasks[index].relativePath = nil
        tasks[index].updatedAt = .now
        schedulePersistence()
        startAvailableDownloads()
    }

    /// Removes a task and every file it owns. Active work is cancelled first;
    /// completed downloads are deleted from the Downloads directory as well.
    public func remove(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        operations[id]?.cancel()
        if task.state == .completed, let relativePath = task.relativePath {
            let url = downloadsDirectory.appendingPathComponent(relativePath, isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
        tasks.remove(at: index)
        DownloadFileSupport.removePartialAndMetadata(for: id, directory: partialDirectory)
        if operations[id] == nil { startAvailableDownloads() }
        schedulePersistence()
    }

    /// Clears terminal tasks and their files, leaving waiting, active and paused
    /// tasks untouched.
    public func clearFinished() {
        let finishedIDs = tasks.filter {
            $0.state == .completed || $0.state == .failed || $0.state == .cancelled
        }.map(\.id)
        finishedIDs.forEach(remove)
    }

    public func saveImmediately() async throws {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceDirty = false
        try await store.save(tasks)
    }

    private func startAvailableDownloads() {
        let limit = settings.maximumConcurrent
        guard operations.count < limit else { return }
        let candidates = tasks
            .filter { ($0.state == .waiting || $0.state == .resolving) && operations[$0.id] == nil }
            .sorted { $0.createdAt < $1.createdAt }
        for candidate in candidates.prefix(limit - operations.count) {
            mutateTask(id: candidate.id, persist: false) { task in
                task.state = .resolving
                task.bytesPerSecond = 0
            }
            let id = candidate.id
            operations[id] = Task { [weak self] in
                guard let self else { return }
                await self.runOperation(id: id)
            }
        }
        schedulePersistence()
    }

    private func runOperation(id: UUID) async {
        defer {
            operations[id] = nil
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                if tasks[index].state == .cancelled {
                    DownloadFileSupport.removePartialAndMetadata(for: id, directory: partialDirectory)
                    tasks[index].downloadedBytes = 0
                }
            } else {
                // remove(id:) deletes the record before this cancelled operation
                // finishes; repeat idempotent partial cleanup after file handles close.
                DownloadFileSupport.removePartialAndMetadata(for: id, directory: partialDirectory)
            }
            schedulePersistence()
            startAvailableDownloads()
        }

        while true {
            guard let current = task(id: id),
                  current.state == .resolving || current.state == .waiting || current.state == .downloading else {
                return
            }

            do {
                mutateTask(id: id, persist: false) { task in
                    task.state = .resolving
                    task.errorMessage = nil
                }
                let resolved = try await resolve(current.resource)
                try Task.checkCancellation()
                guard task(id: id)?.state.isActive == true else { return }

                let partialURL = DownloadFileSupport.partialURL(for: id, directory: partialDirectory)
                let partialBytes = DownloadFileSupport.fileSize(partialURL)
                mutateTask(id: id, persist: false) { task in
                    task.state = .downloading
                    task.fileName = DownloadFilename.sanitize(resolved.fileName)
                    task.downloadedBytes = partialBytes
                    task.totalBytes = resolved.fileSize ?? task.totalBytes
                    task.bytesPerSecond = 0
                }

                let result = try await performDownload(resolved: resolved, id: id, partialURL: partialURL)
                try Task.checkCancellation()
                guard task(id: id)?.state == .downloading else { return }

                let fileName = DownloadFilename.sanitize(resolved.fileName)
                let destination = DownloadFilename.uniqueDestination(
                    fileName: fileName,
                    directory: downloadsDirectory
                )
                try FileManager.default.moveItem(at: partialURL, to: destination)
                try? FileManager.default.removeItem(
                    at: DownloadFileSupport.metadataURL(for: id, directory: partialDirectory)
                )
                mutateTask(id: id) { task in
                    task.state = .completed
                    task.fileName = destination.lastPathComponent
                    task.relativePath = destination.lastPathComponent
                    task.downloadedBytes = result.downloadedBytes
                    task.totalBytes = result.totalBytes > 0 ? result.totalBytes : result.downloadedBytes
                    task.errorMessage = nil
                }
                return
            } catch {
                guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
                if tasks[index].state == .paused {
                    synchronizePartialBytes(at: index)
                    return
                }
                if tasks[index].state == .cancelled { return }
                if error.isCancellationForDownload {
                    // pause() followed immediately by resume() can deliver the
                    // old operation's cancellation after state is waiting again.
                    // Never let that stale cancellation overwrite the new intent.
                    if tasks[index].state != .waiting {
                        tasks[index].state = .cancelled
                        tasks[index].downloadedBytes = 0
                        tasks[index].bytesPerSecond = 0
                        tasks[index].updatedAt = .now
                    }
                    return
                }

                synchronizePartialBytes(at: index)
                let automaticRetry = error.isRetryableForDownload
                    && tasks[index].retryCount < settings.maximumRetries
                if automaticRetry {
                    tasks[index].retryCount += 1
                    tasks[index].state = .waiting
                    tasks[index].bytesPerSecond = 0
                    tasks[index].errorMessage = "自动重试（\(tasks[index].retryCount)/\(settings.maximumRetries)）：\(error.localizedDescription)"
                    tasks[index].updatedAt = .now
                    schedulePersistence()
                    let delay = min(30, pow(2, Double(tasks[index].retryCount - 1)))
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard task(id: id)?.state.isActive == true else { return }
                    continue
                }

                tasks[index].state = .failed
                tasks[index].bytesPerSecond = 0
                tasks[index].errorMessage = error.localizedDescription
                tasks[index].updatedAt = .now
                schedulePersistence()
                return
            }
        }
    }

    private func resolve(_ resource: GameResource) async throws -> ResolvedDownload {
        if let resolver = resolvers[resource.provider] {
            return try await resolver.resolve(resource)
        }
        if resource.directURL != nil {
            return try await directResolver.resolve(resource)
        }
        throw DownloadError.noResolver(resource.provider)
    }

    private func performDownload(resolved: ResolvedDownload, id: UUID, partialURL: URL) async throws -> DownloadEngineResult {
        let metadataURL = DownloadFileSupport.metadataURL(for: id, directory: partialDirectory)
        if settings.connectionsPerFile > 1 {
            do {
                return try await SegmentedDownloadEngine(
                    session: session,
                    partialURL: partialURL,
                    metadataURL: metadataURL
                ).download(resolved: resolved, connections: settings.connectionsPerFile) { [weak self] item in
                    await self?.updateProgress(id: id, item: item)
                }
            } catch let error as SegmentedDownloadError {
                guard case .rangeNotSupported = error else { throw error }
                // The segmented engine removed incompatible resume state. Retry
                // the same resolved URL with the proven single-stream engine.
            }
        }
        return try await DirectDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: metadataURL
        ).download(resolved: resolved) { [weak self] item in
            await self?.updateProgress(id: id, item: item)
        }
    }

    private func savedDownloadedBytes(for id: UUID) -> Int64 {
        let partialURL = DownloadFileSupport.partialURL(for: id, directory: partialDirectory)
        if settings.connectionsPerFile > 1,
           let progress = SegmentedDownloadEngine(
            session: session,
            partialURL: partialURL,
            metadataURL: DownloadFileSupport.metadataURL(for: id, directory: partialDirectory)
           ).savedProgress() {
            return progress.downloadedBytes
        }
        return DownloadFileSupport.fileSize(partialURL)
    }

    private func updateProgress(id: UUID, item: DownloadProgress) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].state == .downloading else { return }
        tasks[index].downloadedBytes = max(0, item.downloadedBytes)
        tasks[index].totalBytes = max(0, item.totalBytes)
        tasks[index].bytesPerSecond = max(0, item.bytesPerSecond)
        tasks[index].updatedAt = .now
        schedulePersistence()
    }

    private func synchronizePartialBytes(at index: Int) {
        let id = tasks[index].id
        tasks[index].downloadedBytes = savedDownloadedBytes(for: id)
    }

    private func mutateTask(
        id: UUID,
        persist: Bool = true,
        _ mutation: (inout DownloadTask) -> Void
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&tasks[index])
        tasks[index].updatedAt = .now
        if persist { schedulePersistence() }
    }

    private func schedulePersistence() {
        persistenceDirty = true
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await self.flushPersistence()
        }
    }

    private func flushPersistence() async {
        persistenceTask = nil
        guard persistenceDirty else { return }
        persistenceDirty = false
        try? await store.save(tasks)
        if persistenceDirty { schedulePersistence() }
    }

    private static func normalized(_ settings: DownloadSettings) -> DownloadSettings {
        DownloadSettings(
            maximumConcurrent: settings.maximumConcurrent,
            connectionsPerFile: settings.connectionsPerFile,
            maximumRetries: settings.maximumRetries,
            allowsCellular: settings.allowsCellular,
            automaticallyExtract: settings.automaticallyExtract,
            deleteArchiveAfterExtraction: settings.deleteArchiveAfterExtraction
        )
    }
}

private extension Error {
    var isCancellationForDownload: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }

    var isRetryableForDownload: Bool {
        if let error = self as? DownloadError { return error.isRetryable }
        if let error = self as? URLError { return error.code != .cancelled && error.code != .badURL }
        return !(self is CancellationError)
    }
}
