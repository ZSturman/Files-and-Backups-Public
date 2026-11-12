import Foundation

public enum FileCoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidPath(String)
    case invalidConfiguration(String)
    case missingCredential
    case authenticationFailed
    case unreachable(String)
    case notFound(RemotePath)
    case alreadyExists(RemotePath)
    case notADirectory(RemotePath)
    case permissionDenied(String)
    case insufficientSpace
    case stagingQuotaExceeded(needed: Int64, available: Int64)
    case unsupported(String)
    case verificationFailed(String)
    case sourceChanged(String)
    case cancelled
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let reason): return "Invalid path: \(reason)."
        case .invalidConfiguration(let reason): return "Invalid connection settings: \(reason)."
        case .missingCredential: return "No saved credential for this connection."
        case .authenticationFailed: return "The server rejected the user name or password."
        case .unreachable(let detail): return "The server could not be reached (\(detail))."
        case .notFound(let path): return "\(path) was not found."
        case .alreadyExists(let path): return "\(path) already exists."
        case .notADirectory(let path): return "\(path) is not a folder."
        case .permissionDenied(let detail): return "Permission denied: \(detail)."
        case .insufficientSpace: return "The destination is out of space or quota."
        case .stagingQuotaExceeded(let needed, let available):
            return "Importing needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of transfer storage but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        case .unsupported(let what): return "Not supported by this connection: \(what)."
        case .verificationFailed(let detail): return "Verification failed: \(detail)."
        case .sourceChanged(let detail): return "The source changed after it was queued: \(detail)."
        case .cancelled: return "Cancelled."
        case .protocolError(let detail): return "Server error: \(detail)."
        }
    }

    /// Errors worth retrying automatically after reconnecting. Everything else
    /// needs a user decision (credentials, permissions, space, conflicts).
    public var isTransient: Bool {
        switch self {
        case .unreachable, .protocolError: return true
        default: return false
        }
    }
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case smb
    case homeServices
    case localFolder
    case webDAV
    case sftp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smb: return "SMB File Share"
        case .homeServices: return "Home Services"
        case .localFolder: return "Folder or Disk on This Mac"
        case .webDAV: return "WebDAV (HTTPS)"
        case .sftp: return "SFTP"
        }
    }

    /// Planned providers are visible in setup but cannot be saved until their
    /// adapters pass fixture and device checks.
    public var isAvailable: Bool {
        switch self {
        case .smb, .homeServices, .localFolder, .webDAV, .sftp: return true
        }
    }
}

/// A saved destination. Secrets are never part of the profile; they live in a
/// `CredentialStore` keyed by `id`.
public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ProviderKind
    public var name: String
    /// SMB/SFTP host name or IP (LAN, .local, or Tailscale address/MagicDNS).
    public var host: String
    public var port: Int?
    /// SMB share name.
    public var share: String
    /// Folder inside the share/provider that bounds this connection.
    public var rootPath: String
    public var username: String
    public var domain: String
    /// Home Services/WebDAV base URL.
    public var baseURL: String
    /// Require SMB3 encryption; connecting fails rather than downgrading.
    public var requireEncryption: Bool
    /// Mac local folder security-scoped bookmark.
    public var bookmark: Data?
    /// SFTP: OpenSSH-format host key recorded at setup and required afterwards.
    public var pinnedHostKey: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), kind: ProviderKind, name: String, host: String = "", port: Int? = nil,
        share: String = "", rootPath: String = "", username: String = "", domain: String = "",
        baseURL: String = "", requireEncryption: Bool = false, bookmark: Data? = nil, pinnedHostKey: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.share = share
        self.rootPath = rootPath
        self.username = username
        self.domain = domain
        self.baseURL = baseURL
        self.requireEncryption = requireEncryption
        self.bookmark = bookmark
        self.pinnedHostKey = pinnedHostKey
        self.createdAt = createdAt
    }

    public func validatedRoot() throws -> RemotePath {
        try RemotePath(rootPath)
    }

    /// A short non-secret description for lists; never includes credentials.
    public var summary: String {
        switch kind {
        case .smb:
            let portPart = port.map { ":\($0)" } ?? ""
            let rootPart = rootPath.isEmpty ? "" : "/" + rootPath
            return "smb://\(host)\(portPart)/\(share)\(rootPart)"
        case .homeServices: return rootPath.isEmpty ? baseURL : "\(baseURL) › \(rootPath)"
        case .webDAV: return rootPath.isEmpty ? baseURL : "\(baseURL) › \(rootPath)"
        case .sftp: return "sftp://\(username)@\(host)\(port.map { ":\($0)" } ?? "")\(rootPath.hasPrefix("/") ? "" : "/")\(rootPath)"
        case .localFolder: return rootPath.isEmpty ? "Selected folder" : rootPath
        }
    }
}

