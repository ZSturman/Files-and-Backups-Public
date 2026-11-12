import FileCore
import Foundation
import XCTest

/// Live checks against a real Home Services v1 server. Requires
/// FB_HS_TEST_URL and FB_HS_TEST_TOKEN (files-backups scope). Writes only a
/// disposable `fb-live-test-*` folder in the files root and moves it to the
/// managed Trash afterwards.
final class HomeServicesLiveTests: XCTestCase {
    func testLiveBrowseUploadKeepBothDownloadAndTrash() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["FB_HS_TEST_URL"], let url = URL(string: raw), let token = env["FB_HS_TEST_TOKEN"] else {
            throw XCTSkip("FB_HS_TEST_URL / FB_HS_TEST_TOKEN not set")
        }
        let root = try HomeServicesProvider(baseURL: url, token: token)
        try await root.connect()
        XCTAssertNotNil(root.serverID)
        XCTAssertTrue(root.capabilities.upload.isSupported)
        XCTAssertFalse(root.capabilities.permanentDelete.isSupported)
        let capacity = try await root.capacity()
        XCTAssertGreaterThan(capacity?.totalBytes ?? 0, 0)

        let folder = try RemotePath("fb-live-test-\(UUID().uuidString.prefix(8).lowercased())")
        try await root.createDirectory(folder)
        defer { Task { try? await root.delete(folder) } }
        let provider = try HomeServicesProvider(baseURL: url, token: token, root: folder)
        try await provider.connect()

        let harness = try QueueHarness(provider: provider)
        let (source, files) = try makeNestedFixture(in: harness.temp)
        try await provider.createDirectory(try RemotePath("Trip"))
        let queue = await harness.makeQueue()
        let job = try harness.folderJob(source, verify: false)
        await queue.enqueue(job)
        await queue.waitUntilIdle()
        let finished = await queue.job(job.id)
        XCTAssertEqual(finished?.state, .complete, (finished?.failureReason ?? "") + (finished?.items.compactMap(\.lastError).joined(separator: "; ") ?? ""))
        XCTAssertEqual(finished?.resolvedRootName, "Trip (2)")
        XCTAssertEqual(finished?.verificationSummary, .serverSHA256)
        for (path, data) in files {
            let remote = try RemotePath(path.replacingOccurrences(of: "Trip/", with: "Trip (2)/"))
            let read = try await provider.read(remote, offset: 0, length: data.count + 1)
            XCTAssertEqual(read, data, path)
        }

        // Same file again: the server publishes it with keep-both naming.
        let second = try harness.filesJob([source.appendingPathComponent("notes.txt")], destination: try RemotePath("Trip (2)"), verify: false)
        await queue.enqueue(second)
        await queue.waitUntilIdle()
        let secondJob = await queue.job(second.id)
        XCTAssertEqual(secondJob?.state, .complete)
        XCTAssertNotEqual(secondJob?.items.first?.finalPath, try RemotePath("Trip (2)/notes.txt"))

        do {
            try await provider.move(RemotePath("Trip (2)/notes.txt"), to: RemotePath("Trip (2)/Day 2/video.bin"))
            XCTFail("move must not overwrite")
        } catch FileCoreError.alreadyExists {}

        // Successful rename and move into a subfolder.
        try await provider.move(RemotePath("Trip (2)/notes.txt"), to: RemotePath("Trip (2)/renamed.txt"))
        let renamed = try await provider.item(at: RemotePath("Trip (2)/renamed.txt"))
        XCTAssertEqual(renamed?.size, Int64(files["Trip/notes.txt"]?.count ?? -1))
        try await provider.move(RemotePath("Trip (2)/renamed.txt"), to: RemotePath("Trip (2)/Day 1/renamed.txt"))
        let moved = try await provider.item(at: RemotePath("Trip (2)/Day 1/renamed.txt"))
        XCTAssertNotNil(moved)

        // Trash a folder and restore it from the managed Trash.
        try await provider.delete(RemotePath("Trip (2)/Day 2"))
        let trashed = try await provider.item(at: RemotePath("Trip (2)/Day 2"))
        XCTAssertNil(trashed)
        let trash = try await provider.trashItems()
        let entry = try XCTUnwrap(trash.first { $0.originalPath == (try? RemotePath("Trip (2)/Day 2")) })
        let restored = try await provider.restoreFromTrash(entry.id)
        XCTAssertEqual(restored, try RemotePath("Trip (2)/Day 2"))
        let video = try await provider.read(RemotePath("Trip (2)/Day 2/video.bin"), offset: 0, length: 2_000_000)
        XCTAssertEqual(video, files["Trip/Day 2/video.bin"])

        let history = try await root.snapshots()
        // Browse from "/" (some sources, like the Pi's test workspace, are empty).
        if let snapshot = history.first(where: { $0.source.contains("mac-workspace") }) ?? history.first {
            let top = try await root.snapshotEntries(snapshot.id, path: "/")
            XCTAssertFalse(top.isEmpty, "snapshot browsing")
            XCTAssertTrue(top.allSatisfy { $0.path.hasPrefix("/") })
        }
        XCTAssertFalse(history.isEmpty)
        let protection = try await root.protection()
        XCTAssertFalse(protection.isEmpty)

        try await root.delete(folder)
        let after = try await root.item(at: folder)
        XCTAssertNil(after, "the test folder is in the managed Trash")
    }
}
