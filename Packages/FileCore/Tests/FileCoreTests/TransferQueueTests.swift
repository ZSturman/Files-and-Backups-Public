import FileCore
import Foundation
import XCTest

final class TransferQueueTests: XCTestCase {
    func testNestedFolderUploadMatchesSourceAndCleansStaging() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let (folder, files) = try makeNestedFixture(in: harness.temp)
        let job = try harness.folderJob(folder)
        let queue = await harness.makeQueue()

        await queue.enqueue(job)
        await queue.waitUntilIdle()

        let unwrapped101 = await queue.job(job.id)

        let finished = try XCTUnwrap(unwrapped101)
        XCTAssertEqual(finished.state, .complete)
        XCTAssertEqual(finished.resolvedRootName, "Trip")
        XCTAssertEqual(finished.verificationSummary, .sha256Readback)
        for (path, data) in files {
            XCTAssertEqual(provider.fileData(path), data, path)
        }
        let value1 = try await provider.item(at: RemotePath("Trip/Empty Folder"))
        XCTAssertNotNil(value1)
        XCTAssertFalse(provider.allPaths().contains { $0.contains(".fbpart-") }, "no temp files left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.staging.root.appendingPathComponent(job.id.uuidString).path))
    }

    func testExistingFolderAndFileAreNeverOverwritten() async throws {
        let provider = InMemoryProvider()
        try provider.seedFile("Trip/notes.txt", data: Data("original".utf8))
        try provider.seedFile("report.pdf", data: Data("old".utf8))
        let harness = try QueueHarness(provider: provider)
        let (folder, files) = try makeNestedFixture(in: harness.temp)
        let report = try harness.temp.file("loose/report.pdf", Data("new".utf8))
        let queue = await harness.makeQueue()

        let folderJob = try harness.folderJob(folder)
        let fileJob = try harness.filesJob([report])
        await queue.enqueue(folderJob)
        await queue.enqueue(fileJob)
        await queue.waitUntilIdle()

        XCTAssertEqual(provider.fileData("Trip/notes.txt"), Data("original".utf8))
        let value2 = await queue.job(folderJob.id)?.resolvedRootName
        XCTAssertEqual(value2, "Trip (2)")
        XCTAssertEqual(provider.fileData("Trip (2)/notes.txt"), files["Trip/notes.txt"])
        XCTAssertEqual(provider.fileData("report.pdf"), Data("old".utf8))
        XCTAssertEqual(provider.fileData("report (2).pdf"), Data("new".utf8))
        let value3 = await queue.job(fileJob.id)?.items.first?.finalPath
        XCTAssertEqual(value3, try RemotePath("report (2).pdf"))
    }

    func testNetworkDropMidFileResumesFromVerifiedOffset() async throws {
        let provider = InMemoryProvider()
        provider.updateFaults { $0.disconnectAfterWrittenBytes = 700_000 }
        let harness = try QueueHarness(provider: provider)
        let big = randomData(1_500_000, seed: 9)
        let source = try harness.temp.file("in/big.bin", big)
        let queue = await harness.makeQueue()
        let job = try harness.filesJob([source])

        await queue.enqueue(job)
        await queue.waitUntilIdle()

        let unwrapped102 = await queue.job(job.id)?.items.first

        let item = try XCTUnwrap(unwrapped102)
        XCTAssertEqual(item.state, .complete)
        XCTAssertEqual(item.attempts, 2)
        XCTAssertNotNil(item.resumedFromOffset)
        XCTAssertGreaterThan(item.resumedFromOffset ?? 0, 0)
        XCTAssertEqual(provider.fileData("big.bin"), big)
        XCTAssertEqual(item.verification, .sha256Readback)
    }

    func testAppReopenAfterSuspensionResumesTransfer() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let data = randomData(2_000_000, seed: 4)
        let source = try harness.temp.file("in/clip.mov", data)
        let job = try harness.filesJob([source])

