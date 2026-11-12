import Foundation

/// Bounded app-owned storage for imported files waiting to upload. Imported
/// items are copied here (with SHA-256 computed during the copy) so a queued
/// transfer survives the picker's temporary permission ending, app relaunch,
/// and the phone going offline.
public final class StagingArea: @unchecked Sendable {
    public let root: URL
    public var quotaBytes: Int64
    /// Free space always left on the device volume.
    public let volumeReserveBytes: Int64

    public struct StagedImport: Sendable {
        public var rootFolderName: String?
        public var directories: [String]
        public var items: [TransferItem]
        public var skippedSymbolicLinks: Int
    }

    public init(root: URL, quotaBytes: Int64 = 10 << 30, volumeReserveBytes: Int64 = 1 << 30) {
        self.root = root
        self.quotaBytes = quotaBytes
        self.volumeReserveBytes = volumeReserveBytes
    }

    public func url(forStaged relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    public func usedBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    public func availableBytes() -> Int64 {
        let quotaLeft = max(0, quotaBytes - usedBytes())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? Int.max)
        return max(0, min(quotaLeft, free - volumeReserveBytes))
    }

    /// Copies one folder (becoming the job's root folder) or a set of files.
    public func stage(folder: URL, jobID: UUID) throws -> StagedImport {
        try withAccess(folder) {
            let rootName = folder.lastPathComponent.precomposedStringWithCanonicalMapping
            try RemotePath.validate(name: rootName)
            var directories: [String] = []
            var files: [(URL, String, Int64)] = []
            var skipped = 0
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
                throw FileCoreError.permissionDenied("cannot read the selected folder")
            }
            let basePath = folder.standardizedFileURL.resolvingSymlinksInPath().path
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: Set(keys))
                let relative = Self.relativePath(of: url, base: basePath)
                for component in relative.split(separator: "/") { try RemotePath.validate(name: String(component)) }
                if values.isSymbolicLink == true {
                    skipped += 1
                } else if values.isDirectory == true {
                    directories.append(relative)
                } else if values.isRegularFile == true {
                    files.append((url, relative, Int64(values.fileSize ?? 0)))
                }
            }
            let items = try copy(files, jobID: jobID)
            return StagedImport(rootFolderName: rootName, directories: directories.sorted(), items: items, skippedSymbolicLinks: skipped)
        }
    }

    public func stage(files urls: [URL], jobID: UUID) throws -> StagedImport {
        var files: [(URL, String, Int64)] = []
        var names = Set<String>()
        for url in urls {
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            try RemotePath.validate(name: name)
            // Two picked files with the same name keep both in the manifest too.
            var unique = name
            var attempt = 2
            while names.contains(unique) {
                unique = CollisionNaming.candidate(for: name, attempt: attempt)
                attempt += 1
            }
            names.insert(unique)
            let size = try withAccess(url) { Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            files.append((url, unique, size))
        }
        let items = try copy(files, jobID: jobID)
        return StagedImport(rootFolderName: nil, directories: [], items: items, skippedSymbolicLinks: 0)
    }

    public func removeJob(_ jobID: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(jobID.uuidString, isDirectory: true))
    }

    /// Removes staged job folders that no longer belong to a known job. Recent
    /// folders are kept: the Share Extension may still be handing them over.
    public func removeOrphans(keeping jobIDs: Set<UUID>, olderThan age: TimeInterval = 0) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in contents {
            guard let id = UUID(uuidString: url.lastPathComponent), !jobIDs.contains(id) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard Date().timeIntervalSince(modified) >= age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func copy(_ files: [(URL, String, Int64)], jobID: UUID) throws -> [TransferItem] {
        let needed = files.reduce(Int64(0)) { $0 + $1.2 }
        let available = availableBytes()
        guard needed <= available else { throw FileCoreError.stagingQuotaExceeded(needed: needed, available: available) }

        let jobRoot = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        var items: [TransferItem] = []
        do {
            for (source, relative, _) in files {
                try Task.checkCancellation()
                let itemID = UUID()
                let stagedRelative = "\(jobID.uuidString)/\(itemID.uuidString)"
                let destination = url(forStaged: stagedRelative)
                let (size, hash) = try withAccess(source) { try Self.copyHashing(from: source, to: destination) }
                var item = TransferItem(id: itemID, relativePath: relative, source: .staged(stagedRelative), size: size, sha256: hash)
                item.state = .queued
                items.append(item)
            }
        } catch {
            removeJob(jobID)
            throw error
        }
        return items
    }

    static func copyHashing(from source: URL, to destination: URL) throws -> (Int64, String) {
        var coordinationError: NSError?
        var result: Result<(Int64, String), any Error> = .failure(FileCoreError.permissionDenied("could not read \(source.lastPathComponent)"))
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
            result = Result {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw FileCoreError.permissionDenied("could not create transfer storage")
                }
                let input = try FileHandle(forReadingFrom: readURL)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                let hasher = SHA256Stream()
                var total: Int64 = 0
                while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                    hasher.update(chunk)
                    try output.write(contentsOf: chunk)
                    total += Int64(chunk.count)
                }
                try output.synchronize()
                return (total, hasher.finalizeHex())
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Manifest paths use NFC (precomposed) Unicode, the convention of
    /// Windows and Samba servers; Apple file APIs often return decomposed names.
    static func relativePath(of url: URL, base: String) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return url.lastPathComponent.precomposedStringWithCanonicalMapping }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping
    }

    private func withAccess<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
