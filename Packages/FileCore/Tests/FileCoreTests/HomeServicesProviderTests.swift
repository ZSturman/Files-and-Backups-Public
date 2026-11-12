import FileCore
import Foundation
import XCTest

/// A stub of the draft Home Services v1 contract, served through URLProtocol.
final class StubHomeServices: @unchecked Sendable {
    static var current: StubHomeServices?

    var token = "test-token"
    var apiVersion = "1"  // the Home-Services-Contract major the stub accepts
    var contractVersion = "1.1"
    var entryRequests = 0
    var restorePolls = 0
    var capabilities: [String: Bool] = ["files": true, "transfers": true, "trash": true, "capacity": true, "backups": true]
    var files: [String: Data] = [:]
    var directories: Set<String> = [""]
    var trash: [String] = []
    var sessions: [String: (key: String, path: String, size: Int, sha256: String?, data: Data, published: String?)] = [:]
    var failNextChunk = false
    let lock = NSLock()

    func handle(_ request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        func respond(_ status: Int, _ object: Any) -> (Int, Data) { (status, try! JSONSerialization.data(withJSONObject: object)) }
        func fail(_ status: Int, _ code: String, _ details: [String: Any] = [:]) -> (Int, Data) {
            respond(status, ["error": ["code": code, "message": code, "details": details]])
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { return fail(401, "unauthenticated") }
        guard request.value(forHTTPHeaderField: "Home-Services-Contract") == apiVersion else {
            return fail(400, "contract_version_unsupported", ["supported_majors": [1]])
        }
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let route = url.path.replacingOccurrences(of: "/api/v1/", with: "")
        let body = request.httpBody ?? request.httpBodyStream.map(readAll) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
        func exists(_ path: String) -> Bool { files[path] != nil || directories.contains(path) }
        func entry(_ path: String) -> [String: Any] {
            ["name": String(path.split(separator: "/").last ?? ""), "path": path, "kind": directories.contains(path) ? "directory" : "file",
             "size": directories.contains(path) ? NSNull() : (files[path]?.count ?? 0) as Any, "modified_at": "2026-10-20T14:50:20.724198Z"]
        }
        func available(_ on: Bool) -> [String: Any] { on ? ["state": "available"] : ["state": "unavailable", "reason": "disabled on stub"] }

        switch (request.httpMethod ?? "GET", route) {
        case ("GET", "bootstrap"):
            return respond(200, ["contract": ["supported_majors": [1], "version": contractVersion], "server_id": "srv_stub",
                                 "roots": [["role": "files", "writable": true], ["role": "restic_repository", "writable": false]]])
        case ("GET", "capabilities"):
            return respond(200, ["capabilities": [
                "storage": ["browse": available(capabilities["files"]!), "download": available(capabilities["files"]!),
                            "create_directory": available(capabilities["files"]!), "move": available(capabilities["files"]!),
                            "managed_trash": available(capabilities["trash"]!), "capacity": available(capabilities["capacity"]!),
                            "permanent_delete": ["state": "unavailable", "reason": "not offered; managed Trash purges after the retention window"]],
                "transfers": ["resumable_upload": available(capabilities["transfers"]!)],
                "backups": ["snapshots": available(capabilities["backups"]!)],
            ]])
        case ("GET", "storage/files/entries"):
            let dir = query["path"] ?? ""
            guard directories.contains(dir) else { return fail(404, "not_found") }
            let children = (Array(files.keys) + Array(directories)).filter { !$0.isEmpty && parent($0) == dir }.sorted()
            // Two pages to exercise the cursor.
            let page = query["cursor"] == nil ? Array(children.prefix(2)) : Array(children.dropFirst(2))
            let next: Any = query["cursor"] == nil && children.count > 2 ? "c2" : NSNull()
            return respond(200, ["entries": page.map(entry), "next_cursor": next, "path": dir, "root": "files"])
        case ("GET", "storage/files/entry") where contractVersion != "1.0":
            entryRequests += 1
            let path = query["path"] ?? ""
            guard exists(path) else { return fail(404, "not_found", ["path": path]) }
            return respond(200, entry(path))
        case ("POST", "storage/files/directories"):
            let path = json["path"] as! String
            if exists(path) { return fail(409, "destination_exists", ["path": path]) }
            guard directories.contains(parent(path)) else { return fail(404, "not_found") }
            directories.insert(path)
            return respond(201, entry(path))
        case ("POST", "storage/files/move"):
            let from = json["from"] as! String, to = json["to"] as! String
            guard files[from] != nil else { return fail(404, "not_found") }
            if exists(to) { return fail(409, "destination_exists", ["path": to]) }
            files[to] = files.removeValue(forKey: from)
            return respond(200, entry(to))
        case ("POST", "storage/files/trash"):
            let path = json["path"] as! String
            guard files.removeValue(forKey: path) != nil else { return fail(404, "not_found") }
            trash.append(path)
            return respond(201, ["id": "trs_1", "original_path": path])
        case ("GET", "storage/capacity"):
            return respond(200, ["total_bytes": 1000, "available_for_uploads_bytes": 400, "free_bytes": 410])
        case ("GET", "storage/files/content"):
            guard let data = files[query["path"] ?? ""] else { return fail(404, "not_found") }
            if let range = request.value(forHTTPHeaderField: "Range")?.replacingOccurrences(of: "bytes=", with: "").split(separator: "-"),
               let start = Int(range[0]), let end = Int(range[1]) {
                return (206, data.subdata(in: min(start, data.count)..<min(end + 1, data.count)))
            }
            return (200, data)
        case ("POST", "transfers/uploads"):
            let path = json["path"] as! String
            guard directories.contains(parent(path)) else { return fail(404, "not_found") }
            let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? UUID().uuidString
            if let existing = sessions.first(where: { $0.value.key == key }) {
                return respond(200, ["id": existing.key, "offset": existing.value.data.count, "state": "open"])
            }
            let id = "upl_\(sessions.count + 1)"
            sessions[id] = (key, path, json["size"] as! Int, json["sha256"] as? String, Data(), nil)
            return respond(201, ["id": id, "offset": 0, "state": "open"])
        case ("GET", let r) where r.hasPrefix("transfers/uploads/"):
            let id = String(r.dropFirst("transfers/uploads/".count))
            guard let session = sessions[id] else { return fail(404, "not_found") }
            if let done = session.published { return respond(200, ["id": id, "state": "published", "published_path": done, "offset": session.size]) }
            return respond(200, ["id": id, "state": "open", "offset": session.data.count])
        case ("PUT", let r) where r.hasSuffix("/content"):
            let id = String(r.split(separator: "/")[2])
            guard var session = sessions[id] else { return fail(404, "not_found") }
            if failNextChunk {
                failNextChunk = false
                return fail(503, "volume_unavailable", ["state": "missing"])
            }
            guard Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") == session.data.count else {
                return fail(409, "offset_mismatch", ["expected_offset": session.data.count])
            }
            session.data.append(body)
            sessions[id] = session
            return respond(200, ["id": id, "offset": session.data.count, "state": "open"])
        case ("POST", let r) where r.hasSuffix("/complete"):
            let id = String(r.split(separator: "/")[2])
            guard var session = sessions[id] else { return fail(404, "not_found") }
            guard session.data.count == session.size else { return fail(409, "size_mismatch") }
            if let sha = session.sha256, SHA256Stream.hex(of: session.data) != sha { return fail(409, "checksum_mismatch") }
            var attempt = 0
            var path = session.path
            while exists(path) {
                attempt += 1
                let name = String(session.path.split(separator: "/").last!)
                let dot = name.lastIndex(of: ".")
                let renamed = dot.map { "\(name[..<$0]) (\(attempt))\(name[$0...])" } ?? "\(name) (\(attempt))"
                path = parent(session.path).isEmpty ? renamed : "\(parent(session.path))/\(renamed)"
            }
            files[path] = session.data
            session.published = path
            sessions[id] = session
            return respond(200, ["id": id, "state": "published", "published_path": path, "verification": ["sha256": session.sha256 == nil ? "computed_by_server" : "matched", "size": "matched"]])
        case ("DELETE", let r) where r.hasPrefix("transfers/uploads/"):
            sessions[String(r.dropFirst("transfers/uploads/".count))] = nil
            return respond(200, [:])
        case ("GET", "storage/files/trash"):
            return respond(200, ["items": trash.enumerated().map { ["id": "trs_\($0.offset)", "kind": "file", "original_path": $0.element, "size": 1,
                                                                   "deleted_at": "2026-10-20T08:00:00Z", "purge_after": "2026-10-27T08:00:00Z"] }, "retention_days": 7])
        case ("POST", let r) where r.hasPrefix("storage/files/trash/") && r.hasSuffix("/restore"):
            let index = Int(r.split(separator: "/")[3].replacingOccurrences(of: "trs_", with: "")) ?? -1
            guard trash.indices.contains(index) else { return fail(404, "not_found") }
            let path = trash.remove(at: index)
            let target = exists(path) ? path.replacingOccurrences(of: ".txt", with: " (1).txt") : path
            files[target] = Data("a".utf8)
            return respond(200, ["restored_path": target, "renamed": target != path])
        case ("GET", let r) where r.hasPrefix("backups/snapshots/") && r.hasSuffix("/entries"):
            return respond(200, ["entries": [["name": "Projects", "path": "/Users/x/Workspace/Projects", "kind": "directory", "size": NSNull()],
                                             ["name": "a.txt", "path": "/Users/x/Workspace/a.txt", "kind": "file", "size": 5]]])
        case ("POST", "backups/restores"):
            guard request.value(forHTTPHeaderField: "Idempotency-Key") != nil else { return fail(400, "idempotency_key_required") }
            return respond(201, ["id": "job_1", "state": "waiting", "kind": "backup.restore"])
        case ("GET", "jobs/job_1"):
            restorePolls += 1
            if restorePolls < 2 { return respond(200, ["id": "job_1", "state": "running", "result": NSNull(), "error": NSNull()]) }
            return respond(200, ["id": "job_1", "state": "succeeded", "error": NSNull(),
                                 "result": ["destination": ["path": "Restores/job_1", "root": "files"], "summary": ["files_restored": 3]]])
        case ("GET", "backups/snapshots"):
            return respond(200, ["snapshots": [["id": "4515c748", "time": "2026-09-09T03:14:15.123456-07:00", "tags": ["mac-workspace"], "paths": ["/Users/x/Workspace"], "hostname": "mac"]]])
        case ("GET", "backups/protection"):
            return respond(200, ["groups": [["hostname": "mac", "paths": ["/Users/x/Workspace"], "tags": ["mac-workspace"], "snapshot_count": 1,
                                             "protection": ["state": "overdue", "last_success_at": "2026-09-09T03:14:15.123456-07:00"]]]])
        default:
            return fail(404, "not_found")
        }
    }

