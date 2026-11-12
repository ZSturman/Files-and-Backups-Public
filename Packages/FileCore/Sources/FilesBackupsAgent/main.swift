import BackupCore
import Darwin
import Foundation
import Security

// fbbackup-agent: the standalone Files & Backups Mac backup companion.
// Runs from ~/Library/Application Support/FilesBackups/bin under launchd;
// it needs neither the app, this checkout, nor Home Services.

let usage = """
usage: fbbackup-agent <command> [options]

  add-local-job --id ID --name NAME --source DIR --repository DIR
                (--password-stdin | --password-from-job ID | --password-command /abs/cmd [args...])
                [--create-repository] [--hour 2] [--minute 0] [EXCLUSIONS]
      Configure a job backing up DIR into a restic repository on a local or
      external disk. Records the disk's volume UUID. --create-repository
      initializes a new repository in an empty folder; otherwise the folder
      must already be a restic repository.
  add-sftp-job --id ID --name NAME --source DIR --sftp USER@HOST:/abs/repo --mount /abs/mountpoint
                (--generate-password | --password-stdin | --password-from-job ID | --password-command /abs/cmd [args...])
                [--create-repository] [--hour 2] [--minute 0] [EXCLUSIONS]
      Configure a job backing up into a restic repository over SFTP (SSH key
      auth, known host key). Records the UUID of the disk mounted at --mount
      on the remote host and refuses to run when it is missing or different.
      --generate-password creates a random password, stores it in the private
      secrets file and in the login Keychain ("Files & Backups restic ID").
      --password-from-job reuses another job's password source, so a second
      job can write the same repository (deduplicated with the first).
  EXCLUSIONS: --exclude PATTERN ... | --exclude-file FILE ... (patterns are
      copied into the job) | --exclude-caches (CACHEDIR.TAG) |
      --exclude-if-present NAME ...   (restic semantics)
  run --job ID              Back up now (manual run).
  tick                      Run due scheduled/catch-up jobs (used by launchd).
  status [--json]           Show job status and protection.
  snapshots --job ID        List this job's snapshots.
  restore --job ID --snapshot ID --target NEW_DIR [--include PATH] [--verify SUBPATH|.]
      Restore into a new/empty folder (never the live source); --verify
      compares SHA-256 of restored files with the live source.
  retention-preview --job ID  Dry-run 24h/14d/8w/12m retention. Never prunes.
  check --job ID [--read-data-subset 5%]   Read-only repository integrity check.
  set-schedule --job ID --hour H --minute M  Change a job's daily time.
  unlock-stale --job ID     Remove only stale restic locks (never data).
  enable-reporting --job ID --url https://host:8443   (token on stdin)
      Report this job's runs (status only, no password) to Home Services so it
      can alert when the backup is overdue or fails. Best effort.
  disable-reporting --job ID
  disable-job --id ID       Stop scheduling a job (manual runs still work).
                            Its repository and snapshots are untouched.
  enable-job --id ID        Schedule a disabled job again.
  remove-job --id ID        Remove a job from the companion. The repository and
                            its snapshots are left untouched.
  install-launchagent [--print]   Install the daily 02:00 + catch-up LaunchAgent.
  uninstall-launchagent

Environment: FILES_BACKUPS_HOME overrides the private state directory.
"""

struct Arguments {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var trailing: [String] = []

    init(_ raw: [String], valueOptions: Set<String>, multiOptions: Set<String> = [], trailingOption: String? = nil) throws {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item == trailingOption {
                trailing = Array(raw[(index + 1)...])
                break
            }
            guard item.hasPrefix("--") else { throw BackupError.invalidConfiguration("unexpected argument \(item)") }
            if valueOptions.contains(item) || multiOptions.contains(item) {
                guard index + 1 < raw.count else { throw BackupError.invalidConfiguration("\(item) needs a value") }
                values[item, default: []].append(raw[index + 1])
                index += 2
            } else {
                flags.insert(item)
                index += 1
            }
        }
    }

    func value(_ key: String) -> String? { values[key]?.last }

    func require(_ key: String) throws -> String {
        guard let value = value(key), !value.isEmpty else { throw BackupError.invalidConfiguration("\(key) is required") }
        return value
    }
}

let launchAgentLabel = "com.zacharysturman.filesbackups.agent"

