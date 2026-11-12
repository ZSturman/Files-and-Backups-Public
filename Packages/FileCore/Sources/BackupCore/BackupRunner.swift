import Foundation
#if os(macOS)
import Darwin
import Foundation

/// Executes companion jobs: one restic process per job, never overlapping,
/// with a heartbeat that also re-checks the destination volume.
public final class BackupRunner: @unchecked Sendable {
    public let paths: AgentPaths
    public var configuration: AgentConfiguration
    public var now: @Sendable () -> Date = { Date() }
    public var calendar = Calendar.current
    public var heartbeatInterval: TimeInterval = 15
    private let statusStore: StatusStore
    private let logger: AgentLogger

    public init(paths: AgentPaths, configuration: AgentConfiguration) {
        self.paths = paths
        self.configuration = configuration
        self.statusStore = StatusStore(paths: paths)
        self.logger = AgentLogger(paths: paths)
    }

    public func job(_ id: String) throws -> BackupJobConfiguration {
        guard let job = configuration.jobs.first(where: { $0.id == id }) else {
            throw BackupError.invalidConfiguration("no job named \(id)")
        }
        return job
    }

    public func status(_ job: BackupJobConfiguration) -> JobStatus {
        statusStore.load(job).normalized(now: now())
    }

    // MARK: Scheduling

    /// Periodic entry point (launchd): runs each due job once, sequentially.
    /// Network cost source; overridable in tests.
    public var networkCost: @Sendable () -> NetworkCost.Snapshot? = { NetworkCost.current() }

    public func tick(systemEvent: Date?) async {
        let cost = configuration.jobs.contains(where: { $0.enabled && !$0.allowMeteredNetworks }) ? networkCost() : nil
        for job in configuration.jobs where job.enabled {
            var status = statusStore.load(job).normalized(now: now())
            if status.state == .running { continue }
            // Unattended runs wait for an unmetered network; scheduler state
            // is left untouched so the run happens once the Mac is back on
            // Wi-Fi/Ethernet (slot within its grace window, else catch-up).
            if !job.allowMeteredNetworks, let cost, cost.metered {
                let message = "Waiting for an unmetered network (\(cost.isExpensive ? "hotspot or cellular" : "Low Data Mode")). Run manually to back up now."
                if status.message != message {
                    status.message = message
                    statusStore.save(status)
                    logger.log("job \(job.id): skipped tick on a metered network")
                }
                continue
            }
            let available = (try? validateDestination(job)) != nil
            let (decision, scheduler) = Scheduler.decide(
                now: now(), schedule: job.schedule, state: status.scheduler,
                systemEvent: systemEvent, destinationAvailable: available, calendar: calendar
            )
            status.scheduler = scheduler
            status.nextScheduledAt = job.schedule.nextSlot(after: now(), calendar: calendar)
            switch decision {
            case .run(let reason, _):
                statusStore.save(status)
                logger.log("job \(job.id): starting \(reason.rawValue) run")
                if (try? await run(job, reason: reason)) != nil {
                    await weeklyCheckIfDue(job)
                }
            case .waitForDestination:
                if status.state != .blocked {
                    status.state = .blocked
                    status.message = "Waiting for the backup destination to be connected."
                }
                statusStore.save(status)
            case .wait:
                statusStore.save(status)
            }
        }
    }

    /// Read-only integrity check at most once a week, after a successful
    /// unattended backup (metadata plus a 2% sample of pack data).
    public static let checkInterval: TimeInterval = 7 * 24 * 3600

    func weeklyCheckIfDue(_ job: BackupJobConfiguration) async {
        var status = statusStore.load(job)
        if let last = status.lastCheckAt, now().timeIntervalSince(last) < Self.checkInterval { return }
        logger.log("job \(job.id): starting weekly read-only integrity check")
        do {
            let output = try await check(job, readDataSubset: "2%")
            let text = String(decoding: output, as: UTF8.self)
            status = statusStore.load(job)
            status.lastCheckAt = now()
            status.lastCheckPassed = text.contains("no errors were found")
            status.lastCheckMessage = status.lastCheckPassed == true ? "No errors found (2% of data read back)." : redact(String(text.suffix(400)), sourcePath: job.sourcePath)
        } catch {
            status = statusStore.load(job)
            status.lastCheckAt = now()
            status.lastCheckPassed = false
            status.lastCheckMessage = redact((error as? LocalizedError)?.errorDescription ?? "\(error)", sourcePath: job.sourcePath)
        }
        statusStore.save(status)
        logger.log("job \(job.id): integrity check \(status.lastCheckPassed == true ? "passed" : "FAILED")")
    }

