@testable import BackupCore
import Foundation
import XCTest

/// Runs real restic against a disposable source and repository in a temp
/// directory. Never touches the existing backup repository.
final class ResticIntegrationTests: XCTestCase {
    private var temp: URL!
    private var paths: AgentPaths!
    private var source: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        guard ["/opt/homebrew/bin/restic", "/usr/local/bin/restic"].contains(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("restic is not installed")
        }
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("restic-it-\(UUID().uuidString)")
        paths = AgentPaths(home: temp.appendingPathComponent("home"))
        source = temp.appendingPathComponent("source")
        repository = temp.appendingPathComponent("repository")
        try paths.prepare()
        let files: [String: String] = [
            "Projects/app/main.swift": "print(\"hi\")\n",
            "Projects/app/Café ☕️.md": "notes\n",
            "Projects/data/blob.bin": String(repeating: "x", count: 200_000),
            "Other/readme.txt": "other\n",
        ]
        for (path, contents) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let secret = paths.secretsDirectory.appendingPathComponent("fixture.password")
        FileManager.default.createFile(atPath: secret.path, contents: Data("fixture-\(UUID().uuidString)\n".utf8), attributes: [.posixPermissions: 0o600])
    }

    override func tearDownWithError() throws {
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }

    private func makeJob(volumeUUID: String? = nil) throws -> BackupJobConfiguration {
        BackupJobConfiguration(
            id: "fixture", name: "Fixture", sourcePath: source.path,
            destination: .localRepository(path: repository.path, volumeUUID: try volumeUUID ?? VolumeIdentity.of(path: repository.path).uuid),
            password: .privateFile("fixture.password")
        )
    }

    func testBackupRestoreAndVerifyWithHomeServicesAbsent() async throws {
        let job = try makeJob()
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        runner.heartbeatInterval = 1
        try await runner.initializeRepository(job)

        let first = try await runner.run(job, reason: .catchUp)
        XCTAssertEqual(first.state, .succeeded)
        let snapshotID = try XCTUnwrap(first.snapshotID)
        XCTAssertNotNil(first.scheduler.lastScheduledSuccessAt)
        guard case .current = runner.status(job).protection else { return XCTFail("expected current protection") }

        let snapshots = try await runner.snapshots(job)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].tags?.contains("files-backups") == true)

        let target = temp.appendingPathComponent("restore-1").path
        try await runner.restore(job, snapshotID: snapshotID, target: target, include: nil)
        let report = try RestoreVerification.compare(source: source.path, restoreTarget: target, subpath: nil, snapshotTime: snapshots[0].time.addingTimeInterval(1))
        XCTAssertTrue(report.passed, "\(report)")
        XCTAssertEqual(report.matched, 4)

        // Restoring again into the now non-empty folder is refused.
        do {
            try await runner.restore(job, snapshotID: snapshotID, target: target, include: nil)
            XCTFail("restore into a non-empty folder must be refused")
        } catch BackupError.unsafeRestoreTarget {}

        // Second run is incremental and creates a new snapshot.
        try "changed\n".write(to: source.appendingPathComponent("Other/readme.txt"), atomically: true, encoding: .utf8)
        let second = try await runner.run(job, reason: .manual)
        XCTAssertNotEqual(second.snapshotID, snapshotID)
        let afterSecond = try await runner.snapshots(job)
        XCTAssertEqual(afterSecond.count, 2)

        // Retention preview is a dry run: nothing is removed.
        let preview = try await runner.forgetPreview(job)
        XCTAssertFalse(preview.isEmpty)
        let afterPreview = try await runner.snapshots(job)
        XCTAssertEqual(afterPreview.count, 2)

        let log = try String(contentsOf: paths.logsDirectory.appendingPathComponent("agent.log"), encoding: .utf8)
        XCTAssertFalse(log.contains(source.path), "logs must not contain source paths")
        let password = try String(contentsOf: paths.secretsDirectory.appendingPathComponent("fixture.password"), encoding: .utf8).trimmingCharacters(in: .newlines)
        XCTAssertFalse(log.contains(password))
        let statusJSON = try String(contentsOf: paths.statusFile(for: job.id), encoding: .utf8)
        XCTAssertFalse(statusJSON.contains(password))
    }

    /// Restic and the verifier must agree on what was excluded: anything
    /// restic skipped must also be skipped by verification, or a correct
    /// restore would be reported as missing files.
    func testVerificationSkipsExactlyWhatResticExcluded() async throws {
        let extra: [String: String] = [
            "Projects/app/node_modules/dep/index.js": "x\n",
            "Projects/app/cache.pyc": "x\n",
            "Projects/app/build/DerivedData-mac/Build/Products/App.app/bin": "x\n",
            "Projects/app/build/release.zip": "keep\n",
            "Temporary/scratch.txt": "x\n",
            "Projects/marked/.nobackup": "",
            "Projects/marked/file.txt": "x\n",
            "Projects/tool/.cache/CACHEDIR.TAG": "Signature: 8a477f597d28d172789f06886806bc55\n",
            "Projects/tool/.cache/blob": "x\n",
        ]
        for (path, contents) in extra {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        var job = try makeJob()
        job.excludes = ["**/node_modules", "**/*.pyc", "**/Build/Products", source.appendingPathComponent("Temporary").path]
        job.excludeCaches = true
        job.excludeIfPresent = [".nobackup"]
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        try await runner.initializeRepository(job)
        let status = try await runner.run(job, reason: .manual)
        let snapshotID = try XCTUnwrap(status.snapshotID)
        let target = temp.appendingPathComponent("restore-excl").path
        try await runner.restore(job, snapshotID: snapshotID, target: target, include: nil)
        let restored = URL(fileURLWithPath: target).appendingPathComponent(source.standardizedFileURL.path)
        for skipped in ["Projects/app/node_modules", "Projects/app/cache.pyc", "Projects/app/build/DerivedData-mac/Build/Products",
                        "Temporary", "Projects/marked/file.txt", "Projects/tool/.cache/blob"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent(skipped).path), "restic kept \(skipped)")
        }
        // restic keeps a marked folder and its marker file, nothing else in it.
        for kept in ["Projects/app/build/release.zip", "Projects/marked/.nobackup", "Projects/tool/.cache/CACHEDIR.TAG"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent(kept).path), kept)
        }
        let snapshot = try await runner.snapshots(job)[0]
        let report = try RestoreVerification.compare(source: source.path, restoreTarget: target, subpath: nil,
                                                     snapshotTime: snapshot.time.addingTimeInterval(1), rules: ExcludeRules(job: job))
        XCTAssertTrue(report.passed, "\(report)")
        XCTAssertEqual(report.matched, 7, "4 fixture files, release.zip, and the two marker files")
    }

    func testWrongVolumeBlocksBackup() async throws {
        let job = try makeJob(volumeUUID: "00000000-0000-0000-0000-000000000000")
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        do {
            try await runner.run(job, reason: .scheduled)
            XCTFail("backup must be blocked")
        } catch BackupError.destinationUnavailable {}
        XCTAssertEqual(runner.status(job).state, .blocked)
        let contents = try FileManager.default.contentsOfDirectory(atPath: repository.path)
        XCTAssertTrue(contents.isEmpty, "nothing written to the wrong volume")
    }

    func testMissingDiskBlocksBackup() async throws {
        var job = try makeJob()
        job.destination = .localRepository(path: "/Volumes/FilesBackups-Fixture-\(UUID().uuidString)/repo", volumeUUID: "x")
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        do {
            try await runner.run(job, reason: .scheduled)
            XCTFail("backup must be blocked")
        } catch BackupError.destinationUnavailable {}
    }

    func testOverlappingRunIsRefused() async throws {
        let job = try makeJob()
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        let held = try JobLock(url: paths.lockFile(for: job.id))
        defer { held.release() }
        do {
            try await runner.run(job, reason: .manual)
            XCTFail("overlapping run must be refused")
        } catch BackupError.alreadyRunning {}
    }

    func testLooselyPermissionedPasswordFileIsRefused() async throws {
        let job = try makeJob()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.secretsDirectory.appendingPathComponent("fixture.password").path)
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        do {
            try await runner.run(job, reason: .manual)
            XCTFail("must refuse")
        } catch BackupError.passwordUnavailable {}
    }

    func testHomeServicesDestinationIsReportedUnsupported() async throws {
        var job = try makeJob()
        job.destination = .homeServices(baseURL: "https://example.invalid")
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        do {
            try await runner.run(job, reason: .manual)
            XCTFail("must be unsupported")
        } catch BackupError.unsupported {}
    }

    func testTickRunsCatchUpOnceThenWaits() async throws {
        let job = try makeJob()
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        runner.networkCost = { NetworkCost.Snapshot(isExpensive: false, isConstrained: false, isSatisfied: true) }
        // Midday, well outside the 02:00 slot's grace window.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        runner.now = { noon }
        try await runner.initializeRepository(job)
        let boot = noon.addingTimeInterval(-60)
        await runner.tick(systemEvent: boot)
        let afterFirst = runner.status(job)
        XCTAssertEqual(afterFirst.state, .succeeded)
        XCTAssertEqual(afterFirst.reason, .catchUp)
        XCTAssertEqual(afterFirst.lastCheckPassed, true, "weekly integrity check ran after the first unattended backup")
        await runner.tick(systemEvent: boot)
        let snapshots = try await runner.snapshots(job)
        XCTAssertEqual(snapshots.count, 1, "no second run for the same trigger")
        XCTAssertNotNil(runner.status(job).nextScheduledAt)
    }
}