func launchAgentPlist(paths: AgentPaths, executable: String, schedules: [DailySchedule]) -> String {
    let unique = Array(Set(schedules.isEmpty ? [.default] : schedules)).sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    let calendar = unique.map {
        "    <dict><key>Hour</key><integer>\($0.hour)</integer><key>Minute</key><integer>\($0.minute)</integer></dict>"
    }.joined(separator: "\n")
    var environment = ""
    if let home = ProcessInfo.processInfo.environment["FILES_BACKUPS_HOME"] {
        environment = """
          <key>EnvironmentVariables</key><dict>
            <key>FILES_BACKUPS_HOME</key><string>\(xmlEscape(home))</string>
          </dict>

        """
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(launchAgentLabel)</string>
      <key>ProgramArguments</key><array>
        <string>\(xmlEscape(executable))</string>
        <string>tick</string>
      </array>
    \(environment)  <key>StartCalendarInterval</key><array>
    \(calendar)
      </array>
      <key>StartInterval</key><integer>900</integer>
      <key>RunAtLoad</key><true/>
      <key>ProcessType</key><string>Background</string>
      <key>LowPriorityIO</key><true/>
      <key>StandardOutPath</key><string>\(xmlEscape(paths.logsDirectory.appendingPathComponent("launchd.out.log").path))</string>
      <key>StandardErrorPath</key><string>\(xmlEscape(paths.logsDirectory.appendingPathComponent("launchd.err.log").path))</string>
    </dict></plist>

    """
}

func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func describe(_ status: JobStatus, job: BackupJobConfiguration) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    var lines = ["\(job.name) [\(job.id)]: \(status.state.rawValue)\(job.enabled ? "" : " (disabled: not scheduled)")"]
    switch status.protection {
    case .unprotected: lines.append("  protection: UNPROTECTED — no successful snapshot recorded by this companion")
    case .current(let date): lines.append("  protection: current — last snapshot \(formatter.string(from: date))")
    case .overdue(let date, let hours): lines.append("  protection: OVERDUE — last snapshot \(formatter.string(from: date)) (\(hours) h ago)")
    }
    if let id = status.scheduler.lastSuccessSnapshotID { lines.append("  last snapshot: \(id.prefix(8))") }
    if let progress = status.progress, status.state == .running, let percent = progress.percentDone {
        lines.append(String(format: "  progress: %.1f%%", percent * 100))
    }
    if job.enabled, let next = status.nextScheduledAt { lines.append("  next scheduled: \(formatter.string(from: next))") }
    if let checked = status.lastCheckAt {
        lines.append("  integrity check: \(status.lastCheckPassed == true ? "passed" : "FAILED") \(formatter.string(from: checked))")
    } else {
        lines.append("  integrity check: not yet run (weekly, after a scheduled backup)")
    }
    if let message = status.message { lines.append("  note: \(message)") }
    return lines.joined(separator: "\n")
}

func main() async -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        print(usage)
        return 2
    }
    let rest = Array(arguments.dropFirst())
    let paths = AgentPaths.fromEnvironment()

    // launchd sends SIGTERM on stop/logout: let restic release its lock.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termination.setEventHandler {
        ActiveChild.shared.interruptAndWait()
        exit(143)
    }
    termination.resume()

    do {
        var configuration = try paths.loadConfiguration()
        let runner = BackupRunner(paths: paths, configuration: configuration)

        switch command {
        case "add-local-job":
            let args = try Arguments(
                rest, valueOptions: ["--id", "--name", "--source", "--repository", "--hour", "--minute", "--password-from-job"],
                multiOptions: ["--exclude", "--exclude-file", "--exclude-if-present"], trailingOption: "--password-command"
            )
            let id = try args.require("--id")
            try BackupJobConfiguration.validate(id: id)
            guard !configuration.jobs.contains(where: { $0.id == id }) else {
                throw BackupError.invalidConfiguration("job \(id) already exists")
            }
            let source = URL(fileURLWithPath: try args.require("--source")).standardizedFileURL.path
            let repository = URL(fileURLWithPath: try args.require("--repository")).standardizedFileURL.path
            try paths.prepare()
            if args.flags.contains("--create-repository") {
                try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let volume = try VolumeIdentity.of(path: repository)
            let password = try passwordSource(args, id: id, paths: paths, configuration: configuration)
            let schedule = DailySchedule(hour: Int(args.value("--hour") ?? "2") ?? 2, minute: Int(args.value("--minute") ?? "0") ?? 0)
            var job = BackupJobConfiguration(
                id: id, name: args.value("--name") ?? id, sourcePath: source,
                destination: .localRepository(path: repository, volumeUUID: volume.uuid), password: password,
                schedule: schedule, excludes: try excludePatterns(args)
            )
            applyExclusionFlags(args, to: &job)
            runner.configuration.jobs.append(job)
            if args.flags.contains("--create-repository") {
                try await runner.initializeRepository(job)
            } else {
                _ = try await runner.snapshots(job) // proves the repository and password work
            }
            configuration.jobs.append(job)
            try paths.saveConfiguration(configuration)
            print("Configured \(job.name) [\(id)] on volume \(volume.uuid)\(volume.isRootVolume ? " (startup disk: not independent of this Mac)" : "").")
            return 0

        case "add-sftp-job":
            let args = try Arguments(
                rest, valueOptions: ["--id", "--name", "--source", "--sftp", "--mount", "--hour", "--minute", "--password-from-job"],
                multiOptions: ["--exclude", "--exclude-file", "--exclude-if-present"], trailingOption: "--password-command"
            )
            let id = try args.require("--id")
            try BackupJobConfiguration.validate(id: id)
            guard !configuration.jobs.contains(where: { $0.id == id }) else {
                throw BackupError.invalidConfiguration("job \(id) already exists")
            }
            let source = URL(fileURLWithPath: try args.require("--source")).standardizedFileURL.path
            let target = try args.require("--sftp")
            guard let at = target.firstIndex(of: "@"), let colon = target[at...].firstIndex(of: ":") else {
                throw BackupError.invalidConfiguration("--sftp must look like user@host:/absolute/path")
            }
            let user = String(target[..<at]), host = String(target[target.index(after: at)..<colon])
            let path = String(target[target.index(after: colon)...])
            let mount = try args.require("--mount")
            guard let uuid = try RemoteVolume.uuid(user: user, host: host, mountPoint: mount) else {
                throw BackupError.destinationUnavailable("nothing is mounted at \(mount) on \(host)")
            }
            try paths.prepare()
            let password = try passwordSource(args, id: id, paths: paths, configuration: configuration)
            let schedule = DailySchedule(hour: Int(args.value("--hour") ?? "2") ?? 2, minute: Int(args.value("--minute") ?? "0") ?? 0)
            var job = BackupJobConfiguration(
                id: id, name: args.value("--name") ?? id, sourcePath: source,
                destination: .sftpRepository(user: user, host: host, path: path, mountPoint: mount, volumeUUID: uuid),
                password: password, schedule: schedule, excludes: try excludePatterns(args)
            )
            applyExclusionFlags(args, to: &job)
            runner.configuration.jobs.append(job)
            if args.flags.contains("--create-repository") {
                try await runner.initializeRepository(job)
            } else {
                _ = try await runner.snapshots(job)
            }
            configuration.jobs.append(job)
            try paths.saveConfiguration(configuration)
            print("Configured \(job.name) [\(id)] → \(job.destination.summary) on remote disk \(uuid).")
            return 0

        case "run":
            let args = try Arguments(rest, valueOptions: ["--job"])
            let job = try runner.job(try args.require("--job"))
            let status = try await runner.run(job, reason: .manual)
            print(describe(status, job: job))
            return 0

        case "tick":
            await runner.tick(systemEvent: SystemEvents.lastStartupOrWake())
            return 0

        case "status":
            let args = try Arguments(rest, valueOptions: [])
            let statuses = configuration.jobs.map { runner.status($0) }
            if args.flags.contains("--json") {
                print(String(decoding: try JSONEncoder.pretty.encode(statuses), as: UTF8.self))
            } else if configuration.jobs.isEmpty {
                print("No backup jobs configured. Nothing is protected by this companion.")
            } else {
                for job in configuration.jobs { print(describe(runner.status(job), job: job)) }
            }
            return 0

        case "snapshots":
            let args = try Arguments(rest, valueOptions: ["--job"])
            let job = try runner.job(try args.require("--job"))
            for snapshot in try await runner.snapshots(job) {
                print("\(snapshot.shortID ?? String(snapshot.id.prefix(8)))  \(ISO8601DateFormatter().string(from: snapshot.time))  \(snapshot.hostname)")
            }
            return 0

        case "restore":
            let args = try Arguments(rest, valueOptions: ["--job", "--snapshot", "--target", "--include", "--verify"])
            let job = try runner.job(try args.require("--job"))
            let snapshotID = try ResticCommand.validateSnapshotID(try args.require("--snapshot"))
            let target = URL(fileURLWithPath: try args.require("--target")).standardizedFileURL.path
            var include = args.value("--include")
            let verifySubpath = args.value("--verify").flatMap { $0 == "." ? nil : $0 }
            if let verifySubpath, include == nil {
                include = URL(fileURLWithPath: job.sourcePath).appendingPathComponent(verifySubpath).path
            }
            try await runner.restore(job, snapshotID: snapshotID, target: target, include: include)
            print("Restored snapshot \(snapshotID.prefix(8)) into a new folder.")
            if args.values["--verify"] != nil {
                let snapshots = try await runner.snapshots(job)
                guard let snapshot = snapshots.first(where: { $0.id.hasPrefix(snapshotID) }) else {
                    throw BackupError.invalidConfiguration("snapshot not found for verification")
                }
                let report = try RestoreVerification.compare(source: job.sourcePath, restoreTarget: target, subpath: verifySubpath, snapshotTime: snapshot.time, rules: ExcludeRules(job: job))
                print("Verification: \(report.matched)/\(report.filesCompared) files match by SHA-256; \(report.mismatched.count) mismatched; \(report.missingFromRestore.count) missing; \(report.changedSinceSnapshot.count) changed since the snapshot.")
                for path in (report.mismatched + report.missingFromRestore).prefix(10) { print("  problem: \(path)") }
                return report.passed ? 0 : 1
            }
            return 0

        case "check":
            let args = try Arguments(rest, valueOptions: ["--job", "--read-data-subset"])
            let job = try runner.job(try args.require("--job"))
            print(String(decoding: try await runner.check(job, readDataSubset: args.value("--read-data-subset")), as: UTF8.self))
            return 0

        case "unlock-stale":
            let args = try Arguments(rest, valueOptions: ["--job"])
            let job = try runner.job(try args.require("--job"))
            print(String(decoding: try await runner.removeStaleLocks(job), as: UTF8.self))
            return 0

        case "set-schedule":
            let args = try Arguments(rest, valueOptions: ["--job", "--hour", "--minute"])
            let id = try args.require("--job")
            guard let index = configuration.jobs.firstIndex(where: { $0.id == id }),
                  let hour = Int(try args.require("--hour")), (0...23).contains(hour),
                  let minute = Int(try args.require("--minute")), (0...59).contains(minute) else {
                throw BackupError.invalidConfiguration("unknown job or invalid time")
            }
            configuration.jobs[index].schedule = DailySchedule(hour: hour, minute: minute)
            try paths.saveConfiguration(configuration)
            print("\(id) now runs daily at \(String(format: "%02d:%02d", hour, minute)) local time. Run install-launchagent to update launchd.")
            return 0

        case "enable-reporting":
            let args = try Arguments(rest, valueOptions: ["--job", "--url"])
            let id = try args.require("--job")
            _ = try runner.job(id)
            let url = try args.require("--url")
            guard URL(string: url)?.scheme == "https" else { throw BackupError.invalidConfiguration("--url must be https") }
            guard let token = readLine(strippingNewline: true), !token.isEmpty else {
                throw BackupError.passwordUnavailable("no token on standard input")
            }
            try paths.prepare()
            try writeSecret(token, to: paths.secretsDirectory.appendingPathComponent("home-services-companion.token"))
            var reporting = configuration.reporting ?? ReportingConfiguration(baseURL: url, tokenFile: "home-services-companion.token")
            reporting.baseURL = url
            if !reporting.jobs.contains(id) { reporting.jobs.append(id) }
            configuration.reporting = reporting
            try paths.saveConfiguration(configuration)
            print("Reporting enabled for \(id) → \(url). The next run registers the source and reports its result.")
            return 0

        case "disable-reporting":
            let args = try Arguments(rest, valueOptions: ["--job"])
            let id = try args.require("--job")
            configuration.reporting?.jobs.removeAll { $0 == id }
            try paths.saveConfiguration(configuration)
            print("Reporting disabled for \(id).")
            return 0

        case "disable-job", "enable-job":
            let args = try Arguments(rest, valueOptions: ["--id"])
            let id = try args.require("--id")
            guard let index = configuration.jobs.firstIndex(where: { $0.id == id }) else {
                throw BackupError.invalidConfiguration("no job named \(id)")
            }
            configuration.jobs[index].enabled = command == "enable-job"
            try paths.saveConfiguration(configuration)
            print(command == "enable-job"
                  ? "\(id) is scheduled again. Run install-launchagent to update launchd."
                  : "\(id) is no longer scheduled. Its repository and snapshots were not touched; `run --job \(id)` still works.")
            return 0

        case "remove-job":
            let args = try Arguments(rest, valueOptions: ["--id"])
            let id = try args.require("--id")
            guard configuration.jobs.contains(where: { $0.id == id }) else { throw BackupError.invalidConfiguration("no job named \(id)") }
            configuration.jobs.removeAll { $0.id == id }
            try paths.saveConfiguration(configuration)
            print("Removed job \(id). Its repository, snapshots, and password file were not deleted.")
            return 0

        case "retention-preview":
            let args = try Arguments(rest, valueOptions: ["--job"])
            let job = try runner.job(try args.require("--job"))
            print(String(decoding: try await runner.forgetPreview(job), as: UTF8.self))
            return 0

        case "install-launchagent":
            let args = try Arguments(rest, valueOptions: [])
            let executable = paths.binDirectory.appendingPathComponent("fbbackup-agent").path
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw BackupError.invalidConfiguration("install the companion binary first (scripts/install-mac-agent.sh)")
            }
            let plist = launchAgentPlist(paths: paths, executable: executable, schedules: configuration.jobs.filter(\.enabled).map(\.schedule))
            if args.flags.contains("--print") {
                print(plist)
                return 0
            }
            let agents = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let destination = agents.appendingPathComponent("\(launchAgentLabel).plist")
            try plist.write(to: destination, atomically: true, encoding: .utf8)
            let domain = "gui/\(getuid())"
            _ = shell(["/bin/launchctl", "bootout", "\(domain)/\(launchAgentLabel)"])
            let code = shell(["/bin/launchctl", "bootstrap", domain, destination.path])
            print(code == 0 ? "Installed \(launchAgentLabel)." : "Wrote \(destination.path) but launchctl bootstrap returned \(code).")
            return code

        case "uninstall-launchagent":
            let destination = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
            _ = shell(["/bin/launchctl", "bootout", "gui/\(getuid())/\(launchAgentLabel)"])
            try? FileManager.default.removeItem(at: destination)
            print("Removed \(launchAgentLabel).")
            return 0

        case "help", "--help", "-h":
            print(usage)
            return 0

        default:
            print(usage)
            return 2
        }
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        FileHandle.standardError.write(Data("fbbackup-agent: \(message)\n".utf8))
        return 1
    }
}

func passwordSource(_ args: Arguments, id: String, paths: AgentPaths, configuration: AgentConfiguration) throws -> PasswordSource {
    if let other = args.value("--password-from-job") {
        guard let job = configuration.jobs.first(where: { $0.id == other }) else {
            throw BackupError.invalidConfiguration("no job named \(other) to share a password with")
        }
        return job.password
    }
    let name = "\(id).password"
    if args.flags.contains("--generate-password") {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BackupError.passwordUnavailable("could not generate a password")
        }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        try writeSecret(secret, to: paths.secretsDirectory.appendingPathComponent(name))
        try storeRecoveryCopy(secret, id: id)
        print("Generated a repository password. Recovery copy: login Keychain item \"Files & Backups restic \(id)\". Without it the backup cannot be restored.")
        return .privateFile(name)
    }
    if args.flags.contains("--password-stdin") {
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw BackupError.passwordUnavailable("no password on standard input")
        }
        try writeSecret(line, to: paths.secretsDirectory.appendingPathComponent(name))
        return .privateFile(name)
    }
    if !args.trailing.isEmpty { return .command(args.trailing) }
    throw BackupError.invalidConfiguration("choose --generate-password, --password-stdin, --password-from-job, or --password-command")
}

func excludePatterns(_ args: Arguments) throws -> [String] {
    var patterns = args.values["--exclude"] ?? []
    for file in args.values["--exclude-file"] ?? [] { patterns += try ExcludeRules.patterns(fromFile: file) }
    return patterns
}

func applyExclusionFlags(_ args: Arguments, to job: inout BackupJobConfiguration) {
    job.excludeCaches = args.flags.contains("--exclude-caches")
    job.excludeIfPresent = args.values["--exclude-if-present"] ?? []
}

/// Keeps a recovery copy of a generated repository password in the login
/// Keychain so losing the companion's directory does not lose the backups.
func storeRecoveryCopy(_ secret: String, id: String) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Files & Backups restic \(id)",
        kSecAttrAccount as String: id,
        kSecAttrLabel as String: "Files & Backups restic \(id)",
        kSecValueData as String: Data(secret.utf8),
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw BackupError.passwordUnavailable("Keychain recovery copy failed (\(status))") }
}

func writeSecret(_ secret: String, to url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: Data((secret + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
        throw BackupError.passwordUnavailable("cannot write the private password file")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@discardableResult
func shell(_ argv: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

exit(await main())
