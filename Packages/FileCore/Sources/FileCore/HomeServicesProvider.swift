import Foundation

/// Optional Home Services provider, contract v1 (Home Services repository:
/// `contracts/v1/openapi.json`, `docs/API.md`). HTTPS with a scoped bearer
/// token and the `Home-Services-Contract: 1` header.
///
/// Files live in the server's `files` root. Uploads use resumable sessions
/// (idempotent create, `Upload-Offset` chunks, server-side size + SHA-256
/// verification, keep-both publication). Deletes go to the managed 7-day
/// Trash; the server offers no permanent delete.
public final class HomeServicesProvider: StorageProvider, @unchecked Sendable {
    public static let contractMajor = "1"
    static let maxChunk = 16 << 20

    struct ServerCapabilities: Sendable {
        var browse = false, download = false, createDirectory = false, move = false
        var trash = false, capacity = false, uploads = false, snapshots = false
        /// Contract 1.1 added `GET storage/files/entry`.
        var entryRoute = false
        var reasons: [String: String] = [:]
    }

    public struct APIError: Error, Sendable {
        public var status: Int
        public var code: String
        public var message: String
        public var details: [String: String]
    }

    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let root: RemotePath
    private var server = ServerCapabilities()
    private let lock = NSLock()
    public private(set) var serverID: String?

