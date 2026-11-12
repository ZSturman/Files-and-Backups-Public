import Foundation

/// The contract every destination implements. Paths are always relative to
/// the connection's approved root; implementations map them onto their own
/// namespace and must never escape it.
public protocol StorageProvider: AnyObject, Sendable {
    var capabilities: ProviderCapabilities { get }

    /// Connects (or reconnects) and checks authorization for the root.
    func connect() async throws
    func disconnect() async

    func list(_ directory: RemotePath) async throws -> [RemoteItem]
    /// Returns nil when nothing exists at `path`.
    func item(at path: RemotePath) async throws -> RemoteItem?
    /// Fails with `.alreadyExists` when something is already there.
    func createDirectory(_ path: RemotePath) async throws
    /// Renames/moves within the connection. Never replaces an existing item;
    /// fails with `.alreadyExists` instead.
    func move(_ source: RemotePath, to destination: RemotePath) async throws
    /// Permanently deletes a file or (recursively) a folder.
    func delete(_ path: RemotePath) async throws
    /// nil when the server does not report capacity.
    func capacity() async throws -> StorageCapacity?
    func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data

    /// Creates or resumes the upload of one file into `request.directory`.
    func makeUploadSink(for request: UploadRequest) async throws -> any UploadSink
    /// Discards partial data left by a cancelled upload, identified by the
    /// token its sink reported. Must ignore tokens it did not issue.
    func discardUpload(resumeToken: String) async
}

/// One file upload, including any state persisted from an earlier attempt.
public struct UploadRequest: Sendable {
    public var itemID: UUID
    public var directory: RemotePath
    public var preferredName: String
    public var size: Int64
    public var sha256: String?
    /// Provider-specific token from an earlier attempt (temp path or session ID).
    public var resumeToken: String?
    public var committedOffset: Int64
    /// Final path chosen just before a commit that may not have been recorded.
    public var commitCandidate: RemotePath?
    /// Reads source bytes so a sink can confirm a partial upload still matches.
    public var readSource: @Sendable (_ offset: Int64, _ length: Int) throws -> Data

    public init(
        itemID: UUID, directory: RemotePath, preferredName: String, size: Int64, sha256: String?,
        resumeToken: String? = nil, committedOffset: Int64 = 0, commitCandidate: RemotePath? = nil,
        readSource: @escaping @Sendable (_ offset: Int64, _ length: Int) throws -> Data
    ) {
        self.itemID = itemID
        self.directory = directory
        self.preferredName = preferredName
        self.size = size
        self.sha256 = sha256
        self.resumeToken = resumeToken
        self.committedOffset = committedOffset
        self.commitCandidate = commitCandidate
        self.readSource = readSource
    }
}

public struct UploadResult: Codable, Hashable, Sendable {
    public var finalPath: RemotePath
    public var verification: VerificationLevel

    public init(finalPath: RemotePath, verification: VerificationLevel) {
        self.finalPath = finalPath
        self.verification = verification
    }
}

public enum UploadSinkState: Sendable, Equatable {
    /// Continue sending from this offset (0 means from the beginning).
    case upload(fromOffset: Int64, resumed: Bool)
    /// An earlier attempt already committed this file.
    case alreadyCommitted(UploadResult)
}

public protocol UploadSink: Sendable {
    var state: UploadSinkState { get }
    /// Token to persist so a later attempt can resume or recover this upload.
    var resumeToken: String { get }
    func append(_ data: Data, at offset: Int64) async throws
    /// Verifies the received bytes and publishes them under a non-colliding
    /// name. `willCommit` is called with the chosen path before publication.
    func finish(verifyContents: Bool, willCommit: @escaping @Sendable (RemotePath) async -> Void) async throws -> UploadResult
    /// Removes any partial data belonging to this upload.
    func abort() async
    /// True for protocols without offset writes (WebDAV): the queue then
    /// calls `uploadWholeFile` instead of `append`.
    var uploadsWholeFile: Bool { get }
    func uploadWholeFile(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

extension UploadSink {
    public var uploadsWholeFile: Bool { false }
    public func uploadWholeFile(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        throw FileCoreError.unsupported("whole-file upload")
    }
}

/// Providers that expose plain file primitives (SMB, local folders, fakes).
/// They share one temp-file upload implementation.
public protocol ByteStorageProvider: StorageProvider {
    /// Writes `data` at `offset`. Offset 0 creates the file exclusively and
    /// fails with `.alreadyExists` if it exists; other offsets truncate the
    /// existing file to `offset` first.
    func writeChunk(_ data: Data, to path: RemotePath, at offset: Int64) async throws
}

extension ByteStorageProvider {
    public func makeUploadSink(for request: UploadRequest) async throws -> any UploadSink {
        try await TempFileUploadSink.make(provider: self, request: request)
    }

    public func discardUpload(resumeToken: String) async {
        // Only ever delete this app's own temp files.
        guard let path = try? RemotePath(resumeToken), path.name.hasPrefix(TempFileUploadSink.tempPrefix) else { return }
        try? await delete(path)
    }
}

public enum CollisionNaming {
    /// "Report.pdf" → "Report (2).pdf", "Archive.tar.gz" → "Archive (2).tar.gz",
    /// "Folder" → "Folder (2)". Dotfiles keep their leading dot.
    public static func candidate(for name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz"]
        var base = name
        var ext = ""
        if let compound = compoundExtensions.first(where: { name.lowercased().hasSuffix($0) && name.count > $0.count }) {
            base = String(name.dropLast(compound.count))
            ext = String(name.suffix(compound.count))
        } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[dot...])
        }
        return "\(base) (\(attempt))\(ext)"
    }

    /// Finds the first name in `directory` not currently used.
    public static func firstAvailable(
        _ name: String, in directory: RemotePath, provider: any StorageProvider, maxAttempts: Int = 999
    ) async throws -> RemotePath {
        for attempt in 1...maxAttempts {
            let path = try directory.appending(candidate(for: name, attempt: attempt))
            if try await provider.item(at: path) == nil { return path }
        }
        throw FileCoreError.alreadyExists(try directory.appending(name))
    }
}
