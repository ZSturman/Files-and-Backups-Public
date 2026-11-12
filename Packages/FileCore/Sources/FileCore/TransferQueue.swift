import Foundation

/// Jobs handed over by the Share Extension: one JSON file per job in an
/// inbox folder of the shared container. The app enqueues and removes them.
public struct TransferInbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func deposit(_ job: TransferJob) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.fileCore.encode(job).write(to: directory.appendingPathComponent("\(job.id.uuidString).json"), options: .atomic)
    }

    /// Returns pending jobs and removes their files.
    public func collect() -> [TransferJob] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return try? JSONDecoder.fileCore.decode(TransferJob.self, from: Data(contentsOf: url))
        }
    }
}

/// Persists transfer jobs as one JSON document, written atomically.
public final class TransferStore: @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [TransferJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.fileCore.decode([TransferJob].self, from: data)) ?? []
    }

    public func save(_ jobs: [TransferJob]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.fileCore.encode(jobs)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}

extension JSONEncoder {
    static var fileCore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var fileCore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Serial, persistent upload queue. One job and one file run at a time so a
/// phone on a weak link is not saturated and every state change is durable.
///
/// Interruption model: progress is persisted after each chunk. When the app is
/// suspended or killed, in-flight items become `paused`; they continue on the
/// next launch through the provider's resume rules or restart safely.
public actor TransferQueue {
    public typealias ProviderFactory = @Sendable (UUID) async throws -> any StorageProvider

    public private(set) var jobs: [TransferJob]
    private let store: TransferStore
    private let staging: StagingArea
    private let providerFactory: ProviderFactory
    private var runner: Task<Void, Never>?
    private var currentJobID: UUID?
    private var currentTask: Task<Void, any Error>?
    private var observers: [UUID: AsyncStream<[TransferJob]>.Continuation] = [:]
    private var lastPersist = Date.distantPast

    public var chunkSize = 4 << 20
    public var retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
    /// Test hook invoked after each chunk is written.
    public var afterChunk: (@Sendable (UUID, Int64) async -> Void)?

    public init(store: TransferStore, staging: StagingArea, providerFactory: @escaping ProviderFactory) {
        self.store = store
        self.staging = staging
        self.providerFactory = providerFactory
        var loaded = store.load()
        // Anything in flight when the process ended was interrupted.
        for jobIndex in loaded.indices {
            var interrupted = false
            for itemIndex in loaded[jobIndex].items.indices where [.transferring, .verifying].contains(loaded[jobIndex].items[itemIndex].state) {
                loaded[jobIndex].items[itemIndex].state = .paused
                interrupted = true
            }
            if interrupted, loaded[jobIndex].pauseReason == nil {
                loaded[jobIndex].pauseReason = .system
            }
        }
        self.jobs = loaded
    }

    public func setChunkSize(_ size: Int) { chunkSize = size }
    public func setRetryDelays(_ delays: [Duration]) { retryDelays = delays }
    public func setAfterChunk(_ hook: (@Sendable (UUID, Int64) async -> Void)?) { afterChunk = hook }

    // MARK: Observation

    public func updates() -> AsyncStream<[TransferJob]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[TransferJob]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(jobs)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publish() {
        for continuation in observers.values { continuation.yield(jobs) }
    }

    private func persist(force: Bool = true) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) >= 1 else { publish(); return }
        lastPersist = now
        try? store.save(jobs)
        publish()
    }

    // MARK: Requests

    /// Adds a job. Re-adding a job with the same ID is ignored.
    public func enqueue(_ job: TransferJob) {
        guard !jobs.contains(where: { $0.id == job.id }) else { return }
        jobs.append(job)
        persist()
        kick()
    }

    public func pause(_ jobID: UUID) {
        guard let index = index(of: jobID), !jobs[index].cancelled else { return }
        jobs[index].pauseReason = .user
        persist()
        if currentJobID == jobID { currentTask?.cancel() }
    }

    public func resume(_ jobID: UUID) {
        guard let index = index(of: jobID), !jobs[index].cancelled else { return }
        jobs[index].pauseReason = nil
        persist()
        kick()
    }

    /// Failed items are queued again; completed items are never re-sent.
    public func retry(_ jobID: UUID) {
        guard let index = index(of: jobID), !jobs[index].cancelled else { return }
        jobs[index].failureReason = nil
        jobs[index].pauseReason = nil
        for itemIndex in jobs[index].items.indices where jobs[index].items[itemIndex].state == .failed {
            jobs[index].items[itemIndex].state = .queued
            jobs[index].items[itemIndex].lastError = nil
        }
        persist()
        kick()
    }

    /// Stops the job, removes its partial uploads and staged copies. Files
    /// already published at the destination are left in place.
    public func cancel(_ jobID: UUID) async {
        guard let index = index(of: jobID), !jobs[index].cancelled else { return }
        jobs[index].cancelled = true
        let tokens = jobs[index].items.filter { $0.state != .complete }.compactMap(\.resumeToken)
        for itemIndex in jobs[index].items.indices where jobs[index].items[itemIndex].state != .complete {
            jobs[index].items[itemIndex].state = .cancelled
        }
        persist()
        if currentJobID == jobID {
            currentTask?.cancel()
            _ = await currentTask?.result
        }
        let connectionID = jobs[index].connectionID
        if !tokens.isEmpty, let provider = try? await providerFactory(connectionID) {
            if (try? await provider.connect()) != nil {
                for token in tokens { await provider.discardUpload(resumeToken: token) }
            }
            await provider.disconnect()
        }
        staging.removeJob(jobID)
    }

    /// Removes finished jobs (complete or cancelled) from the list.
    public func removeFinished() {
        let removed = jobs.filter { $0.state == .complete || $0.state == .cancelled }
        jobs.removeAll { $0.state == .complete || $0.state == .cancelled }
        for job in removed { staging.removeJob(job.id) }
        persist()
    }

    /// Called when the app is about to be suspended: stop at a durable point.
    public func suspendForBackground() async {
        guard let jobID = currentJobID, let index = index(of: jobID) else { return }
        if jobs[index].pauseReason == nil { jobs[index].pauseReason = .system }
        persist()
        currentTask?.cancel()
        _ = await currentTask?.result
    }

    /// Called when the app becomes active: continue only transfers the user
    /// already requested that stopped for system or network reasons.
    public func resumeAfterInterruption() {
        for index in jobs.indices where jobs[index].pauseReason == .system || jobs[index].pauseReason == .connectionLost {
            jobs[index].pauseReason = nil
        }
        persist()
        kick()
    }

    public func start() { kick() }

    /// Waits until no runnable work remains (tests and command-line use).
    public func waitUntilIdle() async {
        while let runner {
            await runner.value
        }
    }

    public var isRunning: Bool { runner != nil }

    // MARK: Engine

    private func index(of jobID: UUID) -> Int? { jobs.firstIndex { $0.id == jobID } }

    private func kick() {
        guard runner == nil else { return }
        runner = Task { await self.runLoop() }
    }

    private func runLoop() async {
        while let job = jobs.first(where: \.isRunnable) {
            currentJobID = job.id
            let task = Task { try await self.runJob(job.id) }
            currentTask = task
            _ = await task.result
            currentTask = nil
            currentJobID = nil
            finishIfDone(job.id)
            if Task.isCancelled { break }
        }
        runner = nil
    }

    private func finishIfDone(_ jobID: UUID) {
        guard let index = index(of: jobID) else { return }
        if jobs[index].state == .complete { staging.removeJob(jobID) }
        persist()
    }

    private func runJob(_ jobID: UUID) async throws {
        var attempt = 0
        while true {
            guard let index = index(of: jobID), jobs[index].isRunnable else { return }
            do {
                let provider = try await providerFactory(jobs[index].connectionID)
                defer { Task { await provider.disconnect() } }
                try await provider.connect()
                try await prepareFolders(jobID, provider: provider)
                try await uploadPendingItems(jobID, provider: provider)
                return
            } catch is CancellationError {
                markInFlightPaused(jobID)
                return
            } catch FileCoreError.cancelled {
                markInFlightPaused(jobID)
                return
            } catch let error as FileCoreError where error.isTransient {
                markInFlightPaused(jobID)
                guard attempt < retryDelays.count else {
                    if let index = self.index(of: jobID) { jobs[index].pauseReason = .connectionLost }
                    persist()
                    return
                }
                let delay = retryDelays[attempt]
                attempt += 1
                persist()
                do { try await Task.sleep(for: delay) } catch { return }
            } catch {
                markInFlightPaused(jobID)
                if let index = self.index(of: jobID) {
                    jobs[index].failureReason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
                persist()
                return
            }
        }
    }

    private func markInFlightPaused(_ jobID: UUID) {
        guard let index = index(of: jobID) else { return }
        for itemIndex in jobs[index].items.indices where [.transferring, .verifying].contains(jobs[index].items[itemIndex].state) {
            jobs[index].items[itemIndex].state = jobs[index].cancelled ? .cancelled : .paused
        }
        persist()
    }

    private func prepareFolders(_ jobID: UUID, provider: any StorageProvider) async throws {
        guard let index = index(of: jobID) else { return }
        let job = jobs[index]
        try await requireDirectory(job.destination, provider: provider)
        if let rootName = job.rootFolderName {
            if let resolved = job.resolvedRootName {
                try await ensureDirectory(try job.destination.appending(resolved), provider: provider)
            } else {
                // Keep-both for the imported folder itself: never merge into an
                // existing folder of the same name on the first attempt.
                var created = false
                for nameAttempt in 1...999 {
                    let candidate = CollisionNaming.candidate(for: rootName, attempt: nameAttempt)
                    let path = try job.destination.appending(candidate)
                    if try await provider.item(at: path) != nil { continue }
                    jobs[index].resolvedRootName = candidate
                    persist()
                    do {
                        try await provider.createDirectory(path)
                        created = true
                        break
                    } catch FileCoreError.alreadyExists {
                        continue
                    }
                }
                guard created else { throw FileCoreError.alreadyExists(try job.destination.appending(rootName)) }
            }
        }
        let targetRoot = try jobs[index].targetRoot()
        for directory in job.directories.sorted() {
            let path = targetRoot.appending(try RemotePath(directory))
            try await ensureDirectory(path, provider: provider)
        }
    }

    private func requireDirectory(_ path: RemotePath, provider: any StorageProvider) async throws {
        if path.isRoot { return }
        guard let existing = try await provider.item(at: path) else { throw FileCoreError.notFound(path) }
        guard existing.isDirectory else { throw FileCoreError.notADirectory(path) }
    }

    private func ensureDirectory(_ path: RemotePath, provider: any StorageProvider) async throws {
        if path.isRoot { return }
        if let existing = try await provider.item(at: path) {
            guard existing.isDirectory else { throw FileCoreError.notADirectory(path) }
            return
        }
        if let parent = path.parent { try await ensureDirectory(parent, provider: provider) }
        do {
            try await provider.createDirectory(path)
        } catch FileCoreError.alreadyExists {
            guard let existing = try await provider.item(at: path), existing.isDirectory else { throw FileCoreError.notADirectory(path) }
        }
    }

    private func uploadPendingItems(_ jobID: UUID, provider: any StorageProvider) async throws {
        guard let jobIndex = index(of: jobID) else { return }
        let itemIDs = jobs[jobIndex].items.filter { !$0.state.isFinished && $0.state != .failed }.map(\.id)
        for itemID in itemIDs {
            try Task.checkCancellation()
            guard let jobIndex = index(of: jobID), jobs[jobIndex].isRunnable else { return }
            do {
                try await uploadItem(jobID: jobID, itemID: itemID, provider: provider)
            } catch let error as FileCoreError {
                switch error {
                case .cancelled, .unreachable, .protocolError, .authenticationFailed, .insufficientSpace, .missingCredential:
                    // Connection-wide problems stop the job rather than
                    // failing every remaining file the same way.
                    if case .insufficientSpace = error { setItemFailed(jobID, itemID, error) }
                    if case .authenticationFailed = error { setItemFailed(jobID, itemID, error) }
                    throw error
                default:
                    setItemFailed(jobID, itemID, error)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                setItemFailed(jobID, itemID, error)
            }
        }
    }

    private func setItemFailed(_ jobID: UUID, _ itemID: UUID, _ error: any Error) {
        mutateItem(jobID, itemID) {
            $0.state = .failed
            $0.lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        persist()
    }

    private func mutateItem(_ jobID: UUID, _ itemID: UUID, _ body: (inout TransferItem) -> Void) {
        guard let jobIndex = index(of: jobID),
              let itemIndex = jobs[jobIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        body(&jobs[jobIndex].items[itemIndex])
    }

    private func item(_ jobID: UUID, _ itemID: UUID) -> (TransferJob, TransferItem)? {
        guard let job = jobs.first(where: { $0.id == jobID }), let item = job.items.first(where: { $0.id == itemID }) else { return nil }
        return (job, item)
    }

    private func sourceURL(for item: TransferItem) throws -> URL {
        switch item.source {
        case .staged(let relative):
            return staging.url(forStaged: relative)
        case .reference(let path, let bookmark, let modified):
            var url = URL(fileURLWithPath: path)
            if let bookmark {
                var stale = false
                #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
                #else
                let options: URL.BookmarkResolutionOptions = []
                #endif
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale) {
                    url = resolved
                }
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values?.fileSize else { throw FileCoreError.sourceChanged("\(item.relativePath) is no longer available") }
            if Int64(size) != item.size || (modified != nil && values?.contentModificationDate != modified) {
                throw FileCoreError.sourceChanged("\(item.relativePath) was modified")
            }
            return url
        }
    }

    private func uploadItem(jobID: UUID, itemID: UUID, provider: any StorageProvider) async throws {
        guard let (job, item) = item(jobID, itemID) else { return }
        let components = item.manifestComponents
        guard let name = components.last else { throw FileCoreError.invalidPath(item.relativePath) }
        let directory = try job.targetRoot().appending(try RemotePath(components: Array(components.dropLast())))

        let url = try sourceURL(for: item)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw FileCoreError.sourceChanged("\(item.relativePath) cannot be read")
        }
        defer { try? handle.close() }
        let reader = SourceReader(handle: handle)

        var sha256 = item.sha256
        if sha256 == nil, job.verifyContents {
            sha256 = try SHA256Stream.hex(ofFileAt: url)
            mutateItem(jobID, itemID) { $0.sha256 = sha256 }
        }

        mutateItem(jobID, itemID) {
            $0.state = .transferring
            $0.attempts += 1
            $0.lastError = nil
        }
        persist()

        let request = UploadRequest(
            itemID: item.id, directory: directory, preferredName: name, size: item.size, sha256: sha256,
            resumeToken: item.resumeToken, committedOffset: item.bytesCommitted, commitCandidate: item.commitCandidate,
            readSource: { offset, length in try reader.read(offset: offset, length: length) }
        )
        let sink = try await provider.makeUploadSink(for: request)
        mutateItem(jobID, itemID) { $0.resumeToken = sink.resumeToken }

        switch sink.state {
        case .alreadyCommitted(var result):
            if job.verifyContents, let sha256 {
                try await verifyByReadBack(result.finalPath, size: item.size, sha256: sha256, provider: provider)
                result.verification = .sha256Readback
            }
            complete(jobID, itemID, result)
            return
        case .upload where sink.uploadsWholeFile:
            mutateItem(jobID, itemID) {
                $0.bytesCommitted = 0
                $0.resumedFromOffset = nil
            }
            persist()
            try await sink.uploadWholeFile(url) { [weak self] sent in
                Task { await self?.reportProgress(jobID, itemID, sent) }
            }
        case .upload(let fromOffset, let resumed):
            mutateItem(jobID, itemID) {
                $0.bytesCommitted = fromOffset
                $0.resumedFromOffset = resumed ? fromOffset : nil
            }
            persist()
            var offset = fromOffset
            var mustCreate = fromOffset == 0
            while mustCreate || offset < item.size {
                try Task.checkCancellation()
                let length = Int(min(Int64(chunkSize), item.size - offset))
                let data = try reader.read(offset: offset, length: length)
                guard data.count == length else { throw FileCoreError.sourceChanged("\(item.relativePath) became shorter") }
                try await sink.append(data, at: offset)
                offset += Int64(data.count)
                mustCreate = false
                mutateItem(jobID, itemID) { $0.bytesCommitted = offset }
                persist(force: false)
                if let afterChunk { await afterChunk(itemID, offset) }
            }
        }

        try Task.checkCancellation()
        mutateItem(jobID, itemID) { $0.state = .verifying }
        persist()
        let result = try await sink.finish(verifyContents: job.verifyContents) { [weak self] candidate in
            await self?.recordCandidate(jobID, itemID, candidate)
        }
        complete(jobID, itemID, result)
    }

    private func reportProgress(_ jobID: UUID, _ itemID: UUID, _ sent: Int64) {
        mutateItem(jobID, itemID) { if $0.state == .transferring { $0.bytesCommitted = sent } }
        persist(force: false)
    }

    private func recordCandidate(_ jobID: UUID, _ itemID: UUID, _ candidate: RemotePath) {
        mutateItem(jobID, itemID) { $0.commitCandidate = candidate }
        persist()
    }

    private func complete(_ jobID: UUID, _ itemID: UUID, _ result: UploadResult) {
        mutateItem(jobID, itemID) {
            $0.state = .complete
            $0.finalPath = result.finalPath
            $0.verification = result.verification
            $0.bytesCommitted = $0.size
            $0.lastError = nil
        }
        persist()
    }

    private func verifyByReadBack(_ path: RemotePath, size: Int64, sha256: String, provider: any StorageProvider) async throws {
        let hasher = SHA256Stream()
        var offset: Int64 = 0
        while offset < size {
            let data = try await provider.read(path, offset: offset, length: Int(min(Int64(chunkSize), size - offset)))
            guard !data.isEmpty else { break }
            hasher.update(data)
            offset += Int64(data.count)
        }
        guard offset == size, hasher.finalizeHex() == sha256 else {
            throw FileCoreError.verificationFailed("\(path) does not match the source")
        }
    }
}

/// Random-access reads from a source file.
final class SourceReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func read(offset: Int64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        var data = Data()
        while data.count < length, let chunk = try handle.read(upToCount: length - data.count), !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }
}