    public init(baseURL: URL, token: String, root: RemotePath = .root, session: URLSession = .shared) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw FileCoreError.invalidConfiguration("Home Services requires an https:// URL")
        }
        self.baseURL = baseURL
        self.token = token
        self.root = root
        self.session = session
    }

    public var capabilities: ProviderCapabilities {
        let server = lock.withLock { self.server }
        func support(_ available: Bool, _ key: String) -> CapabilitySupport {
            available ? .supported : .unsupported(server.reasons[key] ?? "not available on this server")
        }
        return ProviderCapabilities(
            browse: support(server.browse, "browse"), download: support(server.download, "download"),
            upload: support(server.uploads, "resumable_upload"), createFolder: support(server.createDirectory, "create_directory"),
            rename: support(server.move, "move"),
            permanentDelete: .unsupported(server.reasons["permanent_delete"] ?? "deletes move items to the managed Trash"),
            restorableTrash: support(server.trash, "managed_trash"), capacity: support(server.capacity, "capacity"),
            resumableUpload: support(server.uploads, "resumable_upload"), bestVerification: .serverSHA256,
            backgroundTransfers: .unsupported("transfers currently run while the app is open"),
            versionedBackups: support(server.snapshots, "snapshots")
        )
    }

    // MARK: HTTP

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    @discardableResult
    private func request(
        _ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil,
        body: Data? = nil, headers: [String: String] = [:], accept: Set<Int> = [200, 201]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contractMajor, forHTTPHeaderField: "Home-Services-Contract")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw FileCoreError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FileCoreError.protocolError("not an HTTP response") }
        if accept.contains(http.statusCode) { return (data, http) }
        throw Self.apiError(status: http.statusCode, data: data)
    }

    static func apiError(status: Int, data: Data) -> APIError {
        let envelope = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let details = (envelope?["details"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        return APIError(status: status, code: envelope?["code"] as? String ?? "http_\(status)",
                        message: envelope?["message"] as? String ?? "HTTP \(status)", details: details)
    }

    /// Maps a server error to the app's error model.
    static func map(_ error: APIError, path: RemotePath) -> FileCoreError {
        switch (error.status, error.code) {
        case (401, _): return .authenticationFailed
        case (_, "contract_version_unsupported"): return .unsupported("this Home Services version (\(error.message))")
        case (_, "capability_unavailable"): return .unsupported(error.details["reason"] ?? error.message)
        case (403, _): return .permissionDenied(error.details["required_scope"].map { "the token lacks scope \($0)" } ?? error.message)
        case (404, _): return .notFound(path)
        case (409, "destination_exists"): return .alreadyExists(path)
        case (409, "checksum_mismatch"): return .verificationFailed("the server's SHA-256 did not match the source; nothing was published")
        case (409, "offset_mismatch"): return .protocolError("upload offset changed on the server (expected \(error.details["expected_offset"] ?? "?"))")
        case (507, _), (413, "size_exceeded"): return .insufficientSpace
        case (503, "volume_unavailable"): return .unreachable("Home Services storage is unavailable (\(error.details["state"] ?? "unknown")); the disk may be disconnected")
        case (500..<600, _): return .protocolError(error.message)
        default: return .protocolError("\(error.code): \(error.message)")
        }
    }

    private func call<T>(_ path: RemotePath, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as APIError {
            throw Self.map(error, path: path)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileCoreError.protocolError("malformed response")
        }
        return object
    }

    private func serverPath(_ path: RemotePath) -> String { root.appending(path).string }

    private func relative(_ serverPath: String) throws -> RemotePath {
        let path = try RemotePath(serverPath)
        guard path.isWithin(root) else { throw FileCoreError.protocolError("server returned a path outside this connection") }
        return try RemotePath(components: Array(path.components.dropFirst(root.components.count)))
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    // MARK: StorageProvider

    public func connect() async throws {
        let (bootData, _) = try await call(.root) { try await request("GET", "bootstrap") }
        let bootstrap = try object(bootData)
        let majors = ((bootstrap["contract"] as? [String: Any])?["supported_majors"] as? [Any])?.map { "\($0)" } ?? []
        guard majors.contains(Self.contractMajor) else {
            throw FileCoreError.unsupported("Home Services contract \(majors.joined(separator: ", ")); this app supports \(Self.contractMajor)")
        }
        let version = (bootstrap["contract"] as? [String: Any])?["version"] as? String ?? "1.0"
        let minor = Int(version.split(separator: ".").dropFirst().first ?? "0") ?? 0
        let roots = bootstrap["roots"] as? [[String: Any]] ?? []
        guard roots.contains(where: { $0["role"] as? String == "files" }) else {
            throw FileCoreError.unsupported("this server has no files root")
        }
        let (capData, _) = try await call(.root) { try await request("GET", "capabilities") }
        let all = try object(capData)["capabilities"] as? [String: Any] ?? [:]
        var parsed = ServerCapabilities()
        func state(_ group: String, _ key: String) -> Bool {
            guard let entry = (all[group] as? [String: Any])?[key] as? [String: Any] else {
                parsed.reasons[key] = "not reported by this server"
                return false
            }
            if let reason = entry["reason"] as? String { parsed.reasons[key] = reason }
            return entry["state"] as? String == "available"
        }
        parsed.browse = state("storage", "browse")
        parsed.download = state("storage", "download")
        parsed.createDirectory = state("storage", "create_directory")
        parsed.move = state("storage", "move")
        parsed.trash = state("storage", "managed_trash")
        parsed.capacity = state("storage", "capacity")
        _ = state("storage", "permanent_delete")
        parsed.uploads = state("transfers", "resumable_upload")
        parsed.snapshots = state("backups", "snapshots")
        parsed.entryRoute = minor >= 1
        lock.withLock {
            server = parsed
            serverID = bootstrap["server_id"] as? String
        }
        if !root.isRoot {
            guard let rootItem = try await item(at: .root), rootItem.isDirectory else { throw FileCoreError.notFound(root) }
        }
    }

    public func disconnect() async {}

    private func entries(_ directory: RemotePath) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var cursor: String?
        repeat {
            var query = ["path": serverPath(directory), "limit": "500"]
            if let cursor { query["cursor"] = cursor }
            let (data, _) = try await call(directory) { try await request("GET", "storage/files/entries", query: query) }
            let page = try object(data)
            all += page["entries"] as? [[String: Any]] ?? []
            cursor = page["next_cursor"] as? String
        } while cursor != nil
        return all
    }

    private func item(_ entry: [String: Any]) -> RemoteItem? {
        guard let path = (entry["path"] as? String).flatMap({ try? relative($0) }) else { return nil }
        let isDirectory = entry["kind"] as? String == "directory"
        return RemoteItem(path: path, isDirectory: isDirectory, size: isDirectory ? nil : (entry["size"] as? NSNumber)?.int64Value,
                          modified: Self.date(entry["modified_at"]))
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        try await entries(directory).compactMap(item)
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    /// Uses `GET storage/files/entry` (contract 1.1+); 1.0 servers have no
    /// single-item route, so the name is looked up in its parent listing.
    public func item(at path: RemotePath) async throws -> RemoteItem? {
        guard let parent = path.parent else { return RemoteItem(path: path, isDirectory: true, size: nil, modified: nil) }
        if lock.withLock({ server.entryRoute }) {
            do {
                let (data, _) = try await request("GET", "storage/files/entry", query: ["path": serverPath(path)])
                return item(try object(data))
            } catch let error as APIError where error.status == 404 {
                return nil
            } catch let error as APIError {
                throw Self.map(error, path: path)
            }
        }
        do {
            return try await list(parent).first { $0.name == path.name }
        } catch FileCoreError.notFound {
            return nil
        }
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try await call(path) { _ = try await request("POST", "storage/files/directories", json: ["path": serverPath(path)]) }
    }

    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        do {
            _ = try await request("POST", "storage/files/move", json: ["from": serverPath(source), "to": serverPath(destination), "conflict": "fail"])
        } catch let error as APIError {
            throw Self.map(error, path: error.code == "destination_exists" ? destination : source)
        }
    }

    /// Moves the item to the managed Trash (restorable for 7 days).
    public func delete(_ path: RemotePath) async throws {
        guard !path.isRoot else { throw FileCoreError.permissionDenied("the connection root cannot be deleted") }
        try await call(path) { _ = try await request("POST", "storage/files/trash", json: ["path": serverPath(path)]) }
    }

    public func capacity() async throws -> StorageCapacity? {
        guard lock.withLock({ server.capacity }) else { return nil }
        let (data, _) = try await call(.root) { try await request("GET", "storage/capacity") }
        let object = try object(data)
        guard let total = (object["total_bytes"] as? NSNumber)?.int64Value,
              let available = ((object["available_for_uploads_bytes"] ?? object["free_bytes"]) as? NSNumber)?.int64Value else { return nil }
        return StorageCapacity(totalBytes: total, availableBytes: available)
    }

    public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let (data, response) = try await call(path) {
            try await request("GET", "storage/files/content", query: ["path": serverPath(path)],
                              headers: ["Range": "bytes=\(offset)-\(offset + Int64(length) - 1)"], accept: [200, 206, 416])
        }
        if response.statusCode == 416 { return Data() }
        if response.statusCode == 200 {
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(start + length, data.count))
        }
        return data
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url("storage/files/content", query: ["path": serverPath(path)]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contractMajor, forHTTPHeaderField: "Home-Services-Contract")
        let (temp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw FileCoreError.protocolError("not an HTTP response") }
        guard http.statusCode == 200 else {
            throw Self.map(Self.apiError(status: http.statusCode, data: (try? Data(contentsOf: temp)) ?? Data()), path: path)
        }
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: temp, to: localURL)
        progress(Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    // MARK: Resumable uploads

    public func makeUploadSink(for request: UploadRequest) async throws -> any UploadSink {
        guard lock.withLock({ server.uploads }) else { throw FileCoreError.unsupported(lock.withLock { server.reasons["resumable_upload"] } ?? "resumable uploads") }
        if let sessionID = request.resumeToken, Self.isSessionID(sessionID) {
            do {
                let (data, _) = try await self.request("GET", "transfers/uploads/\(sessionID)")
                let state = try object(data)
                switch state["state"] as? String {
                case "published":
                    if let published = state["published_path"] as? String {
                        return HomeServicesUploadSink(provider: self, sessionID: sessionID, state: .alreadyCommitted(
                            UploadResult(finalPath: try relative(published), verification: .serverSHA256)))
                    }
                case "open":
                    let offset = (state["offset"] as? NSNumber)?.int64Value ?? 0
                    return HomeServicesUploadSink(provider: self, sessionID: sessionID, state: .upload(fromOffset: offset, resumed: offset > 0))
                default:
                    break // abandoned or cancelled: start a new session
                }
            } catch let error as APIError where error.status == 404 {
                // Session expired server-side: start a new one.
            } catch let error as APIError {
                throw Self.map(error, path: request.directory)
            }
        }
        let target = try request.directory.appending(request.preferredName)
        var body: [String: Any] = ["root": "files", "path": serverPath(target), "size": request.size, "conflict": "keep_both"]
        if let sha = request.sha256 { body["sha256"] = sha }
        // One key per attempt: a replay of an abandoned session must not be reused.
        let key = "\(request.itemID.uuidString.lowercased())-\(request.resumeToken == nil ? "1" : UUID().uuidString.prefix(8).lowercased())"
        let (data, _) = try await call(request.directory) {
            try await self.request("POST", "transfers/uploads", json: body, headers: ["Idempotency-Key": key])
        }
        let created = try object(data)
        guard let sessionID = created["id"] as? String, Self.isSessionID(sessionID) else {
            throw FileCoreError.protocolError("missing upload session")
        }
        let offset = (created["offset"] as? NSNumber)?.int64Value ?? 0
        return HomeServicesUploadSink(provider: self, sessionID: sessionID, state: .upload(fromOffset: offset, resumed: offset > 0))
    }

    static func isSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    public func discardUpload(resumeToken: String) async {
        guard Self.isSessionID(resumeToken) else { return }
        _ = try? await request("DELETE", "transfers/uploads/\(resumeToken)", accept: [200, 202, 204, 404])
    }

    fileprivate func sendChunk(_ sessionID: String, data: Data, offset: Int64) async throws {
        var sent = 0
        repeat {
            let end = min(sent + Self.maxChunk, data.count)
            let slice = data.subdata(in: sent..<end)
            try await call(.root) {
                _ = try await request("PUT", "transfers/uploads/\(sessionID)/content", body: slice,
                                      headers: ["Upload-Offset": "\(offset + Int64(sent))"])
            }
            sent = end
        } while sent < data.count
    }

    fileprivate func complete(_ sessionID: String, directory: RemotePath) async throws -> UploadResult {
        let (data, _) = try await call(directory) {
            try await request("POST", "transfers/uploads/\(sessionID)/complete", json: ["create_parents": false])
        }
        let object = try object(data)
        guard let published = object["published_path"] as? String else { throw FileCoreError.protocolError("missing published path") }
        let verification = (object["verification"] as? [String: Any])?["sha256"] as? String
        return UploadResult(finalPath: try relative(published), verification: verification == "matched" ? .serverSHA256 : .size)
    }

    // MARK: Backups (read-only on mobile)

    public func snapshots() async throws -> [BackupSnapshotSummary] {
        guard lock.withLock({ server.snapshots }) else { throw FileCoreError.unsupported("backup history") }
        let (data, _) = try await call(.root) { try await request("GET", "backups/snapshots") }
        let entries = try object(data)["snapshots"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, let time = Self.date(entry["time"]) else { return nil }
            let tags = (entry["tags"] as? [String] ?? []).joined(separator: ", ")
            let paths = (entry["paths"] as? [String] ?? []).joined(separator: ", ")
            return BackupSnapshotSummary(id: id, time: time, source: tags.isEmpty ? paths : "\(tags) — \(paths)", host: entry["hostname"] as? String ?? "",
                                         paths: entry["paths"] as? [String] ?? [])
        }
    }

    // MARK: Managed Trash

    /// Trash items inside this connection's root.
    public func trashItems() async throws -> [TrashItem] {
        let (data, _) = try await call(.root) { try await request("GET", "storage/files/trash") }
        let items = try object(data)["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String, Self.isSessionID(id),
                  let original = (item["original_path"] as? String).flatMap({ try? relative($0) }) else { return nil }
            return TrashItem(id: id, originalPath: original, isDirectory: item["kind"] as? String == "directory",
                             size: (item["size"] as? NSNumber)?.int64Value, deletedAt: Self.date(item["deleted_at"]),
                             purgeAfter: Self.date(item["purge_after"]))
        }
        .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Restores with keep-both naming; returns where the item now lives.
    public func restoreFromTrash(_ id: String) async throws -> RemotePath {
        guard Self.isSessionID(id) else { throw FileCoreError.invalidPath(id) }
        let (data, _) = try await call(.root) { try await request("POST", "storage/files/trash/\(id)/restore", json: [:]) }
        guard let restored = try object(data)["restored_path"] as? String else { throw FileCoreError.protocolError("missing restored path") }
        return try relative(restored)
    }

    // MARK: Snapshots and restore jobs

    /// Direct children of an absolute path inside a snapshot.
    public func snapshotEntries(_ snapshotID: String, path: String) async throws -> [SnapshotEntry] {
        guard Self.isSessionID(snapshotID), path.hasPrefix("/") else { throw FileCoreError.invalidPath(path) }
        let (data, _) = try await call(.root) {
            try await request("GET", "backups/snapshots/\(snapshotID)/entries", query: ["path": path])
        }
        let entries = try object(data)["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String, let full = entry["path"] as? String else { return nil }
            let isDirectory = entry["kind"] as? String == "directory"
            return SnapshotEntry(name: name, path: full, isDirectory: isDirectory,
                                 size: isDirectory ? nil : (entry["size"] as? NSNumber)?.int64Value, modified: Self.date(entry["modified_at"]))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    /// Streams one archived file to a local URL.
    public func downloadSnapshotFile(_ snapshotID: String, path: String, to localURL: URL) async throws {
        guard Self.isSessionID(snapshotID), path.hasPrefix("/") else { throw FileCoreError.invalidPath(path) }
        var request = URLRequest(url: url("backups/snapshots/\(snapshotID)/content", query: ["path": path]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contractMajor, forHTTPHeaderField: "Home-Services-Contract")
        let (temp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw FileCoreError.protocolError("not an HTTP response") }
        guard http.statusCode == 200 else {
            throw Self.map(Self.apiError(status: http.statusCode, data: (try? Data(contentsOf: temp)) ?? Data()), path: .root)
        }
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: temp, to: localURL)
    }

    /// Starts a server-side restore into a fresh `files/Restores/<job>` folder.
    public func startRestore(snapshotID: String, include: [String], idempotencyKey: String) async throws -> String {
        let (data, _) = try await call(.root) {
            try await request("POST", "backups/restores", json: ["snapshot_id": snapshotID, "include": include],
                              headers: ["Idempotency-Key": idempotencyKey])
        }
        guard let id = try object(data)["id"] as? String, Self.isSessionID(id) else { throw FileCoreError.protocolError("missing job id") }
        return id
    }

    public func restoreJob(_ id: String) async throws -> RestoreJobStatus {
        guard Self.isSessionID(id) else { throw FileCoreError.invalidPath(id) }
        let (data, _) = try await call(.root) { try await request("GET", "jobs/\(id)") }
        let job = try object(data)
        let result = job["result"] as? [String: Any]
        let destination = (result?["destination"] as? [String: Any])?["path"] as? String
        let summary = result?["summary"] as? [String: Any]
        let errorText = (job["error"] as? [String: Any])?["message"] as? String ?? job["error"] as? String
        return RestoreJobStatus(id: id, state: job["state"] as? String ?? "unknown", destination: destination,
                                filesRestored: (summary?["files_restored"] as? NSNumber)?.intValue, error: errorText)
    }

    /// Protection by source as computed by the server (current/overdue/unknown).
    public func protection() async throws -> [BackupProtectionGroup] {
        let (data, _) = try await call(.root) { try await request("GET", "backups/protection") }
        let groups = try object(data)["groups"] as? [[String: Any]] ?? []
        return groups.map { group in
            let protection = group["protection"] as? [String: Any] ?? [:]
            return BackupProtectionGroup(
                host: group["hostname"] as? String ?? "", paths: group["paths"] as? [String] ?? [], tags: group["tags"] as? [String] ?? [],
                state: protection["state"] as? String ?? "unknown", lastSuccess: Self.date(protection["last_success_at"]),
                snapshotCount: (group["snapshot_count"] as? NSNumber)?.intValue ?? 0
            )
        }
    }
}

public struct BackupSnapshotSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var time: Date
    public var source: String
    public var host: String
    public var paths: [String] = []
}

public struct TrashItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var originalPath: RemotePath
    public var isDirectory: Bool
    public var size: Int64?
    public var deletedAt: Date?
    public var purgeAfter: Date?
}

public struct SnapshotEntry: Identifiable, Hashable, Sendable {
    public var name: String
    /// Absolute path inside the snapshot.
    public var path: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public struct RestoreJobStatus: Hashable, Sendable {
    public var id: String
    /// waiting, running, blocked, succeeded, failed, cancelled, interrupted
    public var state: String
    /// Destination relative to the files root, e.g. "Restores/job_…".
    public var destination: String?
    public var filesRestored: Int?
    public var error: String?
    public var isFinished: Bool { ["succeeded", "failed", "cancelled", "interrupted"].contains(state) }

    public init(id: String, state: String, destination: String? = nil, filesRestored: Int? = nil, error: String? = nil) {
        self.id = id
        self.state = state
        self.destination = destination
        self.filesRestored = filesRestored
        self.error = error
    }
}

public struct BackupProtectionGroup: Hashable, Sendable {
    public var host: String
    public var paths: [String]
    public var tags: [String]
    public var state: String
    public var lastSuccess: Date?
    public var snapshotCount: Int
}

extension HomeServicesProvider.APIError: LocalizedError {
    public var errorDescription: String? { "\(code): \(message)" }
}

final class HomeServicesUploadSink: UploadSink, @unchecked Sendable {
    private let provider: HomeServicesProvider
    private let sessionID: String
    let state: UploadSinkState
    var resumeToken: String { sessionID }

    init(provider: HomeServicesProvider, sessionID: String, state: UploadSinkState) {
        self.provider = provider
        self.sessionID = sessionID
        self.state = state
    }

    func append(_ data: Data, at offset: Int64) async throws {
        try await provider.sendChunk(sessionID, data: data, offset: offset)
    }

    func finish(verifyContents: Bool, willCommit: @escaping @Sendable (RemotePath) async -> Void) async throws -> UploadResult {
        if case .alreadyCommitted(let result) = state { return result }
        return try await provider.complete(sessionID, directory: .root)
    }

    func abort() async {
        await provider.discardUpload(resumeToken: sessionID)
    }
}