    // MARK: Backup

    @discardableResult
    public func run(_ job: BackupJobConfiguration, reason: RunReason) async throws -> JobStatus {
        try paths.prepare()
        let lock = try JobLock(url: paths.lockFile(for: job.id))
        defer { lock.release() }

        var status = statusStore.load(job)
        status.state = .running
        status.reason = reason
        status.runID = UUID().uuidString.lowercased()
        status.startedAt = now()
        status.heartbeatAt = now()
        status.lastProgressAt = nil
        status.progress = nil
        status.finishedAt = nil
        status.snapshotID = nil
        status.message = nil
        status.pid = nil
        statusStore.save(status)

        let reporter = makeReporter(for: job)
        var reportRunID: String?
        if let reporter, let sourceID = await reporter.register(job, host: hostName) {
            rememberSourceID(sourceID, for: job)
            reportRunID = await reporter.start(sourceID: sourceID, runKey: "\(job.id)-\(status.runID ?? UUID().uuidString)")
        }
        // Heartbeats renew the 900 s lease every 5 minutes.
        let reportHeartbeats = Task { [statusStore] in
            guard let reporter, let reportRunID else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { break }
                await reporter.heartbeat(runID: reportRunID, progress: statusStore.load(job).progress)
            }
        }

        var failure: (any Error)?
        do {
            try validateSource(job)
            let repository = try validateDestination(job)
            let environment = try resticEnvironment(job, repository: repository)
            let result = try await execute(
                ResticCommand.backup(job, host: hostName),
                environment: environment, job: job, status: &status, guardVolume: true
            )
            guard result.code == 0 || result.code == 3, let snapshotID = result.snapshotID else {
                throw BackupError.resticFailed(code: result.code, message: redact(result.tail, sourcePath: job.sourcePath))
            }
            status.state = .succeeded
            status.snapshotID = snapshotID
            // Exit 3: snapshot created but some files could not be read.
            status.message = result.code == 3 ? "Snapshot created, but some source files could not be read." : nil
            status.finishedAt = now()
            status.scheduler = Scheduler.record(success: true, reason: reason, snapshotID: snapshotID, finishedAt: now(), state: status.scheduler)
            logger.log("job \(job.id): snapshot \(snapshotID.prefix(8)) created (\(reason.rawValue))")
            // restic occasionally leaves its own lock behind over SFTP; remove
            // only stale locks (dead local processes or >30 min unrefreshed).
            _ = try? await removeStaleLocks(job)
        } catch let error as BackupError {
            status.scheduler = Scheduler.record(success: false, reason: reason, snapshotID: nil, finishedAt: now(), state: status.scheduler)
            switch error {
            case .destinationUnavailable, .sourceUnavailable, .alreadyRunning, .passwordUnavailable, .resticMissing:
                status.state = .blocked
            default:
                status.state = .failed
            }
            status.message = redact(error.errorDescription ?? "\(error)", sourcePath: job.sourcePath)
            status.finishedAt = now()
            failure = error
            logger.log("job \(job.id): \(status.state.rawValue): \(status.message ?? "")")
        } catch {
            failure = error
            status.scheduler = Scheduler.record(success: false, reason: reason, snapshotID: nil, finishedAt: now(), state: status.scheduler)
            status.state = .failed
            status.message = redact(error.localizedDescription, sourcePath: job.sourcePath)
            status.finishedAt = now()
            logger.log("job \(job.id): failed: \(status.message ?? "")")
        }
        status.pid = nil
        status.heartbeatAt = now()
        status.nextScheduledAt = job.schedule.nextSlot(after: now(), calendar: calendar)
        statusStore.save(status)
        reportHeartbeats.cancel()
        if let reporter, let reportRunID {
            await reporter.finish(runID: reportRunID, succeeded: status.state == .succeeded, snapshotID: status.snapshotID,
                                  totals: status.progress, message: status.message)
        }
        if let failure { throw failure }
        return status
    }

    var hostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// A reporter only when reporting is enabled for this job and its token
    /// file is present with owner-only permissions.
    func makeReporter(for job: BackupJobConfiguration) -> StatusReporter? {
        guard let reporting = configuration.reporting, reporting.jobs.contains(job.id),
              !reporting.tokenFile.contains("/") else { return nil }
        let url = paths.secretsDirectory.appendingPathComponent(reporting.tokenFile)
        guard let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            logger.log("reporting: token file missing or not owner-only; skipping report for \(job.id)")
            return nil
        }
        return StatusReporter(configuration: reporting, token: token, session: reportingSession) { [logger] in logger.log($0) }
    }

    /// Overridable for tests.
    public var reportingSession: URLSession = .shared

    func rememberSourceID(_ sourceID: String, for job: BackupJobConfiguration) {
        guard configuration.reporting?.sourceIDs[job.id] != sourceID else { return }
        configuration.reporting?.sourceIDs[job.id] = sourceID
        // Merge into the on-disk configuration so other edits are kept.
        if var saved = try? paths.loadConfiguration() {
            saved.reporting?.sourceIDs[job.id] = sourceID
            try? paths.saveConfiguration(saved)
        }
    }

    func validateSource(_ job: BackupJobConfiguration) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: job.sourcePath, isDirectory: &isDirectory) else {
            throw BackupError.sourceUnavailable("the source folder does not exist")
        }
        if isDirectory.boolValue {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: job.sourcePath)
            } catch {
                throw BackupError.sourceUnavailable("the source folder cannot be read; grant Full Disk Access to fbbackup-agent if it is protected")
            }
        }
    }

    /// Returns the repository location after checking it is safe to write.
    @discardableResult
    func validateDestination(_ job: BackupJobConfiguration) throws -> String {
        switch job.destination {
        case .localRepository(let path, let uuid):
            try VolumeIdentity.require(path: path, uuid: uuid)
            let source = URL(fileURLWithPath: job.sourcePath).standardizedFileURL.path
            let repository = URL(fileURLWithPath: path).standardizedFileURL.path
            if repository == source || repository.hasPrefix(source + "/") {
                throw BackupError.invalidConfiguration("the repository cannot be inside the source")
            }
            return path
        case .sftpRepository(let user, let host, let path, let mountPoint, let uuid):
            try RemoteVolume.require(user: user, host: host, path: path, mountPoint: mountPoint, uuid: uuid)
            return "sftp:\(user)@\(host):\(path)"
        case .homeServices:
            throw BackupError.unsupported("Home Services backup destinations need the Home Services v1 backup contract, which is not published yet")
        }
    }

    func resolvePassword(_ job: BackupJobConfiguration) throws -> String {
        switch job.password {
        case .privateFile(let name):
            guard !name.contains("/"), !name.hasPrefix(".") else { throw BackupError.passwordUnavailable("invalid secret name") }
            let url = paths.secretsDirectory.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let permissions = attributes?[.posixPermissions] as? NSNumber else {
                throw BackupError.passwordUnavailable("the private password file is missing")
            }
            guard permissions.intValue & 0o077 == 0 else {
                throw BackupError.passwordUnavailable("the password file must be readable only by its owner (chmod 600)")
            }
            guard let password = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines), !password.isEmpty else {
                throw BackupError.passwordUnavailable("the private password file is empty")
            }
            return password
        case .command(let argv):
            guard let executable = argv.first, executable.hasPrefix("/") else {
                throw BackupError.passwordUnavailable("the password command must use an absolute path")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(argv.dropFirst())
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let password = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !password.isEmpty else {
                throw BackupError.passwordUnavailable("the password command failed")
            }
            return password
        }
    }

    func resticExecutable() throws -> String {
        let candidates = [configuration.resticPath, "/opt/homebrew/bin/restic", "/usr/local/bin/restic"].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BackupError.resticMissing
        }
        return found
    }

    func resticEnvironment(_ job: BackupJobConfiguration, repository: String) throws -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "RESTIC_REPOSITORY": repository,
            "RESTIC_PASSWORD": try resolvePassword(job),
            "RESTIC_PROGRESS_FPS": "0.2",
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = tmp }
        return environment
    }

    struct ExecutionResult {
        var code: Int32
        var snapshotID: String?
        var tail: String
        var stdout: Data
    }

    /// Runs restic, streaming `--json` progress into the status record. The
    /// heartbeat continues during silent phases and terminates restic if the
    /// destination volume disappears.
    func execute(
        _ arguments: [String], environment: [String: String], job: BackupJobConfiguration,
        status: inout JobStatus, guardVolume: Bool
    ) async throws -> ExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resticExecutable())
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let shared = SharedRunState(status: status)
        let stderrCollector = TailCollector(limit: 4000)
        let exitCode = ExitCode()
        process.terminationHandler = { process in exitCode.finish(process.terminationStatus) }

        try process.run()
        // Drain stderr on its own thread so a chatty restic never blocks.
        let stderrDone = ExitCode()
        let stderrHandle = stderr.fileHandleForReading
        DispatchQueue.global().async {
            while let data = try? stderrHandle.read(upToCount: 4096), !data.isEmpty {
                stderrCollector.append(data)
            }
            stderrDone.finish(0)
        }
        ActiveChild.shared.set(process) { [statusStore, now] in
            // Called on SIGTERM after restic stopped: record the interruption
            // now instead of waiting for the heartbeat deadline.
            shared.update {
                $0.state = .interrupted
                $0.pid = nil
                $0.finishedAt = now()
                $0.message = "The backup was stopped before it finished (system shutdown, logout, or a stop request). No snapshot was created."
            }
            statusStore.save(shared.snapshot())
        }
        defer { ActiveChild.shared.set(nil, onTerminate: nil) }
        shared.update { $0.pid = process.processIdentifier }
        statusStore.save(shared.snapshot())

        let heartbeat = DispatchSource.makeTimerSource(queue: .global())
        heartbeat.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        var beats = 0
        let remote: Bool = { if case .sftpRepository = job.destination { return true } else { return false } }()
        heartbeat.setEventHandler { [self] in
            beats += 1
            // Remote checks cost an SSH round trip: check every 4th beat.
            if guardVolume, !remote || beats % 4 == 0, (try? validateDestination(job)) == nil {
                shared.update { $0.message = "The backup destination disappeared during the run." }
                shared.volumeLost = true
                process.interrupt()
            }
            shared.update { $0.heartbeatAt = now() }
            statusStore.save(shared.snapshot())
        }
        heartbeat.resume()
        defer { heartbeat.cancel() }

        var output = Data()
        var snapshotID: String?
        var lastSave = Date.distantPast
        for try await line in stdout.fileHandleForReading.bytes.lines {
            output.append(Data((line + "\n").utf8))
            switch ResticOutput.parse(line: line) {
            case .status(let progress):
                shared.update {
                    $0.progress = progress
                    $0.lastProgressAt = now()
                    $0.heartbeatAt = now()
                }
                if Date().timeIntervalSince(lastSave) >= 2 {
                    statusStore.save(shared.snapshot())
                    lastSave = Date()
                }
            case .summary(let id, _, _, _):
                snapshotID = id
                if let totals = ResticOutput.summaryTotals(line: line) { shared.update { $0.progress = totals } }
            case .error(let message):
                stderrCollector.append(Data((message + "\n").utf8))
            case nil:
                break
            }
        }
        let code = await exitCode.value()
        // A lingering child (e.g. restic's ssh) must not hang the agent.
        for _ in 0..<50 where !stderrDone.isFinished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        status = shared.snapshot()
        if shared.volumeLost {
            throw BackupError.destinationUnavailable("the backup destination disappeared during the run")
        }
        return ExecutionResult(code: code, snapshotID: snapshotID, tail: stderrCollector.text, stdout: output)
    }

    /// Runs a short restic command and returns stdout.
    func runCapturing(_ arguments: [String], job: BackupJobConfiguration) async throws -> Data {
        let repository = try validateDestination(job)
        var status = statusStore.load(job)
        let arguments = ResticCommand.backendOptions(job) + arguments
        let result = try await execute(arguments, environment: try resticEnvironment(job, repository: repository), job: job, status: &status, guardVolume: false)
        guard result.code == 0 else {
            throw BackupError.resticFailed(code: result.code, message: redact(result.tail, sourcePath: job.sourcePath))
        }
        return result.stdout
    }

    // MARK: Repository, history, restore

    /// Creates a new repository only at an empty or absent location.
    public func initializeRepository(_ job: BackupJobConfiguration) async throws {
        switch job.destination {
        case .localRepository(let path, _):
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            guard contents.filter({ $0 != ".DS_Store" }).isEmpty else {
                throw BackupError.invalidConfiguration("the repository folder is not empty; use the existing repository instead of creating one")
            }
        case .sftpRepository(let user, let host, let path, _, _):
            guard try RemoteVolume.isAbsentOrEmpty(user: user, host: host, path: path) else {
                throw BackupError.invalidConfiguration("the remote repository folder exists and is not empty; refusing to create a repository there")
            }
        case .homeServices:
            throw BackupError.unsupported("the companion cannot create Home Services repositories")
        }
        _ = try await runCapturing(ResticCommand.initialize, job: job)
    }

    public func snapshots(_ job: BackupJobConfiguration) async throws -> [ResticSnapshot] {
        try ResticOutput.parseSnapshots(try await runCapturing(ResticCommand.snapshots(job), job: job))
    }

    /// Read-only repository integrity check (`restic check`, metadata plus
    /// an optional data subset). Never modifies snapshots.
    public func check(_ job: BackupJobConfiguration, readDataSubset: String?) async throws -> Data {
        var arguments = ["check"]
        if let readDataSubset { arguments += ["--read-data-subset", readDataSubset] }
        return try await runCapturing(arguments, job: job)
    }

    /// `restic unlock` without --remove-all: deletes only stale locks; never
    /// snapshots or data.
    @discardableResult
    public func removeStaleLocks(_ job: BackupJobConfiguration) async throws -> Data {
        try await runCapturing(["unlock"], job: job)
    }

    public func forgetPreview(_ job: BackupJobConfiguration, policy: RetentionPolicy = RetentionPolicy()) async throws -> Data {
        try await runCapturing(ResticCommand.forgetPreview(job, policy: policy), job: job)
    }

    /// Restores a snapshot into a new or empty folder. Never restores into,
    /// over, or above the live source.
    public func restore(_ job: BackupJobConfiguration, snapshotID: String, target: String, include: String?) async throws {
        try RestoreSafety.validate(target: target, source: job.sourcePath)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try JobLock(url: paths.lockFile(for: job.id))
        defer { lock.release() }
        _ = try await runCapturing(try ResticCommand.restore(snapshotID: snapshotID, target: target, include: include), job: job)
        logger.log("job \(job.id): restored snapshot \(snapshotID.prefix(8)) into a new folder")
    }
}

