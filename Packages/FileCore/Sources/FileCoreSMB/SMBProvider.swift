import AMSMB2
import FileCore
import Foundation

/// Direct SMB2/3 access to a share on a Mac, Windows PC, Linux/Pi (Samba), or
/// NAS. libsmb2 negotiates SMB2 or SMB3 only; there is no SMB1 fallback.
///
/// Uploads use the shared temp-file sink: offset writes make resume possible,
/// guarded by the sink's identity and tail checks.
public final class SMBProvider: ByteStorageProvider, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int?
        public var share: String
        public var root: RemotePath
        public var username: String
        public var domain: String
        public var password: String
        public var requireEncryption: Bool
        public var timeout: TimeInterval

        public init(
            host: String, port: Int? = nil, share: String, root: RemotePath = .root, username: String,
            domain: String = "", password: String, requireEncryption: Bool = false, timeout: TimeInterval = 30
        ) {
            self.host = host
            self.port = port
            self.share = share
            self.root = root
            self.username = username
            self.domain = domain
            self.password = password
            self.requireEncryption = requireEncryption
            self.timeout = timeout
        }

        public init(profile: ConnectionProfile, password: String) throws {
            guard profile.kind == .smb else { throw FileCoreError.invalidConfiguration("not an SMB connection") }
            self.init(
                host: profile.host, port: profile.port, share: profile.share, root: try profile.validatedRoot(),
                username: profile.username, domain: profile.domain, password: password,
                requireEncryption: profile.requireEncryption
            )
        }

        func serverURL() throws -> URL {
            let host = host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !host.contains("/"), !host.contains("@") else {
                throw FileCoreError.invalidConfiguration("enter a host name or IP address without smb://")
            }
            var components = URLComponents()
            components.scheme = "smb"
            components.host = host
            components.port = port
            guard let url = components.url else { throw FileCoreError.invalidConfiguration("invalid host") }
            return url
        }
    }

    private let configuration: Configuration
    private var manager: SMB2Manager?
    private let lock = NSLock()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            browse: .supported, download: .supported, upload: .supported, createFolder: .supported,
            rename: .supported, permanentDelete: .supported,
            restorableTrash: .unsupported("SMB shares have no restorable Trash; deletes are permanent"),
            capacity: .supported,
            resumableUpload: .supported,
            bestVerification: .sha256Readback,
            backgroundTransfers: .unsupported("SMB transfers pause when iOS suspends the app and continue when it reopens"),
            versionedBackups: .unsupported("an SMB share stores files; it is not a versioned backup service")
        )
    }

    // MARK: Share discovery (setup only)

    /// Lists visible shares on a server, for the Add Storage form.
    public static func listShares(host: String, port: Int?, username: String, domain: String, password: String) async throws -> [String] {
        let configuration = Configuration(host: host, port: port, share: "IPC$", username: username, domain: domain, password: password)
        guard let manager = SMB2Manager(url: try configuration.serverURL(), domain: domain, credential: URLCredential(user: username, password: password, persistence: .forSession)) else {
            throw FileCoreError.invalidConfiguration("invalid server address")
        }
        manager.timeout = configuration.timeout
        do {
            return try await manager.listShares().map(\.name).sorted()
        } catch {
            throw SMBProvider.map(error, path: .root)
        }
    }

    // MARK: Connection

    public func connect() async throws {
        let url = try configuration.serverURL()
        let credential = URLCredential(user: configuration.username, password: configuration.password, persistence: .forSession)
        guard let manager = SMB2Manager(url: url, domain: configuration.domain, credential: credential) else {
            throw FileCoreError.invalidConfiguration("invalid server address")
        }
        manager.timeout = configuration.timeout
        let share = configuration.share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        guard !share.isEmpty, !share.contains("/"), !share.contains("\\") else {
            throw FileCoreError.invalidConfiguration("enter one share name")
        }
        // libsmb2 reports most connect failures as a generic -1 (EPERM), so
        // reachability and credentials are checked separately for an
        // actionable error.
        try await TCPProbe.check(host: url.host ?? configuration.host, port: configuration.port ?? 445, timeout: min(configuration.timeout, 10))
        do {
            try await manager.connectShare(name: share, encrypted: configuration.requireEncryption)
        } catch {
            let mapped = SMBProvider.map(error, path: .root, connecting: true)
            guard case .authenticationFailed = mapped else { throw mapped }
            let shares = try? await SMBProvider.listShares(
                host: configuration.host, port: configuration.port, username: configuration.username,
                domain: configuration.domain, password: configuration.password
            )
            guard let shares else { throw FileCoreError.authenticationFailed }
            if !shares.contains(where: { $0.caseInsensitiveCompare(share) == .orderedSame }) {
                throw FileCoreError.invalidConfiguration("the server has no share named \"\(share)\" visible to this user")
            }
            if configuration.requireEncryption {
                throw FileCoreError.unsupported("SMB3 encryption was required but the share refused an encrypted session")
            }
            throw FileCoreError.permissionDenied("this user cannot open the share \"\(share)\"")
        }
        lock.withLock { self.manager = manager }
        if !configuration.root.isRoot {
            guard let rootItem = try await item(at: .root) else { throw FileCoreError.notFound(configuration.root) }
            guard rootItem.isDirectory else { throw FileCoreError.notADirectory(configuration.root) }
        }
    }

    public func disconnect() async {
        let manager = lock.withLock { () -> SMB2Manager? in
            defer { self.manager = nil }
            return self.manager
        }
        try? await manager?.disconnectShare(gracefully: true)
    }

    private func requireManager() throws -> SMB2Manager {
        guard let manager = lock.withLock({ manager }) else { throw FileCoreError.unreachable("not connected") }
        return manager
    }

    /// Share-relative path string for a connection path. libsmb2 expects SMB
    /// backslash separators for directory and rename operations; names can
    /// never contain a backslash (RemotePath rejects it).
    func sharePath(_ path: RemotePath) -> String {
        configuration.root.appending(path).components.joined(separator: "\\")
    }

    // MARK: StorageProvider

    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let manager = try requireManager()
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await manager.contentsOfDirectory(atPath: sharePath(directory))
        } catch {
            throw SMBProvider.map(error, path: directory)
        }
        return entries.compactMap { entry -> RemoteItem? in
            guard let name = entry[.nameKey] as? String, name != ".", name != "..",
                  let path = try? directory.appending(name) else { return nil }
            return SMBProvider.item(path, entry)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem? {
        let manager = try requireManager()
        do {
            let attributes = try await manager.attributesOfItem(atPath: sharePath(path))
            return SMBProvider.item(path, attributes)
        } catch {
            let mapped = SMBProvider.map(error, path: path)
            if case .notFound = mapped { return nil }
            throw mapped
        }
    }

    private static func item(_ path: RemotePath, _ attributes: [URLResourceKey: Any]) -> RemoteItem {
        let isDirectory = (attributes[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
        let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value
        return RemoteItem(path: path, isDirectory: isDirectory, size: isDirectory ? nil : size, modified: attributes[.contentModificationDateKey] as? Date)
    }

    public func createDirectory(_ path: RemotePath) async throws {
        let manager = try requireManager()
        do {
            try await manager.createDirectory(atPath: sharePath(path))
        } catch {
            throw SMBProvider.map(error, path: path)
        }
    }

    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        let manager = try requireManager()
        // libsmb2 renames with ReplaceIfExists = 0, so an existing destination
        // makes the server refuse; the pre-check gives a clearer error.
        if try await item(at: destination) != nil { throw FileCoreError.alreadyExists(destination) }
        do {
            try await manager.moveItem(atPath: sharePath(source), toPath: sharePath(destination))
        } catch {
            let mapped = SMBProvider.map(error, path: source)
            if case .alreadyExists = mapped { throw FileCoreError.alreadyExists(destination) }
            throw mapped
        }
    }

    public func delete(_ path: RemotePath) async throws {
        guard !path.isRoot else { throw FileCoreError.permissionDenied("the connection root cannot be deleted") }
        guard let existing = try await item(at: path) else { throw FileCoreError.notFound(path) }
        try await deleteTree(existing)
    }

    /// Recursive delete built on this provider's own paths. AMSMB2's recursive
    /// removal rebuilds child paths through URL, which mangles SMB paths.
    private func deleteTree(_ node: RemoteItem) async throws {
        let manager = try requireManager()
        do {
            if node.isDirectory {
                for child in try await list(node.path) {
                    try await deleteTree(child)
                }
                try await manager.removeDirectory(atPath: sharePath(node.path), recursive: false)
            } else {
                try await manager.removeFile(atPath: sharePath(node.path))
            }
        } catch let error as FileCoreError {
            throw error
        } catch {
            throw SMBProvider.map(error, path: node.path)
        }
    }

    public func capacity() async throws -> StorageCapacity? {
        let manager = try requireManager()
        guard let attributes = try? await manager.attributesOfFileSystem(forPath: sharePath(.root)),
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value, total > 0 else {
            return nil
        }
        return StorageCapacity(totalBytes: total, availableBytes: free)
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let manager = try requireManager()
        try? FileManager.default.removeItem(at: localURL)
        do {
            try await manager.downloadItem(atPath: sharePath(path), to: localURL) { bytes, _ in
                progress(bytes)
                return true
            }
        } catch {
            throw SMBProvider.map(error, path: path)
        }
    }

    public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let manager = try requireManager()
        do {
            let range = UInt64(offset)..<UInt64(offset + Int64(length))
            return try await manager.contents(atPath: sharePath(path), range: range, progress: nil)
        } catch {
            throw SMBProvider.map(error, path: path)
        }
    }

    public func writeChunk(_ data: Data, to path: RemotePath, at offset: Int64) async throws {
        let manager = try requireManager()
        do {
            if offset == 0 {
                // Exclusive create (O_CREAT | O_EXCL in AMSMB2).
                try await manager.write(data: data, toPath: sharePath(path), progress: nil)
            } else {
                // Truncates to `offset` first, then writes.
                try await manager.append(data: data, toPath: sharePath(path), offset: offset, progress: nil)
            }
        } catch {
            throw SMBProvider.map(error, path: path)
        }
    }

    // MARK: Errors

    static func map(_ error: any Error, path: RemotePath, connecting: Bool = false) -> FileCoreError {
        if let error = error as? FileCoreError { return error }
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOENT: return connecting ? .notFound(path) : .notFound(path)
            case .EEXIST, .ENOTEMPTY: return .alreadyExists(path)
            case .ENOTDIR: return .notADirectory(path)
            case .EACCES, .EPERM:
                return connecting ? .authenticationFailed : .permissionDenied(path.description)
            case .ENOSPC, .EDQUOT: return .insufficientSpace
            case .ETIMEDOUT, .ECONNREFUSED, .ECONNRESET, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .ENOTCONN, .EPIPE, .EHOSTDOWN:
                return .unreachable(posix.localizedDescription)
            case .ECONNABORTED:
                return .unreachable(posix.localizedDescription)
            case .EINVAL where connecting:
                return .invalidConfiguration(posix.localizedDescription)
            default:
                return .protocolError(posix.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return map(POSIXError(code), path: path, connecting: connecting)
        }
        if nsError.domain == NSURLErrorDomain {
            return .unreachable(nsError.localizedDescription)
        }
        return .protocolError(nsError.localizedDescription)
    }
}
