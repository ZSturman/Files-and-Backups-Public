import Foundation

/// In-memory provider for tests and previews, with fault injection for
/// interruption, reconnect, and capability-limit cases.
public final class InMemoryProvider: ByteStorageProvider, @unchecked Sendable {
    public struct Faults: Sendable {
        /// Fail `connect()` this many more times with `.unreachable`.
        public var failConnects = 0
        /// Throw `.unreachable` once the total bytes written reaches this value.
        public var disconnectAfterWrittenBytes: Int64?
        /// Reject credentials.
        public var rejectCredentials = false
        /// Report this many bytes free; writes beyond it fail with `.insufficientSpace`.
        public var availableBytes: Int64?
        /// Corrupt the first byte of each write (verification tests).
        public var corruptWrites = false

        public init() {}
    }

    private enum Node {
        case directory(Date)
        case file(Data, Date)
    }

    private var nodes: [RemotePath: Node] = [.root: .directory(Date())]
    private let lock = NSLock()
    public var faults = Faults()
    public private(set) var bytesWritten: Int64 = 0
    public private(set) var connectCount = 0
    public var reportsCapacity: Bool

    public init(reportsCapacity: Bool = false) {
        self.reportsCapacity = reportsCapacity
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            browse: .supported, download: .supported, upload: .supported, createFolder: .supported,
            rename: .supported, permanentDelete: .supported, restorableTrash: .unsupported("test provider"),
            capacity: reportsCapacity ? .supported : .unsupported("test provider"), resumableUpload: .supported,
            bestVerification: .sha256Readback, backgroundTransfers: .unsupported("test provider"),
            versionedBackups: .unsupported("test provider")
        )
    }

    public func updateFaults(_ body: (inout Faults) -> Void) {
        lock.withLock { body(&faults) }
    }

    // MARK: Test inspection

    public func fileData(_ path: String) -> Data? {
        lock.withLock {
            guard let path = try? RemotePath(path), case .file(let data, _) = nodes[path] else { return nil }
            return data
        }
    }

    public func allPaths() -> [String] {
        lock.withLock { nodes.keys.map(\.string).filter { !$0.isEmpty }.sorted() }
    }

    public func seedFile(_ path: String, data: Data) throws {
        let path = try RemotePath(path)
        lock.withLock {
            var parent = path.parent
            while let directory = parent, !directory.isRoot {
                if nodes[directory] == nil { nodes[directory] = .directory(Date()) }
                parent = directory.parent
            }
            nodes[path] = .file(data, Date())
        }
    }

    public func seedDirectory(_ path: String) throws {
        let path = try RemotePath(path)
        lock.withLock { nodes[path] = .directory(Date()) }
    }

    // MARK: StorageProvider

    public func connect() async throws {
        try lock.withLock {
            connectCount += 1
            if faults.rejectCredentials { throw FileCoreError.authenticationFailed }
            if faults.failConnects > 0 {
                faults.failConnects -= 1
                throw FileCoreError.unreachable("simulated network loss")
            }
        }
    }

    public func disconnect() async {}

    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        try lock.withLock {
            guard case .directory = nodes[directory] else { throw FileCoreError.notFound(directory) }
            return nodes.compactMap { path, node -> RemoteItem? in
                guard path.parent == directory else { return nil }
                return Self.item(path, node)
            }
            .sorted { $0.name < $1.name }
        }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem? {
        lock.withLock { nodes[path].map { Self.item(path, $0) } }
    }

    private static func item(_ path: RemotePath, _ node: Node) -> RemoteItem {
        switch node {
        case .directory(let date): return RemoteItem(path: path, isDirectory: true, size: nil, modified: date)
        case .file(let data, let date): return RemoteItem(path: path, isDirectory: false, size: Int64(data.count), modified: date)
        }
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try lock.withLock {
            guard nodes[path] == nil else { throw FileCoreError.alreadyExists(path) }
            guard let parent = path.parent, case .directory = nodes[parent] else { throw FileCoreError.notFound(path) }
            nodes[path] = .directory(Date())
        }
    }

    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        try lock.withLock {
            guard nodes[source] != nil else { throw FileCoreError.notFound(source) }
            guard nodes[destination] == nil else { throw FileCoreError.alreadyExists(destination) }
            for (path, node) in nodes where path.isWithin(source) {
                nodes[path] = nil
                let suffix = Array(path.components.dropFirst(source.components.count))
                nodes[destination.appending(try RemotePath(components: suffix))] = node
            }
        }
    }

    public func delete(_ path: RemotePath) async throws {
        try lock.withLock {
            guard nodes[path] != nil else { throw FileCoreError.notFound(path) }
            for key in nodes.keys where key.isWithin(path) { nodes[key] = nil }
        }
    }

    public func capacity() async throws -> StorageCapacity? {
        guard reportsCapacity else { return nil }
        return lock.withLock {
            let used = nodes.values.reduce(Int64(0)) { total, node in
                if case .file(let data, _) = node { return total + Int64(data.count) }
                return total
            }
            let available = faults.availableBytes ?? (1 << 40)
            return StorageCapacity(totalBytes: used + available, availableBytes: available)
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let data = try lock.withLock { () throws -> Data in
            guard case .file(let data, _) = nodes[path] else { throw FileCoreError.notFound(path) }
            return data
        }
        try data.write(to: localURL)
        progress(Int64(data.count))
    }

    public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
        try lock.withLock {
            guard case .file(let data, _) = nodes[path] else { throw FileCoreError.notFound(path) }
            let start = Int(min(offset, Int64(data.count)))
            let end = min(start + length, data.count)
            return data.subdata(in: start..<end)
        }
    }

    public func writeChunk(_ data: Data, to path: RemotePath, at offset: Int64) async throws {
        try lock.withLock {
            if let limit = faults.disconnectAfterWrittenBytes, bytesWritten + Int64(data.count) > limit {
                // Simulate a connection dropping mid-chunk: part of it lands.
                let partial = Int(max(0, limit - bytesWritten))
                if partial > 0 { try writeLocked(data.prefix(partial), to: path, at: offset) }
                bytesWritten += Int64(partial)
                faults.disconnectAfterWrittenBytes = nil
                throw FileCoreError.unreachable("simulated disconnect")
            }
            if let available = faults.availableBytes {
                guard Int64(data.count) <= available else { throw FileCoreError.insufficientSpace }
                faults.availableBytes = available - Int64(data.count)
            }
            var payload = data
            if faults.corruptWrites, !payload.isEmpty { payload[payload.startIndex] ^= 0xFF }
            try writeLocked(payload, to: path, at: offset)
            bytesWritten += Int64(data.count)
        }
    }

    private func writeLocked(_ data: Data, to path: RemotePath, at offset: Int64) throws {
        guard let parent = path.parent, case .directory = nodes[parent] else { throw FileCoreError.notFound(path) }
        if offset == 0 {
            guard nodes[path] == nil else { throw FileCoreError.alreadyExists(path) }
            nodes[path] = .file(Data(data), Date())
            return
        }
        guard case .file(var existing, _) = nodes[path] else { throw FileCoreError.notFound(path) }
        if existing.count > Int(offset) { existing = existing.prefix(Int(offset)) }
        if existing.count < Int(offset) { existing.append(Data(count: Int(offset) - existing.count)) }
        existing.append(data)
        nodes[path] = .file(existing, Date())
    }
}