    private func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = StubHomeServices.current!.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HomeServicesProviderTests: XCTestCase {
    private var server: StubHomeServices!
    private var session: URLSession!

    override func setUp() {
        server = StubHomeServices()
        StubHomeServices.current = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func provider(token: String = "test-token") throws -> HomeServicesProvider {
        try HomeServicesProvider(baseURL: URL(string: "https://host.example.net")!, token: token, session: session)
    }

    func testRequiresHTTPS() {
        XCTAssertThrowsError(try HomeServicesProvider(baseURL: URL(string: "http://home.local")!, token: "x"))
    }

    func testCapabilitiesComeFromServerAndVersionIsChecked() async throws {
        server.capabilities["backups"] = false
        let provider = try provider()
        try await provider.connect()
        XCTAssertTrue(provider.capabilities.restorableTrash.isSupported)
        XCTAssertFalse(provider.capabilities.versionedBackups.isSupported)
        XCTAssertFalse(provider.capabilities.permanentDelete.isSupported)

        server.apiVersion = "2"
        do {
            try await provider.connect()
            XCTFail("contract mismatch must fail")
        } catch FileCoreError.unsupported {}
    }

    func testBadTokenIsAuthenticationFailure() async throws {
        do {
            try await provider(token: "wrong").connect()
            XCTFail("must fail")
        } catch FileCoreError.authenticationFailed {}
    }

    func testQueueUploadsThroughManagedSessionsWithServerVerification() async throws {
        server.files["Trip/notes.txt"] = Data("existing".utf8)
        server.directories.insert("Trip")
        server.failNextChunk = true // one transient server error mid-upload
        let provider = try provider()
        let harness = try QueueHarness(provider: provider)
        let (folder, files) = try makeNestedFixture(in: harness.temp)
        let queue = await harness.makeQueue()
        let job = try harness.folderJob(folder, verify: false)
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let finishedJob = await queue.job(job.id)
        let finished = try XCTUnwrap(finishedJob)
        XCTAssertEqual(finished.state, .complete, finished.failureReason ?? "")
        XCTAssertEqual(finished.resolvedRootName, "Trip (2)", "the app picks a free folder name before uploading")
        XCTAssertEqual(finished.verificationSummary, .serverSHA256)
        for (path, data) in files {
            XCTAssertEqual(server.files[path.replacingOccurrences(of: "Trip/", with: "Trip (2)/")], data, path)
        }
        XCTAssertEqual(server.files["Trip/notes.txt"], Data("existing".utf8))
    }

    func testDeleteGoesToManagedTrashAndSnapshotsAreListed() async throws {
        server.files["a.txt"] = Data("a".utf8)
        let provider = try provider()
        try await provider.connect()
        try await provider.delete(RemotePath("a.txt"))
        XCTAssertEqual(server.trash, ["a.txt"])
        let snapshots = try await provider.snapshots()
        XCTAssertEqual(snapshots.first?.source, "mac-workspace — /Users/x/Workspace")
        let protection = try await provider.protection()
        XCTAssertEqual(protection.first?.state, "overdue")
        let listing = try await provider.list(.root)
        XCTAssertEqual(listing.count, 0)
        let capacity = try await provider.capacity()
        XCTAssertEqual(capacity, StorageCapacity(totalBytes: 1000, availableBytes: 400))
    }

    func testSingleEntryRouteOnContract11AndListingFallbackOn10() async throws {
        server.directories.insert("Docs")
        server.files["Docs/a.txt"] = Data("a".utf8)
        let modern = try provider()
        try await modern.connect()
        let found = try await modern.item(at: RemotePath("Docs/a.txt"))
        XCTAssertEqual(found?.size, 1)
        let missing = try await modern.item(at: RemotePath("Docs/nope.txt"))
        XCTAssertNil(missing)
        XCTAssertEqual(server.entryRequests, 2)

        server.contractVersion = "1.0"
        let legacy = try provider()
        try await legacy.connect()
        let viaListing = try await legacy.item(at: RemotePath("Docs/a.txt"))
        XCTAssertEqual(viaListing?.size, 1)
        XCTAssertEqual(server.entryRequests, 2, "1.0 servers are not asked for the 1.1 route")
    }

    func testTrashRestoreSnapshotBrowseAndRestoreJob() async throws {
        server.directories.insert("Docs")
        server.files["Docs/a.txt"] = Data("a".utf8)
        let provider = try provider()
        try await provider.connect()
        try await provider.delete(RemotePath("Docs/a.txt"))
        let trash = try await provider.trashItems()
        XCTAssertEqual(trash.map(\.originalPath), [try RemotePath("Docs/a.txt")])
        let restored = try await provider.restoreFromTrash(trash[0].id)
        XCTAssertEqual(restored, try RemotePath("Docs/a.txt"))
        let empty = try await provider.trashItems()
        XCTAssertTrue(empty.isEmpty)

        let entries = try await provider.snapshotEntries("4515c748", path: "/Users/x/Workspace")
        XCTAssertEqual(entries.map(\.name), ["Projects", "a.txt"])
        XCTAssertTrue(entries[0].isDirectory)
        let jobID = try await provider.startRestore(snapshotID: "4515c748", include: ["/Users/x/Workspace/a.txt"], idempotencyKey: "k1")
        var status = try await provider.restoreJob(jobID)
        XCTAssertFalse(status.isFinished)
        status = try await provider.restoreJob(jobID)
        XCTAssertEqual(status.state, "succeeded")
        XCTAssertEqual(status.destination, "Restores/job_1")
        XCTAssertEqual(status.filesRestored, 3)
        await XCTAssertThrowsErrorAsync { try await provider.snapshotEntries("4515c748", path: "relative/path") }
    }
}

func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
