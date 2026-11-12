import Foundation

public enum TransferItemState: String, Codable, Sendable {
    case queued
    case transferring
    case paused
    case verifying
    case complete
    case failed
    case cancelled

    public var isFinished: Bool { self == .complete || self == .cancelled }
}

/// Where the bytes for an item come from.
public enum TransferSource: Codable, Hashable, Sendable {
    /// A copy the app owns inside its bounded staging area (relative path).
    /// Deleted after the job finishes or is cancelled.
    case staged(String)
    /// A file the user owns (Mac drag-and-drop); never deleted by the app.
    /// Size and modification date are rechecked before sending.
    case reference(path: String, bookmark: Data?, modified: Date?)
}

public struct TransferItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Path inside the job's manifest, e.g. "Trip/Day 1/IMG_0001.HEIC".
    public var relativePath: String
    public var source: TransferSource
    public var size: Int64
    public var sha256: String?
    public var state: TransferItemState
    public var bytesCommitted: Int64
    public var resumeToken: String?
    public var commitCandidate: RemotePath?
    public var finalPath: RemotePath?
    public var verification: VerificationLevel
    public var resumedFromOffset: Int64?
    public var attempts: Int
    public var lastError: String?

    public init(id: UUID = UUID(), relativePath: String, source: TransferSource, size: Int64, sha256: String?) {
        self.id = id
        self.relativePath = relativePath
        self.source = source
        self.size = size
        self.sha256 = sha256
        self.state = .queued
        self.bytesCommitted = 0
        self.verification = .none
        self.attempts = 0
    }

    /// Manifest path components (validated when the job is built).
    public var manifestComponents: [String] {
        relativePath.split(separator: "/").map(String.init)
    }
}

public enum TransferPauseReason: String, Codable, Sendable {
    case user
    /// App moved to background, quit, or was terminated. Resumes on reopen.
    case system
    /// Repeated network failures. Resumes on reopen or by request.
    case connectionLost
}

public enum TransferJobState: String, Sendable {
    case queued, transferring, paused, verifying, complete, failed, cancelled
}

public struct TransferJob: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var connectionName: String
    /// Destination folder chosen by the user (provider-relative).
    public var destination: RemotePath
    /// Name of the top-level imported folder, when a folder was imported.
    public var rootFolderName: String?
    /// The non-colliding folder name actually used for `rootFolderName`.
    public var resolvedRootName: String?
    /// All manifest folders (including empty ones), relative to the root folder.
    public var directories: [String]
    public var items: [TransferItem]
    public var verifyContents: Bool
    public var createdAt: Date
    public var pauseReason: TransferPauseReason?
    /// Set when the job cannot continue without a user decision (credentials,
    /// space, missing destination). Cleared by Retry.
    public var failureReason: String?
    public var cancelled: Bool

    public init(
        id: UUID = UUID(), connectionID: UUID, connectionName: String, destination: RemotePath,
        rootFolderName: String?, directories: [String], items: [TransferItem], verifyContents: Bool, createdAt: Date = Date()
    ) {
        self.id = id
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.destination = destination
        self.rootFolderName = rootFolderName
        self.directories = directories
        self.items = items
        self.verifyContents = verifyContents
        self.createdAt = createdAt
        self.cancelled = false
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    public var committedBytes: Int64 {
        items.reduce(0) { $0 + ($1.state == .complete ? $1.size : min($1.bytesCommitted, $1.size)) }
    }

    public var displayName: String {
        if let rootFolderName { return rootFolderName }
        if items.count == 1, let item = items.first { return item.relativePath }
        return "\(items.count) items"
    }

    public var state: TransferJobState {
        if cancelled { return .cancelled }
        if items.contains(where: { $0.state == .transferring }) { return .transferring }
        if items.contains(where: { $0.state == .verifying }) { return .verifying }
        if pauseReason != nil { return .paused }
        if failureReason != nil { return .failed }
        if items.allSatisfy({ $0.state == .complete || $0.state == .cancelled }) { return .complete }
        if items.contains(where: { $0.state == .queued || $0.state == .paused }) { return .queued }
        return .failed
    }

    /// True when the queue may pick this job up without user action.
    public var isRunnable: Bool {
        !cancelled && pauseReason == nil && failureReason == nil
            && items.contains(where: { $0.state == .queued || $0.state == .paused || $0.state == .transferring || $0.state == .verifying })
    }

    /// Weakest verification across completed items.
    public var verificationSummary: VerificationLevel? {
        let done = items.filter { $0.state == .complete }
        guard !done.isEmpty else { return nil }
        return done.map(\.verification).min()
    }

    /// The folder files are placed under (destination + resolved root).
    public func targetRoot() throws -> RemotePath {
        guard rootFolderName != nil else { return destination }
        guard let resolvedRootName else {
            throw FileCoreError.invalidConfiguration("the destination folder has not been created yet")
        }
        return try destination.appending(resolvedRootName)
    }
}
