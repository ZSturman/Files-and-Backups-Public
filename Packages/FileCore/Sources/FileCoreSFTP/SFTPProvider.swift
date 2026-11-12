import Citadel
import Crypto
import FileCore
import Foundation
import NIOCore
import NIOSSH

/// Direct SFTP (SSH File Transfer Protocol v3) with password authentication
/// and a pinned host key. The first Test Connection reports the server's
/// key fingerprint; once saved, any different key is refused.
///
/// Uploads use the shared temp-file sink: exclusive create, offset writes for
/// verified resume, and a rename that never replaces (SFTP v3 semantics).
public final class SFTPProvider: ByteStorageProvider, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var root: String
        public var username: String
        public var password: String
        /// OpenSSH-format public key ("ssh-ed25519 AAAA…") to require; nil
        /// only during first-time setup, when the presented key is recorded.
        public var pinnedHostKey: String?
        public var timeout: Int64

        public init(host: String, port: Int = 22, root: String, username: String, password: String, pinnedHostKey: String?, timeout: Int64 = 20) {
            self.host = host
            self.port = port
            self.root = root
            self.username = username
            self.password = password
            self.pinnedHostKey = pinnedHostKey
            self.timeout = timeout
        }
    }

    private let configuration: Configuration
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private let lock = NSLock()
    /// The key the server presented on the last connect (OpenSSH format).
    public private(set) var presentedHostKey: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            browse: .supported, download: .supported, upload: .supported, createFolder: .supported,
            rename: .supported, permanentDelete: .supported,
            restorableTrash: .unsupported("SFTP has no restorable Trash; deletes are permanent"),
            capacity: .unsupported("SFTP v3 does not report free space"),
            resumableUpload: .supported, bestVerification: .sha256Readback,
            backgroundTransfers: .unsupported("SFTP transfers pause when iOS suspends the app and continue when it reopens"),
            versionedBackups: .unsupported("an SFTP folder stores files; it is not a versioned backup service")
        )
    }

    /// SHA256 fingerprint in OpenSSH's display format.
    public static func fingerprint(ofOpenSSHKey key: String) -> String? {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // MARK: Connection

    public func connect() async throws {
        let validator = PinningValidator(pinned: configuration.pinnedHostKey)
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: configuration.host, port: configuration.port,
                authenticationMethod: .passwordBased(username: configuration.username, password: configuration.password),
                hostKeyValidator: .custom(validator), reconnect: .never,
                connectTimeout: .seconds(configuration.timeout)
            )
        } catch {
            lock.withLock { presentedHostKey = validator.presented }
            if validator.mismatch {
                throw FileCoreError.permissionDenied("the server's host key changed (now \(validator.presented.flatMap(Self.fingerprint) ?? "unknown")). Remove and re-add this connection only if you trust the change")
            }
            throw Self.map(error, path: .root, connecting: true)
        }
        lock.withLock { presentedHostKey = validator.presented }
        do {
            let sftp = try await client.openSFTP()
            lock.withLock {
                self.client = client
                self.sftp = sftp
            }
        } catch {
            try? await client.close()
            throw Self.map(error, path: .root, connecting: true)
        }
        guard let rootItem = try await item(at: .root), rootItem.isDirectory else {
            throw FileCoreError.notFound(try RemotePath(configuration.root))
        }
    }

    public func disconnect() async {
        let (sftp, client) = lock.withLock { () -> (SFTPClient?, SSHClient?) in
            defer { self.sftp = nil; self.client = nil }
            return (self.sftp, self.client)
        }
        try? await sftp?.close()
        try? await client?.close()
    }

    private func requireSFTP() throws -> SFTPClient {
        guard let sftp = lock.withLock({ sftp }) else { throw FileCoreError.unreachable("not connected") }
        return sftp
    }

    /// Absolute or home-relative server path for a connection path.
    func serverPath(_ path: RemotePath) -> String {
        var base = configuration.root.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "." }
        if base.hasSuffix("/"), base.count > 1 { base.removeLast() }
        return path.isRoot ? base : base + "/" + path.string
    }

    // MARK: StorageProvider

    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let sftp = try requireSFTP()
        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: serverPath(directory))
        } catch {
            throw Self.map(error, path: directory)
        }
        return names.flatMap(\.components).compactMap { component -> RemoteItem? in
            guard component.filename != ".", component.filename != "..",
                  let path = try? directory.appending(component.filename) else { return nil }
            return Self.item(path, component.attributes)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    private static func item(_ path: RemotePath, _ attributes: SFTPFileAttributes) -> RemoteItem {
        let mode = attributes.permissions ?? 0
        let isDirectory = mode & 0o170000 == 0o040000
        return RemoteItem(
            path: path, isDirectory: isDirectory, size: isDirectory ? nil : attributes.size.map(Int64.init),
            modified: attributes.accessModificationTime?.modificationTime
        )
    }

    public func item(at path: RemotePath) async throws -> RemoteItem? {
        let sftp = try requireSFTP()
        do {
            return Self.item(path, try await sftp.getAttributes(at: serverPath(path)))
        } catch {
            let mapped = Self.map(error, path: path)
            if case .notFound = mapped { return nil }
            throw mapped
        }
    }

    public func createDirectory(_ path: RemotePath) async throws {
        let sftp = try requireSFTP()
        if try await item(at: path) != nil { throw FileCoreError.alreadyExists(path) }
        do {
            try await sftp.createDirectory(atPath: serverPath(path))
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        let sftp = try requireSFTP()
        // SFTP v3 rename fails when the target exists; the check gives a
        // clear error on servers that report a generic failure.
        if try await item(at: destination) != nil { throw FileCoreError.alreadyExists(destination) }
        do {
            try await sftp.rename(at: serverPath(source), to: serverPath(destination))
        } catch {
            throw Self.map(error, path: source)
        }
    }

    public func delete(_ path: RemotePath) async throws {
        guard !path.isRoot else { throw FileCoreError.permissionDenied("the connection root cannot be deleted") }
        guard let node = try await item(at: path) else { throw FileCoreError.notFound(path) }
        let sftp = try requireSFTP()
        do {
            if node.isDirectory {
                for child in try await list(path) { try await delete(child.path) }
                try await sftp.rmdir(at: serverPath(path))
            } else {
                try await sftp.remove(at: serverPath(path))
            }
        } catch let error as FileCoreError {
            throw error
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func capacity() async throws -> StorageCapacity? { nil }

    public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let sftp = try requireSFTP()
        do {
            return try await sftp.withFile(filePath: serverPath(path), flags: .read) { file in
                var data = Data()
                while data.count < length {
                    let chunk = min(length - data.count, 64 * 1024)
                    var buffer = try await file.read(from: UInt64(offset) + UInt64(data.count), length: UInt32(chunk))
                    guard buffer.readableBytes > 0, let bytes = buffer.readBytes(length: buffer.readableBytes) else { break }
                    data.append(contentsOf: bytes)
                }
                return data
            }
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let size = try await item(at: path)?.size else { throw FileCoreError.notFound(path) }
        try? FileManager.default.removeItem(at: localURL)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let data = try await read(path, offset: offset, length: Int(min(4 << 20, size - offset)))
            guard !data.isEmpty else { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset)
        }
    }

    /// SSH_FXF_EXCL: with CREAT, fail if the file exists.
    static let exclusive = SFTPOpenFileFlags(rawValue: 0x00000020)

    public func writeChunk(_ data: Data, to path: RemotePath, at offset: Int64) async throws {
        let sftp = try requireSFTP()
        let flags: SFTPOpenFileFlags = offset == 0 ? [.write, .create, Self.exclusive] : [.write]
        do {
            try await sftp.withFile(filePath: serverPath(path), flags: flags) { file in
                var written = 0
                // SFTP servers cap a single write (commonly 255 KiB).
                while written < data.count {
                    let end = min(written + 255 * 1024, data.count)
                    try await file.write(ByteBuffer(bytes: data[data.startIndex.advanced(by: written)..<data.startIndex.advanced(by: end)]), at: UInt64(offset) + UInt64(written))
                    written = end
                }
            }
        } catch {
            let mapped = Self.map(error, path: path)
            // Some servers report an existing file under EXCL as a generic failure.
            if offset == 0, case .protocolError = mapped, try await item(at: path) != nil { throw FileCoreError.alreadyExists(path) }
            throw mapped
        }
    }

    // MARK: Errors

    static func map(_ error: any Error, path: RemotePath, connecting: Bool = false) -> FileCoreError {
        if let error = error as? FileCoreError { return error }
        if let status = (error as? SFTPMessage.Status) ?? { if case SFTPError.errorStatus(let s)? = error as? SFTPError { return s } else { return nil } }() {
            switch status.errorCode {
            case .noSuchFile: return .notFound(path)
            case .permissionDenied: return .permissionDenied(path.description)
            case .noConnection, .connectionLost: return .unreachable(status.message)
            default: return .protocolError(status.message.isEmpty ? "SFTP failure" : status.message)
            }
        }
        if let sftpError = error as? SFTPError, case .connectionClosed = sftpError { return .unreachable("connection closed") }
        if let citadel = error as? CitadelError, case .unauthorized = citadel { return .authenticationFailed }
        if let auth = error as? AuthenticationFailed { _ = auth; return .authenticationFailed }
        let description = String(describing: error)
        if connecting, description.localizedCaseInsensitiveContains("auth") { return .authenticationFailed }
        if error is IOError || error is ChannelError || description.contains("connect") || description.contains("timeout") {
            return .unreachable(description)
        }
        return .protocolError(description)
    }
}

/// Records the presented host key; accepts it only when it matches the pin
/// (or when no pin exists yet, for first-time setup).
final class PinningValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let pinned: String?
    private let lock = NSLock()
    private var _presented: String?
    private var _mismatch = false

    init(pinned: String?) {
        self.pinned = pinned
    }

    var presented: String? { lock.withLock { _presented } }
    var mismatch: Bool { lock.withLock { _mismatch } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let normalized = key.split(separator: " ").prefix(2).joined(separator: " ")
        lock.withLock { _presented = normalized }
        guard let pinned else { return validationCompletePromise.succeed(()) }
        if pinned.split(separator: " ").prefix(2).joined(separator: " ") == normalized {
            validationCompletePromise.succeed(())
        } else {
            lock.withLock { _mismatch = true }
            validationCompletePromise.fail(FileCoreError.permissionDenied("host key mismatch"))
        }
    }
}
