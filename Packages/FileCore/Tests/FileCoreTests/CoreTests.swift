import FileCore
import Foundation
import XCTest

final class RemotePathTests: XCTestCase {
    func testRejectsTraversalAndUnsafeNames() {
        for bad in ["..", "a/../b", "./a", "a/./b", "a\\b", "a\u{0}b", "tab\there", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try RemotePath(bad), bad)
        }
    }

    func testNormalizesSlashesAndKeepsUnicode() throws {
        let path = try RemotePath("//Photos/Café ☕️//2026/")
        XCTAssertEqual(path.components, ["Photos", "Café ☕️", "2026"])
        XCTAssertEqual(path.string, "Photos/Café ☕️/2026")
        XCTAssertEqual(path.parent, try RemotePath("Photos/Café ☕️"))
        XCTAssertTrue(path.isWithin(try RemotePath("Photos")))
        XCTAssertFalse(try RemotePath("Photoshop").isWithin(try RemotePath("Photos")))
    }

    func testCodableRoundTripRevalidates() throws {
        let data = try JSONEncoder().encode([try RemotePath("a/b")])
        XCTAssertEqual(try JSONDecoder().decode([RemotePath].self, from: data), [try RemotePath("a/b")])
        XCTAssertThrowsError(try JSONDecoder().decode([RemotePath].self, from: Data("[\"a/../../etc\"]".utf8)))
    }

    func testKeepBothNaming() {
        XCTAssertEqual(CollisionNaming.candidate(for: "Report.pdf", attempt: 1), "Report.pdf")
        XCTAssertEqual(CollisionNaming.candidate(for: "Report.pdf", attempt: 2), "Report (2).pdf")
        XCTAssertEqual(CollisionNaming.candidate(for: "backup.tar.gz", attempt: 3), "backup (3).tar.gz")
        XCTAssertEqual(CollisionNaming.candidate(for: "Folder", attempt: 2), "Folder (2)")
        XCTAssertEqual(CollisionNaming.candidate(for: ".env", attempt: 2), ".env (2)")
    }
}

final class StagingAreaTests: XCTestCase {
    func testFolderImportCopiesHashesAndRecordsEmptyFolders() throws {
        let temp = try TempDirectory()
        let (folder, files) = try makeNestedFixture(in: temp)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let staging = StagingArea(root: temp.url.appendingPathComponent("staging"), quotaBytes: 1 << 30, volumeReserveBytes: 0)

        let staged = try staging.stage(folder: folder, jobID: UUID())

        XCTAssertEqual(staged.rootFolderName, "Trip")
        XCTAssertEqual(staged.skippedSymbolicLinks, 1)
        XCTAssertTrue(staged.directories.contains("Empty Folder"))
        XCTAssertTrue(staged.directories.contains("Day 1/Café ☕️"))
        XCTAssertEqual(staged.items.count, files.count)
        for item in staged.items {
            let original = try XCTUnwrap(files["Trip/\(item.relativePath)"], item.relativePath)
            XCTAssertEqual(item.size, Int64(original.count))
            XCTAssertEqual(item.sha256, SHA256Stream.hex(of: original))
            guard case .staged(let relative) = item.source else { return XCTFail("expected staged source") }
            XCTAssertEqual(try Data(contentsOf: staging.url(forStaged: relative)), original)
        }
    }

    func testQuotaIsEnforcedBeforeCopying() throws {
        let temp = try TempDirectory()
        let file = try temp.file("big.bin", randomData(10_000))
        let staging = StagingArea(root: temp.url.appendingPathComponent("staging"), quotaBytes: 5_000, volumeReserveBytes: 0)
        let jobID = UUID()
        XCTAssertThrowsError(try staging.stage(files: [file], jobID: jobID)) { error in
            guard case FileCoreError.stagingQuotaExceeded = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.root.appendingPathComponent(jobID.uuidString).path))
    }

    func testSameNamedPickedFilesKeepBoth() throws {
        let temp = try TempDirectory()
        let a = try temp.file("one/IMG.jpg", Data("1".utf8))
        let b = try temp.file("two/IMG.jpg", Data("2".utf8))
        let staging = StagingArea(root: temp.url.appendingPathComponent("staging"), volumeReserveBytes: 0)
        let staged = try staging.stage(files: [a, b], jobID: UUID())
        XCTAssertEqual(staged.items.map(\.relativePath), ["IMG.jpg", "IMG (2).jpg"])
    }
}