public struct RemoteItem: Identifiable, Hashable, Sendable {
    public var path: RemotePath
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?

    public var id: RemotePath { path }
    public var name: String { path.name }

    public init(path: RemotePath, isDirectory: Bool, size: Int64?, modified: Date?) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// Capacity is optional: generic endpoints may not report it, and the UI shows
/// "unknown" rather than zero.
public struct StorageCapacity: Hashable, Sendable {
    public var totalBytes: Int64
    public var availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// How strongly a completed upload was checked against its source.
public enum VerificationLevel: String, Codable, Sendable, Comparable {
    case none
    /// Destination size equals source size.
    case size
    /// Destination bytes were read back and hashed with SHA-256.
    case sha256Readback
    /// The server computed and returned a SHA-256 for the received bytes.
    case serverSHA256

    private var rank: Int {
        switch self {
        case .none: return 0
        case .size: return 1
        case .sha256Readback, .serverSHA256: return 2
        }
    }

    public static func < (lhs: VerificationLevel, rhs: VerificationLevel) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .none: return "Not verified"
        case .size: return "Size verified"
        case .sha256Readback: return "SHA-256 verified (read back)"
        case .serverSHA256: return "SHA-256 verified (server)"
        }
    }
}

public enum CapabilitySupport: Hashable, Sendable {
    case supported
    case unsupported(String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }
}

/// Honest per-connection capability report shown after Test Connection.
public struct ProviderCapabilities: Hashable, Sendable {
    public var browse: CapabilitySupport
    public var download: CapabilitySupport
    public var upload: CapabilitySupport
    public var createFolder: CapabilitySupport
    public var rename: CapabilitySupport
    public var permanentDelete: CapabilitySupport
    public var restorableTrash: CapabilitySupport
    public var capacity: CapabilitySupport
    public var resumableUpload: CapabilitySupport
    public var bestVerification: VerificationLevel
    public var backgroundTransfers: CapabilitySupport
    public var versionedBackups: CapabilitySupport

    public init(
        browse: CapabilitySupport, download: CapabilitySupport, upload: CapabilitySupport,
        createFolder: CapabilitySupport, rename: CapabilitySupport, permanentDelete: CapabilitySupport,
        restorableTrash: CapabilitySupport, capacity: CapabilitySupport, resumableUpload: CapabilitySupport,
        bestVerification: VerificationLevel, backgroundTransfers: CapabilitySupport, versionedBackups: CapabilitySupport
    ) {
        self.browse = browse
        self.download = download
        self.upload = upload
        self.createFolder = createFolder
        self.rename = rename
        self.permanentDelete = permanentDelete
        self.restorableTrash = restorableTrash
        self.capacity = capacity
        self.resumableUpload = resumableUpload
        self.bestVerification = bestVerification
        self.backgroundTransfers = backgroundTransfers
        self.versionedBackups = versionedBackups
    }

    /// Rows for a capability summary, in display order.
    public var summaryRows: [(String, CapabilitySupport)] {
        [
            ("Browse folders", browse),
            ("Download and preview", download),
            ("Upload files and folders", upload),
            ("Create folders", createFolder),
            ("Rename and move", rename),
            ("Delete permanently", permanentDelete),
            ("Restorable Trash", restorableTrash),
            ("Capacity reporting", capacity),
            ("Resume interrupted uploads", resumableUpload),
            ("Transfers while app is in background", backgroundTransfers),
            ("Versioned backups", versionedBackups),
        ]
    }
}