final class MeteredNetworkTests: XCTestCase {
    func testTickWaitsOnMeteredNetworkWithoutTouchingSchedulerState() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("metered-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("repo"), withIntermediateDirectories: true)
        let paths = AgentPaths(home: temp.appendingPathComponent("home"))
        try paths.prepare()
        var job = BackupJobConfiguration(id: "m", name: "M", sourcePath: temp.appendingPathComponent("src").path,
                                         destination: .localRepository(path: temp.appendingPathComponent("repo").path, volumeUUID: try VolumeIdentity.of(path: temp.path).uuid),
                                         password: .privateFile("p"))
        let runner = BackupRunner(paths: paths, configuration: AgentConfiguration(jobs: [job]))
        runner.networkCost = { NetworkCost.Snapshot(isExpensive: true, isConstrained: false, isSatisfied: true) }
        let before = runner.status(job).scheduler
        await runner.tick(systemEvent: Date())
        let after = runner.status(job)
        XCTAssertEqual(after.scheduler, before, "no slot or trigger consumed")
        XCTAssertTrue(after.message?.contains("unmetered") == true)
        XCTAssertNotEqual(after.state, .running)

        // Opting in lets the job proceed to the normal decision (which fails
        // here on the missing password, proving it was attempted).
        job.allowMeteredNetworks = true
        runner.configuration.jobs = [job]
        await runner.tick(systemEvent: Date())
        XCTAssertNotNil(runner.status(job).scheduler.lastAttemptAt)
    }

    func testOlderConfigurationsDecodeWithMeteredGuardOn() throws {
        let json = #"{"id":"x","name":"X","sourcePath":"/s","destination":{"localRepository":{"path":"/r","volumeUUID":"u"}},"password":{"privateFile":{"_0":"p"}},"schedule":{"hour":2,"minute":0},"excludes":[],"tags":[],"enabled":true}"#
        let job = try JSONDecoder().decode(BackupJobConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(job.allowMeteredNetworks)
    }
}
