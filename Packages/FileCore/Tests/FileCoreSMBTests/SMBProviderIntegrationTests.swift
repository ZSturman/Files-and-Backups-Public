import FileCore
import FileCoreSMB
import Foundation
import XCTest

/// Runs against a live SMB server described by FB_SMB_TEST_* variables, e.g.
/// the disposable Samba container from `scripts/smb-fixture.sh start`.
/// Every test works inside a fresh random folder and removes it afterwards.
final class SMBProviderIntegrationTests: XCTestCase {
    private var configuration: SMBProvider.Configuration!
    private var provider: SMBProvider!
    private var scratch: RemotePath!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["FB_SMB_TEST_HOST"], let share = env["FB_SMB_TEST_SHARE"],
              let user = env["FB_SMB_TEST_USER"], let password = env["FB_SMB_TEST_PASSWORD"] else {
            throw XCTSkip("FB_SMB_TEST_* not set; run scripts/smb-fixture.sh start")
        }
        configuration = SMBProvider.Configuration(
            host: host, port: env["FB_SMB_TEST_PORT"].flatMap(Int.init), share: share,
            username: user, password: password
        )
        let root = SMBProvider(configuration: configuration)
        try await root.connect()
        scratch = try RemotePath("fb-test-\(UUID().uuidString.prefix(8))")
        try await root.createDirectory(scratch)
        await root.disconnect()