/// Destination identity for SFTP repositories, checked over SSH with fixed
/// arguments (no remote shell interpolation of user input beyond validated
/// absolute paths).
public enum RemoteVolume {
    static func validate(path: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_."))
        guard path.hasPrefix("/"), !path.contains(".."), path.unicodeScalars.allSatisfy(allowed.contains) else {
            throw BackupError.invalidConfiguration("remote paths must be absolute and use letters, digits, / - _ .")
        }
    }

    static func ssh(user: String, host: String, _ command: String, timeout: Int = 15) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "-o", "StrictHostKeyChecking=yes", "\(user)@\(host)", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// UUID of the filesystem mounted exactly at `mountPoint`, or nil.
    public static func uuid(user: String, host: String, mountPoint: String) throws -> String? {
        try validate(path: mountPoint)
        let (code, output) = try ssh(user: user, host: host, "findmnt -no UUID --mountpoint \(mountPoint)")
        // ssh exits 255 for connection/authentication/host-key failures;
        // findmnt exits 1 when nothing is mounted there.
        if code == 255 { throw BackupError.destinationUnavailable("cannot reach \(host) over SSH (offline, asleep, or key/host-key rejected)") }
        guard code == 0, !output.isEmpty else { return nil }
        return output
    }

    public static func require(user: String, host: String, path: String, mountPoint: String, uuid expected: String) throws {
        try validate(path: path)
        guard path == mountPoint || path.hasPrefix(mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/") else {
            throw BackupError.invalidConfiguration("the repository is not inside the configured mount point")
        }
        let found: String?
        do {
            found = try uuid(user: user, host: host, mountPoint: mountPoint)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.destinationUnavailable("cannot reach \(host) over SSH")
        }
        guard let found else { throw BackupError.destinationUnavailable("the backup disk is not mounted on \(host)") }
        guard found == expected else { throw BackupError.destinationUnavailable("a different disk is mounted on \(host)") }
    }

