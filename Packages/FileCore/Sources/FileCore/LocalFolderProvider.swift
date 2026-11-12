import Foundation

/// A user-selected folder or disk on this Mac (or any local directory in
/// tests). Paths that resolve outside the folder through links are refused.
public final class LocalFolderProvider: ByteStorageProvider, @unchecked Sendable {
    private let rootURL: URL
    private let bookmark: Data?
    private var scopedURL: URL?
    private let lock = NSLock()

    public init(rootURL: URL, bookmark: Data? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        self.bookmark = bookmark
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            browse: .supported, download: .supported, upload: .supported, createFolder: .supported,
            rename: .supported, permanentDelete: .supported,
            restorableTrash: .unsupported("deletes from a selected folder are permanent in this app"),
            capacity: .supported, resumableUpload: .supported, bestVerification: .sha256Readback,
            backgroundTransfers: .unsupported("transfers run while the app is open"),
            versionedBackups: .unsupported("use the Mac backup companion for versioned backups")
        )
    }

    private var root: URL {
        lock.withLock { scopedURL ?? rootURL }
    }

    public func connect() async throws {
        var url = rootURL
        if let bookmark {
            var stale = false
            #if os(macOS)
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            #else
            url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            #endif
            _ = url.startAccessingSecurityScopedResource()
        }
        lock.withLock { scopedURL = url.standardizedFileURL }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileCoreError.unreachable("the selected folder or disk is not available")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw FileCoreError.permissionDenied("the selected folder is not writable")
        }
    }

    public func disconnect() async {
        let url = lock.withLock { () -> URL? in
            defer { scopedURL = nil }
            return scopedURL
        }
        if bookmark != nil { url?.stopAccessingSecurityScopedResource() }
    }

    /// Maps a provider path to a URL, refusing anything that escapes the root
    /// through a symbolic link on an existing ancestor.
    func url(for path: RemotePath) throws -> URL {
        let base = root
        var url = base
        for component in path.components { url.appendPathComponent(component) }
        let resolvedBase = base.resolvingSymlinksInPath().path
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path.count > base.path.count {
            probe.deleteLastPathComponent()
        }
        let resolved = probe.resolvingSymlinksInPath().path
        guard resolved == resolvedBase || resolved.hasPrefix(resolvedBase + "/") else {
            throw FileCoreError.permissionDenied("\(path) resolves outside the selected folder")
        }
        return url
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let url = try url(for: directory)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        } catch {
            throw map(error, path: directory)
        }
        return try contents.compactMap { child in
            let values = try child.resourceValues(forKeys: Set(keys))
            guard let path = try? directory.appending(child.lastPathComponent) else { return nil }
            return RemoteItem(path: path, isDirectory: values.isDirectory ?? false, size: values.isDirectory == true ? nil : Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem? {
        let url = try url(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return RemoteItem(path: path, isDirectory: isDirectory.boolValue, size: isDirectory.boolValue ? nil : Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
    }

    public func createDirectory(_ path: RemotePath) async throws {
        do {
            try FileManager.default.createDirectory(at: try url(for: path), withIntermediateDirectories: false)
        } catch {
            throw map(error, path: path)
        }
    }

    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        let from = try url(for: source)
        let to = try url(for: destination)
        // RENAME_EXCL: fail instead of replacing an existing destination.
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            throw posixError(errno, path: errno == EEXIST ? destination : source)
        }
    }

    public func delete(_ path: RemotePath) async throws {
        guard !path.isRoot else { throw FileCoreError.permissionDenied("the connection root cannot be deleted") }
        do {
            try FileManager.default.removeItem(at: try url(for: path))
        } catch {
            throw map(error, path: path)
        }
    }

    public func capacity() async throws -> StorageCapacity? {
        let values = try root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        return StorageCapacity(totalBytes: Int64(total), availableBytes: Int64(available))
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let source = try url(for: path)
        try? FileManager.default.removeItem(at: localURL)
        do {
            try FileManager.default.copyItem(at: source, to: localURL)
        } catch {
            throw map(error, path: path)
        }
        progress(Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: try url(for: path))
        } catch {
            throw map(error, path: path)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    public func writeChunk(_ data: Data, to path: RemotePath, at offset: Int64) async throws {
        let url = try url(for: path)
        let flags = offset == 0 ? (O_WRONLY | O_CREAT | O_EXCL) : O_WRONLY
        let fd = open(url.path, flags, 0o644)
        guard fd >= 0 else { throw posixError(errno, path: path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            if offset > 0 {
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
            }
            try handle.write(contentsOf: data)
        } catch {
            throw map(error, path: path)
        }
    }

    private func posixError(_ code: Int32, path: RemotePath) -> FileCoreError {
        switch code {
        case EEXIST: return .alreadyExists(path)
        case ENOENT: return .notFound(path)
        case ENOTDIR: return .notADirectory(path)
        case EACCES, EPERM: return .permissionDenied(path.description)
        case ENOSPC, EDQUOT: return .insufficientSpace
        default: return .protocolError(String(cString: strerror(code)))
        }
    }

    private func map(_ error: any Error, path: RemotePath) -> FileCoreError {
        if let error = error as? FileCoreError { return error }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteFileExistsError: return .alreadyExists(path)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .permissionDenied(path.description)
            case NSFileWriteOutOfSpaceError: return .insufficientSpace
            default: break
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return posixError(Int32(underlying.code), path: path)
            }
        }
        if nsError.domain == NSPOSIXErrorDomain { return posixError(Int32(nsError.code), path: path) }
        return .protocolError(nsError.localizedDescription)
    }
}
