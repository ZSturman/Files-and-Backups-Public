import Foundation

/// Uploads into a hidden temp file named for this transfer item, verifies it,
/// then renames it to a non-colliding final name in the same directory.
///
/// Resume rule: an earlier partial file is reused only when it carries this
/// item's ID in its name, is at least as long as the persisted offset, and its
/// final (up to 1 MiB) bytes before that offset match the source. Otherwise it
/// is removed and the file restarts from zero. Final verification still runs.
public final class TempFileUploadSink: UploadSink, @unchecked Sendable {
    public static let tempPrefix = ".fbpart-"
    static let resumeCheckWindow = 1 << 20
    static let readChunk = 4 << 20

    private let provider: any ByteStorageProvider
    private let request: UploadRequest
    private let tempPath: RemotePath
    public let state: UploadSinkState
    public var resumeToken: String { tempPath.string }

    public static func tempName(for itemID: UUID) -> String {
        tempPrefix + itemID.uuidString.lowercased()
    }

    private init(provider: any ByteStorageProvider, request: UploadRequest, tempPath: RemotePath, state: UploadSinkState) {
        self.provider = provider
        self.request = request
        self.tempPath = tempPath
        self.state = state
    }

    static func make(provider: any ByteStorageProvider, request: UploadRequest) async throws -> TempFileUploadSink {
        let tempPath = try request.directory.appending(tempName(for: request.itemID))
        let existing = try await provider.item(at: tempPath)

        if existing == nil, let result = try await recoveredCommit(provider: provider, request: request) {
            return TempFileUploadSink(provider: provider, request: request, tempPath: tempPath, state: .alreadyCommitted(result))
        }

        guard let existing else {
            return TempFileUploadSink(provider: provider, request: request, tempPath: tempPath, state: .upload(fromOffset: 0, resumed: false))
        }
        if existing.isDirectory {
            throw FileCoreError.alreadyExists(tempPath)
        }

        let offset = request.committedOffset
        if offset > 0, offset <= request.size, let size = existing.size, size >= offset,
           try await tailMatches(provider: provider, tempPath: tempPath, request: request, offset: offset) {
            return TempFileUploadSink(provider: provider, request: request, tempPath: tempPath, state: .upload(fromOffset: offset, resumed: true))
        }

        // The partial is ours by name but cannot be trusted; restart safely.
        try await provider.delete(tempPath)
        return TempFileUploadSink(provider: provider, request: request, tempPath: tempPath, state: .upload(fromOffset: 0, resumed: false))
    }

    /// A commit may have happened without being recorded (crash or lost
    /// connection between rename and persistence).
    static func recoveredCommit(provider: any StorageProvider, request: UploadRequest) async throws -> UploadResult? {
        guard let candidate = request.commitCandidate, candidate.parent == request.directory,
              let committed = try await provider.item(at: candidate), !committed.isDirectory,
              committed.size == request.size else { return nil }
        return UploadResult(finalPath: candidate, verification: .size)
    }

    private static func tailMatches(provider: any ByteStorageProvider, tempPath: RemotePath, request: UploadRequest, offset: Int64) async throws -> Bool {
        let length = Int(min(Int64(resumeCheckWindow), offset))
        let start = offset - Int64(length)
        let remote = try await provider.read(tempPath, offset: start, length: length)
        let local = try request.readSource(start, length)
        return remote == local
    }

    public func append(_ data: Data, at offset: Int64) async throws {
        try await provider.writeChunk(data, to: tempPath, at: offset)
    }

    public func finish(verifyContents: Bool, willCommit: @escaping @Sendable (RemotePath) async -> Void) async throws -> UploadResult {
        if case .alreadyCommitted(let result) = state { return result }
        return try await Self.publish(provider: provider, tempPath: tempPath, request: request, verifyContents: verifyContents, willCommit: willCommit)
    }

    /// Checks size (and optionally SHA-256 by reading back), then renames the
    /// temp file to the first free keep-both name. Shared by all temp-file
    /// providers.
    static func publish(
        provider: any StorageProvider, tempPath: RemotePath, request: UploadRequest, verifyContents: Bool,
        willCommit: @escaping @Sendable (RemotePath) async -> Void
    ) async throws -> UploadResult {
        guard let written = try await provider.item(at: tempPath) else {
            throw FileCoreError.verificationFailed("the uploaded data disappeared before it was published")
        }
        guard written.size == request.size else {
            throw FileCoreError.verificationFailed("destination has \(written.size ?? -1) bytes, expected \(request.size)")
        }

        var level = VerificationLevel.size
        if verifyContents {
            guard let expected = request.sha256 else {
                throw FileCoreError.verificationFailed("no source checksum is available for read-back verification")
            }
            let hasher = SHA256Stream()
            var offset: Int64 = 0
            while offset < request.size {
                try Task.checkCancellation()
                let length = Int(min(Int64(readChunk), request.size - offset))
                let data = try await provider.read(tempPath, offset: offset, length: length)
                guard !data.isEmpty else { break }
                hasher.update(data)
                offset += Int64(data.count)
            }
            guard offset == request.size, hasher.finalizeHex() == expected else {
                throw FileCoreError.verificationFailed("SHA-256 of the uploaded file does not match the source")
            }
            level = .sha256Readback
        }

        // Keep-both: never overwrite. A concurrent writer that wins the race
        // makes the rename fail, and the next candidate is tried.
        for attempt in 1...999 {
            let candidate = try request.directory.appending(CollisionNaming.candidate(for: request.preferredName, attempt: attempt))
            if try await provider.item(at: candidate) != nil { continue }
            await willCommit(candidate)
            do {
                try await provider.move(tempPath, to: candidate)
                return UploadResult(finalPath: candidate, verification: level)
            } catch FileCoreError.alreadyExists {
                continue
            }
        }
        throw FileCoreError.alreadyExists(try request.directory.appending(request.preferredName))
    }

    public func abort() async {
        try? await provider.delete(tempPath)
    }
}