    static func isAbsentOrEmpty(user: String, host: String, path: String) throws -> Bool {
        try validate(path: path)
        let (code, output) = try ssh(user: user, host: host, "test ! -e \(path) && echo absent || ls -A \(path) | head -1")
        guard code == 0 else { throw BackupError.destinationUnavailable("cannot inspect \(path) on \(host)") }
        return output == "absent" || output.isEmpty
    }
}

/// Prevents two runs of the same job, across processes, with flock(2).
final class JobLock {
    private let fd: Int32

    init(url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw BackupError.invalidConfiguration("cannot open the job lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw BackupError.alreadyRunning
        }
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

public enum RestoreSafety {
    public static func validate(target: String, source: String) throws {
        let target = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath().path
        let source = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path
        if target == source || target.hasPrefix(source + "/") {
            throw BackupError.unsafeRestoreTarget("the target is inside the live source")
        }
        if source.hasPrefix(target + "/") || target == "/" {
            throw BackupError.unsafeRestoreTarget("the target contains the live source")
        }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: target), !contents.filter({ $0 != ".DS_Store" }).isEmpty {
            throw BackupError.unsafeRestoreTarget("the target folder is not empty")
        }
    }
}

public struct RestoreVerification: Codable, Sendable {
    public var filesCompared = 0
    public var matched = 0
    public var mismatched: [String] = []
    public var missingFromRestore: [String] = []
    public var changedSinceSnapshot: [String] = []