final class LocalFolderProviderTests: XCTestCase {
    func testRefusesSymlinkEscapesAndNeverReplacesOnMove() async throws {
        let temp = try TempDirectory()
        let root = try temp.directory("dest")
        let outside = try temp.directory("outside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let provider = LocalFolderProvider(rootURL: root)
        try await provider.connect()

        do {
            _ = try await provider.list(RemotePath("link"))
            XCTFail("escaping link must be refused")
        } catch FileCoreError.permissionDenied {}

        try await provider.writeChunk(Data("a".utf8), to: RemotePath("a.txt"), at: 0)
        try await provider.writeChunk(Data("b".utf8), to: RemotePath("b.txt"), at: 0)
        do {
            try await provider.move(RemotePath("a.txt"), to: RemotePath("b.txt"))
            XCTFail("move must not replace")
        } catch FileCoreError.alreadyExists {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b.txt")), Data("b".utf8))

        do {
            try await provider.writeChunk(Data("x".utf8), to: RemotePath("a.txt"), at: 0)
            XCTFail("offset 0 must create exclusively")
        } catch FileCoreError.alreadyExists {}
    }

    func testQueueUploadsIntoLocalFolderWithCapacity() async throws {
        let temp = try TempDirectory()
        let root = try temp.directory("dest")
        let provider = LocalFolderProvider(rootURL: root)
        let harness = try QueueHarness(provider: provider, temp: temp)
        let (folder, files) = try makeNestedFixture(in: temp)
        let queue = await harness.makeQueue()
        let job = try harness.folderJob(folder)
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let value1 = await queue.job(job.id)?.state
        XCTAssertEqual(value1, .complete)
        for (path, data) in files {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), data, path)
        }
        try await provider.connect()
        let capacity = try await provider.capacity()
        XCTAssertNotNil(capacity)
    }
}

final class CredentialIsolationTests: XCTestCase {
    func testProfilesNeverContainSecretsAndRemovalDeletesSecret() throws {
        let temp = try TempDirectory()
        let credentials = InMemoryCredentialStore()
        let store = ConnectionStore(url: temp.url.appendingPathComponent("connections.json"), credentials: credentials)
        let a = ConnectionProfile(kind: .smb, name: "Mac", host: "mac.local", share: "Files", username: "alice")
        let b = ConnectionProfile(kind: .smb, name: "PC", host: "pc.local", share: "Files", username: "alice")
        try store.upsert(a, secret: "secret-a")
        try store.upsert(b, secret: "secret-b")

        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains("secret-a"))
        XCTAssertFalse(json.contains("secret-b"))
        XCTAssertEqual(try credentials.secret(for: a.id), "secret-a")
        XCTAssertEqual(try credentials.secret(for: b.id), "secret-b")

        try store.upsert(a, secret: nil)
        XCTAssertEqual(try credentials.secret(for: a.id), "secret-a", "nil keeps the existing secret")

        try store.remove(a.id)
        XCTAssertNil(try credentials.secret(for: a.id))
        XCTAssertEqual(try credentials.secret(for: b.id), "secret-b")
        XCTAssertEqual(store.load().map(\.id), [b.id])
    }

    func testKeychainStoreIsolatesConnections() throws {
        // File-based login keychain: the data-protection keychain needs an
        // entitled app, which the app target exercises on device.
        let store = KeychainCredentialStore(service: "com.zacharysturman.filesbackups.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
        let a = UUID(), b = UUID()
        defer {
            try? store.removeSecret(for: a)
            try? store.removeSecret(for: b)
        }
        try store.setSecret("one", for: a)
        XCTAssertNil(try store.secret(for: b))
        try store.setSecret("two", for: b)
        try store.setSecret("one-updated", for: a)
        XCTAssertEqual(try store.secret(for: a), "one-updated")
        XCTAssertEqual(try store.secret(for: b), "two")
        try store.removeSecret(for: a)
        XCTAssertNil(try store.secret(for: a))
        XCTAssertEqual(try store.secret(for: b), "two")
    }

    func testProviderFactoryCannotCrossConnections() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/a.txt", Data("a".utf8))
        var job = try harness.filesJob([source])
        job.connectionID = UUID() // a different connection's ID
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let value2 = await queue.job(job.id)?.state
        XCTAssertEqual(value2, .failed)
        XCTAssertTrue(provider.allPaths().isEmpty)
    }
}
