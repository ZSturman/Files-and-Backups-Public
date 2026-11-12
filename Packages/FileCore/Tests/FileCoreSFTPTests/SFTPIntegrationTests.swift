import FileCore
import FileCoreSFTP
import Foundation
import XCTest

/// Runs against a live SSH server from FB_SFTP_TEST_* (for example
/// `scripts/sftp-fixture.sh start`). Each test uses a fresh folder.
final class SFTPIntegrationTests: XCTestCase {
    private var base: SFTPProvider.Configuration!
    private var provider: SFTPProvider!
    private var scratchRoot = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["FB_SFTP_TEST_HOST"], let user = env["FB_SFTP_TEST_USER"],
              let password = env["FB_SFTP_TEST_PASSWORD"], let root = env["FB_SFTP_TEST_ROOT"] else {
            throw XCTSkip("FB_SFTP_TEST_* not set; run scripts/sftp-fixture.sh start")
        }
        base = SFTPProvider.Configuration(host: host, port: Int(env["FB_SFTP_TEST_PORT"] ?? "22") ?? 22, root: root, username: user, password: password, pinnedHostKey: nil)
        // First contact: record the key, then require it for everything else.
        let probe = SFTPProvider(configuration: base)
        try await probe.connect()
        let key = try XCTUnwrap(probe.presentedHostKey)
        let folder = "fb-test-\(UUID().uuidString.prefix(8))"
        try await probe.createDirectory(try RemotePath(folder))
        await probe.disconnect()
        base.pinnedHostKey = key
        scratchRoot = root + "/" + folder
        var scoped = base!
        scoped.root = scratchRoot
        provider = SFTPProvider(configuration: scoped)
        try await provider.connect()
    }

    override func tearDown() async throws {
        guard let base else { return }
        await provider?.disconnect()
        let cleanup = SFTPProvider(configuration: base)
        try? await cleanup.connect()
        if let name = scratchRoot.split(separator: "/").last { try? await cleanup.delete(try RemotePath(String(name))) }
        await cleanup.disconnect()
    }

    func testFingerprintFormat() throws {
        let key = try XCTUnwrap(provider.presentedHostKey)
        XCTAssertTrue(SFTPProvider.fingerprint(ofOpenSSHKey: key)?.hasPrefix("SHA256:") == true)
    }

    func testPinnedKeyMismatchIsRefused() async throws {
        var wrong = base!
        // A syntactically valid but different ed25519 key.
        wrong.pinnedHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVqb2V5b2V5b2V5b2V5b2V5b2V5b2V5b2V5b2V5b2V5"
        do {
            try await SFTPProvider(configuration: wrong).connect()
            XCTFail("must refuse a different host key")
        } catch FileCoreError.permissionDenied(let message) {
            XCTAssertTrue(message.contains("host key"), message)
        }
    }

    func testBrowseCreateRenameDeleteUnicode() async throws {
        let folder = try RemotePath("Café ☕️")
        try await provider.createDirectory(folder)
        try await provider.writeChunk(Data("crème".utf8), to: folder.appending("ñandú.txt"), at: 0)
        do {
            try await provider.writeChunk(Data("x".utf8), to: folder.appending("ñandú.txt"), at: 0)
            XCTFail("offset 0 must create exclusively")
        } catch FileCoreError.alreadyExists {}
        let listing = try await provider.list(folder)
        XCTAssertEqual(listing.map(\.name), ["ñandú.txt"])
        XCTAssertEqual(listing.first?.size, 6)
        try await provider.writeChunk(Data("b".utf8), to: RemotePath("b.txt"), at: 0)
        do {
            try await provider.move(folder.appending("ñandú.txt"), to: RemotePath("b.txt"))
            XCTFail("rename must not replace")
        } catch FileCoreError.alreadyExists {}
        try await provider.delete(folder)
        let rest = try await provider.list(.root)
        XCTAssertEqual(rest.map(\.name), ["b.txt"])
    }

    func testQueueUploadInterruptedThenResumedAndVerified() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let src = temp.appendingPathComponent("src/Trip")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        try big.write(to: src.appendingPathComponent("Day 1/video.bin"))
        try Data("hi\n".utf8).write(to: src.appendingPathComponent("notes.txt"))
        try await provider.createDirectory(try RemotePath("Trip"))

        let staging = StagingArea(root: temp.appendingPathComponent("staging"), volumeReserveBytes: 0)
        let jobID = UUID()
        let staged = try staging.stage(folder: src, jobID: jobID)
        let job = TransferJob(id: jobID, connectionID: UUID(), connectionName: "SFTP", destination: .root,
                              rootFolderName: staged.rootFolderName, directories: staged.directories, items: staged.items, verifyContents: true)
        var scoped = base!
        scoped.root = scratchRoot
        let configuration = scoped
        let store = TransferStore(url: temp.appendingPathComponent("transfers.json"))
        let first = TransferQueue(store: store, staging: staging) { _ in SFTPProvider(configuration: configuration) }
        await first.setChunkSize(256 * 1024)
        await first.setAfterChunk { _, offset in
            if offset >= 1 << 20 { Task { await first.suspendForBackground() } }
        }
        await first.enqueue(job)
        try await Task.sleep(for: .milliseconds(300))
        await first.waitUntilIdle()

        let second = TransferQueue(store: store, staging: staging) { _ in SFTPProvider(configuration: configuration) }
        await second.setChunkSize(256 * 1024)
        await second.resumeAfterInterruption()
        await second.waitUntilIdle()
        let finishedJob = await second.jobs.first
        let finished = try XCTUnwrap(finishedJob)
        XCTAssertEqual(finished.state, .complete, finished.items.compactMap(\.lastError).joined(separator: "; ") + (finished.failureReason ?? ""))
        XCTAssertEqual(finished.resolvedRootName, "Trip (2)")
        XCTAssertEqual(finished.verificationSummary, .sha256Readback)
        let video = try XCTUnwrap(finished.items.first { $0.relativePath == "Day 1/video.bin" })
        XCTAssertGreaterThan(video.resumedFromOffset ?? 0, 0)
        let read = try await provider.read(RemotePath("Trip (2)/Day 1/video.bin"), offset: 0, length: big.count + 10)
        XCTAssertEqual(read, big)
    }

    func testWrongPasswordIsAuthenticationFailure() async throws {
        var wrong = base!
        wrong.password = "wrong"
        do {
            try await SFTPProvider(configuration: wrong).connect()
            XCTFail("must fail")
        } catch FileCoreError.authenticationFailed {
        } catch {
            XCTFail("expected authenticationFailed, got \(error)")
        }
    }

    func testUnreachableIsTransient() async throws {
        var dead = base!
        dead.port = 1
        dead.timeout = 5
        do {
            try await SFTPProvider(configuration: dead).connect()
            XCTFail("must fail")
        } catch let error as FileCoreError {
            XCTAssertTrue(error.isTransient, "\(error)")
        }
    }
}