    public var passed: Bool { filesCompared > 0 && mismatched.isEmpty && missingFromRestore.isEmpty }

    /// Compares SHA-256 of each live source file under `subpath` with its
    /// restored copy. Files modified after the snapshot are reported
    /// separately instead of counting as mismatches.
    public static func compare(source: String, restoreTarget: String, subpath: String?, snapshotTime: Date, excludes: [String] = []) throws -> RestoreVerification {
        try compare(source: source, restoreTarget: restoreTarget, subpath: subpath, snapshotTime: snapshotTime, rules: ExcludeRules(patterns: excludes))
    }

    public static func compare(source: String, restoreTarget: String, subpath: String?, snapshotTime: Date, rules: ExcludeRules) throws -> RestoreVerification {
        var result = RestoreVerification()
        let sourceRoot = URL(fileURLWithPath: source).standardizedFileURL
        let base = subpath.map { sourceRoot.appendingPathComponent($0) } ?? sourceRoot
        let restoredRoot = URL(fileURLWithPath: restoreTarget).appendingPathComponent(sourceRoot.path)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]) else {
            throw BackupError.sourceUnavailable("cannot enumerate the source for verification")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
            // Paths the job excludes were never backed up.
            let isDirectory = values.isDirectory == true
            if rules.excludes(url, isDirectory: isDirectory) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(sourceRoot.path.count + 1))
            result.filesCompared += 1
            if let modified = values.contentModificationDate, modified > snapshotTime {
                result.changedSinceSnapshot.append(relative)
                continue
            }
            let restored = restoredRoot.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: restored.path) else {
                result.missingFromRestore.append(relative)
                continue
            }
            if try sha256(url) == sha256(restored) {
                result.matched += 1
            } else {
                result.mismatched.append(relative)
            }
        }
        return result
    }
}