        let first = await harness.makeQueue()
        await first.setAfterChunk { _, offset in
            if offset >= 640 * 1024 { Task { await first.suspendForBackground() } }
        }
        await first.enqueue(job)
        try await Task.sleep(for: .milliseconds(200))
        await first.waitUntilIdle()
        let unwrapped103 = await first.job(job.id)
        let paused = try XCTUnwrap(unwrapped103)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.pauseReason, .system)
        XCTAssertNil(provider.fileData("clip.mov"))

        // Relaunch: a new queue over the same persisted state.
        let second = await harness.makeQueue()
        let value4 = await second.job(job.id)?.state
        XCTAssertEqual(value4, .paused)
        await second.resumeAfterInterruption()
        await second.waitUntilIdle()
        let unwrapped104 = await second.job(job.id)?.items.first
        let item = try XCTUnwrap(unwrapped104)
        XCTAssertEqual(item.state, .complete)
        XCTAssertGreaterThan(item.resumedFromOffset ?? 0, 0)
        XCTAssertEqual(provider.fileData("clip.mov"), data)
    }

    func testProcessKilledMidTransferIsTreatedAsInterrupted() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/a.bin", randomData(500_000, seed: 5))
        let job = try harness.filesJob([source])
        let first = await harness.makeQueue()
        await first.setAfterChunk { _, offset in
            if offset >= 128 * 1024 { Task { await first.pause(job.id) } }
        }
        await first.enqueue(job)
        try await Task.sleep(for: .milliseconds(100))
        await first.waitUntilIdle()

        // Rewrite the persisted state as a crash would leave it: in flight, no pause.
        var json = try String(contentsOf: harness.storeURL, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"state\":\"paused\"", with: "\"state\":\"transferring\"")
        json = json.replacingOccurrences(of: "\"pauseReason\":\"user\",", with: "")
        try json.write(to: harness.storeURL, atomically: true, encoding: .utf8)

        let relaunched = await harness.makeQueue()
        let unwrapped105 = await relaunched.job(job.id)
        let restored = try XCTUnwrap(unwrapped105)
        XCTAssertEqual(restored.items.first?.state, .paused)
        XCTAssertEqual(restored.pauseReason, .system)
        let value5 = await relaunched.isRunning
        XCTAssertFalse(value5, "nothing starts until the app asks")
        await relaunched.resumeAfterInterruption()
        await relaunched.waitUntilIdle()
        let value6 = await relaunched.job(job.id)?.state
        XCTAssertEqual(value6, .complete)
        XCTAssertEqual(provider.fileData("a.bin"), try Data(contentsOf: source))
    }

    func testChangedPartialUploadRestartsFromZero() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let data = randomData(900_000, seed: 6)
        let source = try harness.temp.file("in/doc.bin", data)
        let job = try harness.filesJob([source])
        let queue = await harness.makeQueue()
        await queue.setAfterChunk { _, offset in
            if offset >= 256 * 1024 { Task { await queue.pause(job.id) } }
        }
        await queue.enqueue(job)
        try await Task.sleep(for: .milliseconds(100))
        await queue.waitUntilIdle()
        let unwrapped106 = await queue.job(job.id)?.items.first?.resumeToken
        let token = try XCTUnwrap(unwrapped106)

        // Someone else modifies the partial file on the server.
        try provider.seedFile(token, data: randomData(300_000, seed: 77))

        await queue.setAfterChunk(nil)
        await queue.resume(job.id)
        await queue.waitUntilIdle()
        let unwrapped107 = await queue.job(job.id)?.items.first
        let item = try XCTUnwrap(unwrapped107)
        XCTAssertEqual(item.state, .complete)
        XCTAssertNil(item.resumedFromOffset, "untrusted partial must restart")
        XCTAssertEqual(provider.fileData("doc.bin"), data)
    }

    func testUnrecordedCommitIsRecoveredWithoutDuplicate() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let data = randomData(200_000, seed: 8)
        let source = try harness.temp.file("in/x.bin", data)
        let job = try harness.filesJob([source])

        // Simulate: the file was renamed into place, but the app died before
        // persisting completion (commit candidate recorded, temp gone).
        try provider.seedFile("x.bin", data: data)
        var crashed = job
        crashed.items[0].state = .verifying
        crashed.items[0].bytesCommitted = Int64(data.count)
        crashed.items[0].commitCandidate = try RemotePath("x.bin")
        crashed.items[0].resumeToken = ".fbpart-\(job.items[0].id.uuidString.lowercased())"
        try TransferStore(url: harness.storeURL).save([crashed])

        let queue = await harness.makeQueue()
        await queue.resumeAfterInterruption()
        await queue.waitUntilIdle()
        let unwrapped108 = await queue.job(job.id)?.items.first
        let item = try XCTUnwrap(unwrapped108)
        XCTAssertEqual(item.state, .complete)
        XCTAssertEqual(item.finalPath, try RemotePath("x.bin"))
        XCTAssertEqual(item.verification, .sha256Readback)
        XCTAssertNil(provider.fileData("x (2).bin"), "no duplicate copy")
    }

    func testCorruptedUploadFailsReadBackVerificationAndIsNotPublished() async throws {
        let provider = InMemoryProvider()
        provider.updateFaults { $0.corruptWrites = true }
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/c.bin", randomData(100_000, seed: 10))
        let job = try harness.filesJob([source], verify: true)
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let unwrapped109 = await queue.job(job.id)?.items.first
        let item = try XCTUnwrap(unwrapped109)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.lastError?.contains("SHA-256") == true)
        XCTAssertNil(provider.fileData("c.bin"))
        let value7 = await queue.job(job.id)?.state
        XCTAssertEqual(value7, .failed)
    }

    func testSizeOnlyVerificationIsReportedHonestly() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/s.bin", randomData(10_000, seed: 11))
        let job = try harness.filesJob([source], verify: false)
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let value8 = await queue.job(job.id)?.verificationSummary
        XCTAssertEqual(value8, .size)
    }

    func testInvalidCredentialsFailJobWithoutUploading() async throws {
        let provider = InMemoryProvider()
        provider.updateFaults { $0.rejectCredentials = true }
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/a.txt", Data("a".utf8))
        let job = try harness.filesJob([source])
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let unwrapped110 = await queue.job(job.id)
        let finished = try XCTUnwrap(unwrapped110)
        XCTAssertEqual(finished.state, .failed)
        XCTAssertEqual(finished.failureReason, FileCoreError.authenticationFailed.errorDescription)
        XCTAssertEqual(finished.items.first?.state, .queued, "file stays queued for retry after fixing credentials")
        XCTAssertTrue(provider.allPaths().isEmpty)
    }

    func testUnreachableHostPausesAsConnectionLostThenResumes() async throws {
        let provider = InMemoryProvider()
        provider.updateFaults { $0.failConnects = 10 }
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/a.txt", Data("a".utf8))
        let job = try harness.filesJob([source])
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let value9 = await queue.job(job.id)?.pauseReason
        XCTAssertEqual(value9, .connectionLost)
        XCTAssertEqual(provider.connectCount, 4, "initial attempt plus three bounded retries")

        provider.updateFaults { $0.failConnects = 0 }
        await queue.resumeAfterInterruption()
        await queue.waitUntilIdle()
        let value10 = await queue.job(job.id)?.state
        XCTAssertEqual(value10, .complete)
    }

    func testOutOfSpaceStopsJob() async throws {
        let provider = InMemoryProvider(reportsCapacity: true)
        provider.updateFaults { $0.availableBytes = 50_000 }
        let harness = try QueueHarness(provider: provider)
        let a = try harness.temp.file("in/a.bin", randomData(200_000, seed: 12))
        let b = try harness.temp.file("in/b.bin", randomData(10, seed: 13))
        let job = try harness.filesJob([a, b])
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let unwrapped111 = await queue.job(job.id)
        let finished = try XCTUnwrap(unwrapped111)
        XCTAssertEqual(finished.state, .failed)
        XCTAssertEqual(finished.items[0].state, .failed)
        XCTAssertEqual(finished.items[1].state, .queued)
    }

    func testMissingDestinationFolderFailsClearly() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/a.txt", Data("a".utf8))
        let job = try harness.filesJob([source], destination: try RemotePath("Unmounted HDD"))
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let value11 = await queue.job(job.id)?.failureReason
        XCTAssertEqual(value11, FileCoreError.notFound(try RemotePath("Unmounted HDD")).errorDescription)
    }

    func testDuplicateEnqueueAndRepeatedResumeUploadOnce() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let source = try harness.temp.file("in/once.txt", Data("once".utf8))
        let job = try harness.filesJob([source])
        let queue = await harness.makeQueue()
        await queue.enqueue(job)
        await queue.enqueue(job)
        await queue.resume(job.id)
        await queue.resumeAfterInterruption()
        await queue.waitUntilIdle()
        let value12 = await queue.jobs.count
        XCTAssertEqual(value12, 1)
        XCTAssertEqual(provider.allPaths(), ["once.txt"])
    }

    func testCancelRemovesPartialAndStagingButKeepsPublishedFiles() async throws {
        let provider = InMemoryProvider()
        let harness = try QueueHarness(provider: provider)
        let small = try harness.temp.file("in/a-small.txt", Data("done".utf8))
        let large = try harness.temp.file("in/b-large.bin", randomData(800_000, seed: 14))
        let job = try harness.filesJob([small, large])
        let queue = await harness.makeQueue()
        await queue.setAfterChunk { _, offset in
            if offset >= 192 * 1024 { Task { await queue.pause(job.id) } }
        }
        await queue.enqueue(job)
        try await Task.sleep(for: .milliseconds(100))
        await queue.waitUntilIdle()
        XCTAssertTrue(provider.allPaths().contains { $0.hasPrefix(".fbpart-") })

        await queue.cancel(job.id)
        let value13 = await queue.job(job.id)?.state
        XCTAssertEqual(value13, .cancelled)
        XCTAssertEqual(provider.allPaths(), ["a-small.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.staging.root.appendingPathComponent(job.id.uuidString).path))
    }

    func testDiscardIgnoresTokensThatAreNotAppTempFiles() async throws {
        let provider = InMemoryProvider()
        try provider.seedFile("important.doc", data: Data("keep".utf8))
        await provider.discardUpload(resumeToken: "important.doc")
        XCTAssertEqual(provider.fileData("important.doc"), Data("keep".utf8))
    }
}