        var scoped = configuration!
        scoped.root = scratch
        provider = SMBProvider(configuration: scoped)
        try await provider.connect()
    }

    override func tearDown() async throws {
        await provider?.disconnect()
        guard let configuration, let scratch else { return }
        let root = SMBProvider(configuration: configuration)
        try? await root.connect()
        try? await root.delete(scratch)
        await root.disconnect()
    }

    func testBrowseCreateRenameDeleteWithUnicodeNames() async throws {
        let folder = try RemotePath("Café ☕️/日本語")
        try await provider.createDirectory(try RemotePath("Café ☕️"))
        try await provider.createDirectory(folder)
        try await provider.writeChunk(Data("crème".utf8), to: folder.appending("ñandú.txt"), at: 0)

        let listing = try await provider.list(try RemotePath("Café ☕️"))
        XCTAssertEqual(listing.map(\.name), ["日本語"])
        XCTAssertTrue(listing[0].isDirectory)
        let file = try await provider.item(at: folder.appending("ñandú.txt"))
        XCTAssertEqual(file?.size, 6)
        let missing = try await provider.item(at: folder.appending("missing.txt"))
        XCTAssertNil(missing)

        try await provider.move(folder.appending("ñandú.txt"), to: folder.appending("renamed.txt"))
        let renamed = try await provider.read(folder.appending("renamed.txt"), offset: 0, length: 100)
        XCTAssertEqual(renamed, Data("crème".utf8))

        try await provider.delete(try RemotePath("Café ☕️"))
        let rootListing = try await provider.list(.root)
        XCTAssertTrue(rootListing.isEmpty)
    }

    func testExclusiveCreateOffsetWriteAndNoReplaceRename() async throws {
        let a = try RemotePath("a.bin"), b = try RemotePath("b.bin")
        try await provider.writeChunk(Data(repeating: 1, count: 1000), to: a, at: 0)
        do {
            try await provider.writeChunk(Data([9]), to: a, at: 0)
            XCTFail("offset 0 must not overwrite")
        } catch FileCoreError.alreadyExists {}

        // Offset write truncates anything after the offset (resume semantics).
        try await provider.writeChunk(Data(repeating: 2, count: 10), to: a, at: 500)
        let size = try await provider.item(at: a)?.size
        XCTAssertEqual(size, 510)
        let tail = try await provider.read(a, offset: 495, length: 15)
        XCTAssertEqual(tail, Data(repeating: 1, count: 5) + Data(repeating: 2, count: 10))

        try await provider.writeChunk(Data("b".utf8), to: b, at: 0)
        do {
            try await provider.move(a, to: b)
            XCTFail("rename must not replace")
        } catch FileCoreError.alreadyExists {}
        let bData = try await provider.read(b, offset: 0, length: 10)
        XCTAssertEqual(bData, Data("b".utf8))
    }

    func testQueueUploadsNestedFolderAndResumesAfterInterruption() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("smb-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let files: [String: Data] = [
            "Trip/notes.txt": Data("hello\n".utf8),
            "Trip/Day 1/Café ☕️/menu.txt": Data("crème brûlée\n".utf8),
            "Trip/Day 2/video.bin": Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }),
            "Trip/Day 2/empty.dat": Data(),
        ]
        for (path, data) in files {
            let url = temp.appendingPathComponent("src/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("src/Trip/Empty Folder"), withIntermediateDirectories: true)
        // Pre-existing folder: the upload must land in "Trip (2)".
        try await provider.createDirectory(try RemotePath("Trip"))

        let staging = StagingArea(root: temp.appendingPathComponent("staging"), volumeReserveBytes: 0)
        let connectionID = UUID()
        let jobID = UUID()
        let staged = try staging.stage(folder: temp.appendingPathComponent("src/Trip"), jobID: jobID)
        let job = TransferJob(
            id: jobID, connectionID: connectionID, connectionName: "Samba", destination: .root,
            rootFolderName: staged.rootFolderName, directories: staged.directories, items: staged.items, verifyContents: true
        )
        var scoped = configuration!
        scoped.root = scratch
        let factoryConfiguration = scoped
        let store = TransferStore(url: temp.appendingPathComponent("transfers.json"))
        let makeQueue = { () async -> TransferQueue in
            let queue = TransferQueue(store: store, staging: staging) { _ in SMBProvider(configuration: factoryConfiguration) }
            await queue.setChunkSize(256 * 1024)
            return queue
        }

        // First run: suspend partway through the large file (app backgrounded).
        let first = await makeQueue()
        await first.setAfterChunk { _, offset in
            if offset >= 1_024 * 1024 { Task { await first.suspendForBackground() } }
        }
        await first.enqueue(job)
        try await Task.sleep(for: .milliseconds(300))
        await first.waitUntilIdle()
        let pausedState = await first.jobs.first?.state
        XCTAssertEqual(pausedState, .paused)

        // Relaunch and resume.
        let second = await makeQueue()
        await second.resumeAfterInterruption()
        await second.waitUntilIdle()
        let firstJob = await second.jobs.first
        let finished = try XCTUnwrap(firstJob)
        XCTAssertEqual(finished.state, .complete, finished.items.compactMap(\.lastError).joined(separator: "; "))
        XCTAssertEqual(finished.resolvedRootName, "Trip (2)")
        XCTAssertEqual(finished.verificationSummary, .sha256Readback)
        let video = try XCTUnwrap(finished.items.first { $0.relativePath == "Day 2/video.bin" })
        XCTAssertGreaterThan(video.resumedFromOffset ?? 0, 0, "large file resumed on the SMB share")

        for (path, data) in files {
            let remote = try RemotePath(path.replacingOccurrences(of: "Trip/", with: "Trip (2)/"))
            let read = try await provider.read(remote, offset: 0, length: data.count + 1)
            XCTAssertEqual(read, data, path)
        }
        let emptyFolder = try await provider.item(at: try RemotePath("Trip (2)/Empty Folder"))
        XCTAssertEqual(emptyFolder?.isDirectory, true)
        let leftovers = try await provider.list(try RemotePath("Trip (2)/Day 2")).filter { $0.name.hasPrefix(".fbpart-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCapacityIsReportedOrUnknown() async throws {
        let capacity = try await provider.capacity()
        if let capacity {
            XCTAssertGreaterThan(capacity.totalBytes, 0)
            XCTAssertLessThanOrEqual(capacity.availableBytes, capacity.totalBytes)
        }
    }

    func testWrongPasswordIsAuthenticationFailure() async throws {
        var bad = configuration!
        bad.password = "definitely-wrong"
        let wrong = SMBProvider(configuration: bad)
        do {
            try await wrong.connect()
            XCTFail("connect must fail")
        } catch FileCoreError.authenticationFailed {
        } catch {
            XCTFail("expected authenticationFailed, got \(error)")
        }
    }

    func testUnreachableHostIsTransient() async throws {
        var bad = configuration!
        bad.port = 1 // nothing listens here
        bad.timeout = 5
        do {
            try await SMBProvider(configuration: bad).connect()
            XCTFail("connect must fail")
        } catch let error as FileCoreError {
            XCTAssertTrue(error.isTransient, "\(error)")
        }
    }

    func testMissingShareAndRootAreReported() async throws {
        var badShare = configuration!
        badShare.share = "NoSuchShare"
        do {
            try await SMBProvider(configuration: badShare).connect()
            XCTFail("connect must fail")
        } catch let error as FileCoreError {
            XCTAssertFalse(error.isTransient, "\(error)")
        }

        var badRoot = configuration!
        badRoot.root = try RemotePath("no-such-folder-\(UUID().uuidString)")
        do {
            try await SMBProvider(configuration: badRoot).connect()
            XCTFail("connect must fail")
        } catch FileCoreError.notFound {}
    }

    func testRequiredEncryptionConnects() async throws {
        var encrypted = configuration!
        encrypted.requireEncryption = true
        encrypted.root = scratch
        let secure = SMBProvider(configuration: encrypted)
        try await secure.connect()
        try await secure.writeChunk(Data("sealed".utf8), to: try RemotePath("enc.txt"), at: 0)
        let data = try await secure.read(try RemotePath("enc.txt"), offset: 0, length: 10)
        XCTAssertEqual(data, Data("sealed".utf8))
        await secure.disconnect()
    }

    func testListSharesForSetup() async throws {
        let shares = try await SMBProvider.listShares(
            host: configuration.host, port: configuration.port, username: configuration.username,
            domain: "", password: configuration.password
        )
        XCTAssertTrue(shares.contains(configuration.share), "\(shares)")
    }

    /// Regression for the AMSMB2 timeout use-after-free (Packages/Vendor):
    /// freeze the server longer than the SMB timeout during an upload, then
    /// resume it. The queue must fail the attempt cleanly (no crash), retry on
    /// a fresh connection, and finish with verified contents.
    func testServerStallLongerThanTimeoutDoesNotCrash() async throws {
        guard let container = ProcessInfo.processInfo.environment["FB_SMB_TEST_CONTAINER"] else {
            throw XCTSkip("FB_SMB_TEST_CONTAINER not set")
        }
        func docker(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("smb-stall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let data = Data((0..<8_000_000).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("src"), withIntermediateDirectories: true)
        try data.write(to: temp.appendingPathComponent("src/stall.bin"))
        let staging = StagingArea(root: temp.appendingPathComponent("staging"), volumeReserveBytes: 0)
        let jobID = UUID()
        let staged = try staging.stage(files: [temp.appendingPathComponent("src/stall.bin")], jobID: jobID)
        let job = TransferJob(id: jobID, connectionID: UUID(), connectionName: "Samba", destination: .root,
                              rootFolderName: nil, directories: [], items: staged.items, verifyContents: true)
        var scoped = configuration!
        scoped.root = scratch
        scoped.timeout = 4
        let factory = scoped
        let queue = TransferQueue(store: TransferStore(url: temp.appendingPathComponent("t.json")), staging: staging) { _ in
            SMBProvider(configuration: factory)
        }
        await queue.setChunkSize(256 * 1024)
        await queue.setRetryDelays([.seconds(3), .seconds(3), .seconds(5), .seconds(5)])
        let stalled = StallFlag()
        await queue.setAfterChunk { _, offset in
            if offset >= 2 << 20, stalled.claim() {
                try? docker(["pause", container])
                Task.detached {
                    try? await Task.sleep(for: .seconds(9))
                    try? docker(["unpause", container])
                }
            }
        }
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        try? docker(["unpause", container])
        let item = await queue.jobs.first?.items.first
        XCTAssertEqual(item?.state, .complete, item?.lastError ?? "")
        XCTAssertGreaterThanOrEqual(item?.attempts ?? 0, 2, "the stall forced at least one retry")
        let read = try await provider.read(RemotePath("stall.bin"), offset: 0, length: data.count + 1)
        XCTAssertEqual(read, data)
    }
}

final class StallFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