/// Delivers a process exit status to async code without blocking a thread.
final class ExitCode: @unchecked Sendable {
    private var code: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?
    private let lock = NSLock()

    var isFinished: Bool { lock.withLock { code != nil } }

    func finish(_ value: Int32) {
        let waiter = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            code = value
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: value)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Int32? in
                if let code { return code }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Mutable run state shared between the output reader and the heartbeat.
final class SharedRunState: @unchecked Sendable {
    private var status: JobStatus
    private let lock = NSLock()
    var volumeLost = false

    init(status: JobStatus) {
        self.status = status
    }

    func update(_ body: (inout JobStatus) -> Void) {
        lock.withLock { body(&status) }
    }

    func snapshot() -> JobStatus {
        lock.withLock { status }
    }
}

final class TailCollector: @unchecked Sendable {
    private var data = Data()
    private let limit: Int
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// The running restic child, so a SIGTERM from launchd stops it cleanly.
public final class ActiveChild: @unchecked Sendable {
    public static let shared = ActiveChild()
    private var process: Process?
    private var onTerminate: (@Sendable () -> Void)?
    private let lock = NSLock()

    func set(_ process: Process?, onTerminate: (@Sendable () -> Void)?) {
        lock.withLock {
            self.process = process
            self.onTerminate = onTerminate
        }
    }

    /// Asks restic to stop (SIGINT lets it remove its lock), then waits briefly.
    public func interruptAndWait(seconds: TimeInterval = 20) {
        guard let process = lock.withLock({ self.process }), process.isRunning else { return }
        process.interrupt()
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning { process.terminate() }
        lock.withLock { onTerminate }?()
    }
}

/// Append-only companion log without source paths or secrets.
struct AgentLogger: Sendable {
    let paths: AgentPaths

    func log(_ message: String) {
        try? paths.prepare()
        let url = paths.logsDirectory.appendingPathComponent("agent.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Most recent startup or wake time, for catch-up decisions.
public enum SystemEvents {
    public static func lastStartupOrWake() -> Date? {
        [sysctlTime("kern.boottime"), sysctlTime("kern.waketime")].compactMap { $0 }.max()
    }

    private static func sysctlTime(_ name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }
}
#endif

import CryptoKit

func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
