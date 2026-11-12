@testable import BackupCore
import Foundation
import XCTest

final class ScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    func testSlotsAroundDaylightSavingTransitions() {
        let schedule = DailySchedule.default
        // Spring forward (Mar 8, 2026): 02:00 does not exist → 03:00 PDT.
        XCTAssertEqual(schedule.slot(onDayOf: date("2026-03-08T12:00:00-07:00"), calendar: calendar), date("2026-03-08T03:00:00-07:00"))
        // Fall back (Nov 1, 2026): 02:00 PST happens once, after 01:00–01:59 repeats.
        XCTAssertEqual(schedule.slot(onDayOf: date("2026-11-01T12:00:00-08:00"), calendar: calendar), date("2026-11-01T02:00:00-08:00"))
        // Ordinary day.
        XCTAssertEqual(schedule.nextSlot(after: date("2026-10-20T02:00:00-07:00"), calendar: calendar), date("2026-10-21T02:00:00-07:00"))
        XCTAssertEqual(schedule.mostRecentSlot(atOrBefore: date("2026-10-20T01:59:00-07:00"), calendar: calendar), date("2026-10-19T02:00:00-07:00"))
    }

    func testScheduledSlotRunsOnceAndNeverTwice() {
        var state = SchedulerState()
        state.lastScheduledSuccessAt = date("2026-10-19T02:05:00-07:00")
        let now = date("2026-10-20T02:00:30-07:00")
        let (first, updated) = Scheduler.decide(now: now, schedule: .default, state: state, systemEvent: nil, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(first, .run(.scheduled, slot: date("2026-10-20T02:00:00-07:00")))
        let (second, _) = Scheduler.decide(now: now.addingTimeInterval(900), schedule: .default, state: updated, systemEvent: nil, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(second, .wait(until: date("2026-10-21T02:00:00-07:00")))
    }

    func testOneCatchUpAfterWakeWhenNoRecentScheduledSnapshot() {
        var state = SchedulerState()
        state.lastHandledSlot = date("2026-10-18T02:00:00-07:00")
        state.lastScheduledSuccessAt = date("2026-10-18T02:30:00-07:00")
        // Mac was asleep at 02:00 on Oct 19 and Oct 20; wakes at 08:10 Oct 20.
        let wake = date("2026-10-20T08:10:00-07:00")
        let now = date("2026-10-20T08:15:00-07:00")
        let (decision, state1) = Scheduler.decide(now: now, schedule: .default, state: state, systemEvent: wake, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(decision, .run(.catchUp, slot: nil))

        // The catch-up failed; the next tick must not retry for the same wake.
        let (again, state2) = Scheduler.decide(now: now.addingTimeInterval(900), schedule: .default, state: state1, systemEvent: wake, destinationAvailable: true, calendar: calendar)
        guard case .wait = again else { return XCTFail("expected wait, got \(again)") }

        // A later wake allows one more attempt.
        let laterWake = date("2026-10-20T13:00:00-07:00")
        let (third, _) = Scheduler.decide(now: laterWake.addingTimeInterval(60), schedule: .default, state: state2, systemEvent: laterWake, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(third, .run(.catchUp, slot: nil))
    }

    func testNoCatchUpWhenScheduledSnapshotIsRecent() {
        var state = SchedulerState()
        state.lastHandledSlot = date("2026-10-20T02:00:00-07:00")
        state.lastScheduledSuccessAt = date("2026-10-20T02:20:00-07:00")
        let wake = date("2026-10-20T09:00:00-07:00")
        let (decision, _) = Scheduler.decide(now: wake.addingTimeInterval(60), schedule: .default, state: state, systemEvent: wake, destinationAvailable: true, calendar: calendar)
        guard case .wait = decision else { return XCTFail("expected wait, got \(decision)") }
    }

    func testManualSnapshotDoesNotSatisfyScheduledCatchUp() {
        var state = SchedulerState()
        state = Scheduler.record(success: true, reason: .manual, snapshotID: "abcdef12", finishedAt: date("2026-10-20T07:00:00-07:00"), state: state)
        XCTAssertNotNil(state.lastSuccessAt)
        XCTAssertNil(state.lastScheduledSuccessAt)
        let wake = date("2026-10-20T08:00:00-07:00")
        let (decision, _) = Scheduler.decide(now: wake.addingTimeInterval(60), schedule: .default, state: state, systemEvent: wake, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(decision, .run(.catchUp, slot: nil))
    }

    func testDestinationReconnectTriggersCatchUp() {
        var state = SchedulerState()
        state.lastScheduledSuccessAt = date("2026-10-18T02:10:00-07:00")
        state.lastCatchUpTrigger = date("2026-10-19T09:00:00-07:00")
        let boot = date("2026-10-19T09:00:00-07:00")
        let t1 = date("2026-10-20T10:00:00-07:00")
        let (waiting, state1) = Scheduler.decide(now: t1, schedule: .default, state: state, systemEvent: boot, destinationAvailable: false, calendar: calendar)
        XCTAssertEqual(waiting, .waitForDestination)
        let t2 = t1.addingTimeInterval(900)
        let (decision, state2) = Scheduler.decide(now: t2, schedule: .default, state: state1, systemEvent: boot, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(decision, .run(.catchUp, slot: nil))
        XCTAssertEqual(state2.lastReconnectAt, t2)
    }

    func testWarningAfterTwentySixHoursAcrossDST() {
        // 25 wall-clock hours across fall-back is 26 real hours: still current
        // at exactly 26 h, overdue after.
        let last = date("2026-10-31T02:00:00-07:00")
        XCTAssertEqual(ProtectionStatus.evaluate(lastSuccess: last, now: last.addingTimeInterval(26 * 3600)), .current(lastSuccess: last))
        guard case .overdue(_, let hours) = ProtectionStatus.evaluate(lastSuccess: last, now: last.addingTimeInterval(26 * 3600 + 60)) else {
            return XCTFail("expected overdue")
        }
        XCTAssertEqual(hours, 26)
        XCTAssertEqual(ProtectionStatus.evaluate(lastSuccess: nil, now: last), .unprotected)
    }

    func testStaleRunningStatusBecomesInterrupted() {
        var status = JobStatus(jobID: "mac", jobName: "Mac")
        status.state = .running
        status.heartbeatAt = Date().addingTimeInterval(-600)
        XCTAssertEqual(status.normalized(now: Date()).state, .interrupted)
        status.heartbeatAt = Date()
        XCTAssertEqual(status.normalized(now: Date()).state, .running)
    }
}

final class ResticParsingTests: XCTestCase {
    func testParsesStatusSummaryAndErrorLines() {
        XCTAssertEqual(
            ResticOutput.parse(line: #"{"message_type":"status","percent_done":0.5,"total_files":10,"files_done":5,"total_bytes":100,"bytes_done":50}"#),
            .status(JobProgress(filesDone: 5, totalFiles: 10, bytesDone: 50, totalBytes: 100, percentDone: 0.5))
        )
        XCTAssertEqual(
            ResticOutput.parse(line: #"{"message_type":"summary","files_new":3,"files_changed":1,"data_added":42,"snapshot_id":"4515c74846f53f1e"}"#),
            .summary(snapshotID: "4515c74846f53f1e", filesNew: 3, filesChanged: 1, dataAdded: 42)
        )
        XCTAssertEqual(ResticOutput.parse(line: #"{"message_type":"error","error":{"message":"permission denied"},"during":"scan"}"#), .error("permission denied"))
        XCTAssertNil(ResticOutput.parse(line: "not json"))
    }

    func testParsesSnapshotsWithNanosecondTimes() throws {
        let json = #"[{"time":"2026-09-09T03:14:15.123456789-07:00","hostname":"mac","paths":["/src"],"tags":["files-backups"],"id":"4515c74846f53f1e9cc02631c6e74d0594c105c60ecbb5876f35eeaba39a8fc6","short_id":"4515c748"}]"#
        let snapshots = try ResticOutput.parseSnapshots(Data(json.utf8))
        XCTAssertEqual(snapshots.first?.shortID, "4515c748")
        XCTAssertEqual(snapshots.first?.time.timeIntervalSince1970 ?? 0, 1788948855.123, accuracy: 0.001)
    }

    func testCommandsUseFixedArgvAndRejectSelectors() throws {
        XCTAssertThrowsError(try ResticCommand.validateSnapshotID("latest"))
        XCTAssertThrowsError(try ResticCommand.validateSnapshotID("--target=/"))
        XCTAssertEqual(try ResticCommand.validateSnapshotID("ABCDEF12"), "abcdef12")
        let job = BackupJobConfiguration(id: "mac", name: "Mac", sourcePath: "/src", destination: .localRepository(path: "/r", volumeUUID: "u"), password: .privateFile("p"), excludes: ["*.tmp"])
        let args = ResticCommand.backup(job, host: "h")
        XCTAssertEqual(Array(args.suffix(2)), ["--", "/src"], "source is never parsed as an option")
        XCTAssertTrue(args.contains("job-mac"))
        XCTAssertTrue(ResticCommand.forgetPreview(job, policy: RetentionPolicy()).contains("--dry-run"))
        XCTAssertThrowsError(try BackupJobConfiguration.validate(id: "../etc"))
    }

    func testRestoreSafetyRefusesLiveSource() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-safety-\(UUID().uuidString)")
        let source = temp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertThrowsError(try RestoreSafety.validate(target: source.path, source: source.path))
        XCTAssertThrowsError(try RestoreSafety.validate(target: source.appendingPathComponent("restore").path, source: source.path))
        XCTAssertThrowsError(try RestoreSafety.validate(target: temp.path, source: source.path))
        XCTAssertNoThrow(try RestoreSafety.validate(target: temp.appendingPathComponent("restore").path, source: source.path))
    }
}

final class RemoteVolumeTests: XCTestCase {
    func testRemotePathsCannotInjectShellCommands() {
        for bad in ["/mnt/x; rm -rf /", "/mnt/$(id)", "relative/path", "/mnt/../etc", "/mnt/a b", "/mnt/`x`"] {
            XCTAssertThrowsError(try RemoteVolume.validate(path: bad), bad)
        }
        XCTAssertNoThrow(try RemoteVolume.validate(path: "/mnt/workspace-backup/files-backups/mac-projects"))
    }

    func testRepositoryMustBeInsideMountPoint() {
        XCTAssertThrowsError(try RemoteVolume.require(user: "u", host: "h", path: "/mnt/other/repo", mountPoint: "/mnt/workspace-backup", uuid: "x")) { error in
            guard case BackupError.invalidConfiguration = error else { return XCTFail("\(error)") }
        }
    }
}

final class RetryTests: XCTestCase {
    func testFailedScheduledRunRetriesWithBackoffThenStops() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let failedAt = ISO8601DateFormatter().date(from: "2026-10-20T16:26:00Z")!
        var state = SchedulerState()
        state.lastHandledSlot = failedAt.addingTimeInterval(-3600)
        state.lastCatchUpTrigger = failedAt.addingTimeInterval(-3600)
        state = Scheduler.record(success: false, reason: .catchUp, snapshotID: nil, finishedAt: failedAt, state: state)
        XCTAssertEqual(state.consecutiveFailures, 1)

        let (tooSoon, _) = Scheduler.decide(now: failedAt.addingTimeInterval(600), schedule: .default, state: state, systemEvent: nil, destinationAvailable: true, calendar: calendar)
        guard case .wait = tooSoon else { return XCTFail("\(tooSoon)") }
        let (retry, afterRetry) = Scheduler.decide(now: failedAt.addingTimeInterval(16 * 60), schedule: .default, state: state, systemEvent: nil, destinationAvailable: true, calendar: calendar)
        XCTAssertEqual(retry, .run(.retry, slot: nil))

        var exhausted = afterRetry
        for _ in 0..<3 { exhausted = Scheduler.record(success: false, reason: .retry, snapshotID: nil, finishedAt: failedAt, state: exhausted) }
        XCTAssertEqual(exhausted.consecutiveFailures, 4)
        let (stop, _) = Scheduler.decide(now: failedAt.addingTimeInterval(6 * 3600), schedule: .default, state: exhausted, systemEvent: nil, destinationAvailable: true, calendar: calendar)
        guard case .wait = stop else { return XCTFail("retries are bounded: \(stop)") }

        let recovered = Scheduler.record(success: true, reason: .retry, snapshotID: "abcdef12", finishedAt: failedAt, state: exhausted)
        XCTAssertEqual(recovered.consecutiveFailures, 0)
        XCTAssertNotNil(recovered.lastScheduledSuccessAt)
    }

    func testManualFailureDoesNotScheduleRetries() {
        let state = Scheduler.record(success: false, reason: .manual, snapshotID: nil, finishedAt: Date(), state: SchedulerState())
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testOlderStatusFilesDecodeWithoutRetryFields() throws {
        let json = #"{"lastSuccessAt":"2026-10-20T16:51:39Z","destinationWasAvailable":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SchedulerState.self, from: Data(json.utf8))
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertNotNil(state.lastSuccessAt)
    }

    func testSFTPJobsGetSSHKeepalives() {
        let sftp = BackupJobConfiguration(id: "p", name: "P", sourcePath: "/s", destination: .sftpRepository(user: "u", host: "h", path: "/m/r", mountPoint: "/m", volumeUUID: "x"), password: .privateFile("p"))
        XCTAssertTrue(ResticCommand.backup(sftp, host: "mac").joined(separator: " ").contains("ServerAliveInterval"))
        let local = BackupJobConfiguration(id: "l", name: "L", sourcePath: "/s", destination: .localRepository(path: "/r", volumeUUID: "u"), password: .privateFile("p"))
        XCTAssertFalse(ResticCommand.backup(local, host: "mac").joined(separator: " ").contains("sftp.args"))
    }
}
