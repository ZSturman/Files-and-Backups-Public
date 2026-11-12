import FileCore
import Foundation
import XCTest

/// Runs against a live WebDAV server from FB_WEBDAV_TEST_* (for example
/// `scripts/webdav-fixture.sh start`). Each test uses a fresh folder.
final class WebDAVIntegrationTests: XCTestCase {
    private var provider: WebDAVProvider!
    private var rootProvider: WebDAVProvider!
    private var scratch: RemotePath!
    private var url: URL!, user = "", password = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["FB_WEBDAV_TEST_URL"], let url = URL(string: raw),
              let user = env["FB_WEBDAV_TEST_USER"], let password = env["FB_WEBDAV_TEST_PASSWORD"] else {
            throw XCTSkip("FB_WEBDAV_TEST_* not set; run scripts/webdav-fixture.sh start")
        }
        self.url = url; self.user = user; self.password = password
        rootProvider = try WebDAVProvider(baseURL: url, username: user, password: password)
        try await rootProvider.connect()
        scratch = try RemotePath("fb-test-\(UUID().uuidString.prefix(8))")
        try await rootProvider.createDirectory(scratch)
        provider = try WebDAVProvider(baseURL: url, root: scratch, username: user, password: password)
        try await provider.connect()
    }

    override func tearDown() async throws {
        if let scratch { try? await rootProvider?.delete(scratch) }
    }

    func testRejectsPlainHTTPToRemoteHosts() {
        XCTAssertThrowsError(try WebDAVProvider(baseURL: URL(string: "http://nas.local/dav")!, username: "a", password: "b"))
        XCTAssertNoThrow(try WebDAVProvider(baseURL: URL(string: "https://nas.local/dav")!, username: "a", password: "b"))
    }

    func testBrowseCreateRenameDeleteWithUnicodeAndSpaces() async throws {
        let folder = try RemotePath("Café ☕️ & Co")
        try await provider.createDirectory(folder)
        do {
            try await provider.createDirectory(folder)
            XCTFail("second MKCOL must fail")
        } catch FileCoreError.alreadyExists {}
        let listing = try await provider.list(.root)
        XCTAssertEqual(listing.map(\.name), ["Café ☕️ & Co"])
        XCTAssertTrue(listing[0].isDirectory)
        let missing = try await provider.item(at: RemotePath("nope.txt"))
        XCTAssertNil(missing)

        let renamed = try RemotePath("Renamed #1")
        try await provider.move(folder, to: renamed)
        let afterMove = try await provider.list(.root)
        XCTAssertEqual(afterMove.map(\.name), ["Renamed #1"])
        try await provider.delete(renamed)
        let empty = try await provider.list(.root)
        XCTAssertTrue(empty.isEmpty)
    }

    func testQueueUploadsNestedFolderKeepsBothAndVerifies() async throws {
        let harness = try QueueHarness(provider: provider)
        let (folder, files) = try makeNestedFixture(in: harness.temp)
        try await provider.createDirectory(try RemotePath("Trip"))
        let queue = await harness.makeQueue()
        let job = try harness.folderJob(folder, verify: true)
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let finished = await queue.job(job.id)
        XCTAssertEqual(finished?.state, .complete, finished?.items.compactMap(\.lastError).joined(separator: "; ") ?? "")
        XCTAssertEqual(finished?.resolvedRootName, "Trip (2)")
        XCTAssertEqual(finished?.verificationSummary, .sha256Readback)
        for (path, data) in files {
            let remote = try RemotePath(path.replacingOccurrences(of: "Trip/", with: "Trip (2)/"))
            let read = try await provider.read(remote, offset: 0, length: data.count + 1)
            XCTAssertEqual(read, data, path)
        }
        let emptyFolder = try await provider.item(at: RemotePath("Trip (2)/Empty Folder"))
        XCTAssertEqual(emptyFolder?.isDirectory, true)
        let day2 = try await provider.list(RemotePath("Trip (2)/Day 2"))
        XCTAssertFalse(day2.contains { $0.name.hasPrefix(".fbpart-") })

        // Moving onto an existing name never replaces it.
        do {
            try await provider.move(RemotePath("Trip (2)/notes.txt"), to: RemotePath("Trip (2)/Day 2/video.bin"))
            XCTFail("MOVE must not overwrite")
        } catch FileCoreError.alreadyExists {}
    }

    func testWrongPasswordIsAuthenticationFailure() async throws {
        let wrong = try WebDAVProvider(baseURL: url, username: user, password: "wrong")
        do {
            try await wrong.connect()
            XCTFail("must fail")
        } catch FileCoreError.authenticationFailed {}
    }

    func testUnreachableServerIsTransient() async throws {
        let dead = try WebDAVProvider(baseURL: URL(string: "http://127.0.0.1:1/")!, username: user, password: password)
        do {
            try await dead.connect()
            XCTFail("must fail")
        } catch let error as FileCoreError {
            XCTAssertTrue(error.isTransient, "\(error)")
        }
    }
}
