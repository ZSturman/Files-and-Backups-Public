import Foundation

/// Where restic gets the repository password. Nothing here is the password.
public enum PasswordSource: Codable, Hashable, Sendable {
    /// Owner-only file inside the companion's private `secrets/` directory.
    case privateFile(String)
    /// An existing command that prints the password (e.g. `security
    /// find-generic-password -w ...`), run without a shell.
    case command([String])
}

public enum BackupDestination: Codable, Hashable, Sendable {
    /// Human-readable, non-secret description.
    public var summary: String {
        switch self {
        case .localRepository(let path, _): return path
        case .sftpRepository(let user, let host, let path, _, _): return "sftp:\(user)@\(host):\(path)"
        case .homeServices(let url): return url
        }
    }

    /// A restic repository on a local or external disk, guarded by the
    /// volume UUID recorded when the job was configured.
    case localRepository(path: String, volumeUUID: String)
    /// A restic repository on another machine over SFTP (SSH keys, strict
    /// host keys). Before and during each run the companion confirms over SSH
    /// that `mountPoint` is mounted from the filesystem with `volumeUUID` and
    /// that `path` is inside it, so an unmounted disk is never written.
    case sftpRepository(user: String, host: String, path: String, mountPoint: String, volumeUUID: String)
    /// The Home Services backup contract (not yet published).
    case homeServices(baseURL: String)
}

public struct BackupJobConfiguration: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sourcePath: String
    public var destination: BackupDestination
    public var password: PasswordSource
    public var schedule: DailySchedule
    public var excludes: [String]
    public var tags: [String]
    public var enabled: Bool
    /// Allow unattended runs over expensive/constrained networks (hotspot,
    /// Low Data Mode). Off by default; manual runs are never restricted.
    public var allowMeteredNetworks: Bool = false
    /// Skip folders holding a valid CACHEDIR.TAG (restic `--exclude-caches`).
    public var excludeCaches: Bool = false
    /// Skip folders containing a file with one of these names (restic
    /// `--exclude-if-present`), e.g. a `.nobackup` marker.
    public var excludeIfPresent: [String] = []

    public init(
        id: String, name: String, sourcePath: String, destination: BackupDestination, password: PasswordSource,
        schedule: DailySchedule = .default, excludes: [String] = [], tags: [String] = [], enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.destination = destination
        self.password = password
        self.schedule = schedule
        self.excludes = excludes
        self.tags = tags
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sourcePath, destination, password, schedule, excludes, tags, enabled, allowMeteredNetworks
        case excludeCaches, excludeIfPresent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        destination = try c.decode(BackupDestination.self, forKey: .destination)
        password = try c.decode(PasswordSource.self, forKey: .password)
        schedule = try c.decodeIfPresent(DailySchedule.self, forKey: .schedule) ?? .default
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowMeteredNetworks = try c.decodeIfPresent(Bool.self, forKey: .allowMeteredNetworks) ?? false
        excludeCaches = try c.decodeIfPresent(Bool.self, forKey: .excludeCaches) ?? false
        excludeIfPresent = try c.decodeIfPresent([String].self, forKey: .excludeIfPresent) ?? []
    }

    /// IDs become file names and restic tags, so they are deliberately narrow.
    public static func validate(id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !id.isEmpty, id.count <= 48, id.unicodeScalars.allSatisfy(allowed.contains), !id.hasPrefix("-") else {
            throw BackupError.invalidConfiguration("job IDs use lowercase letters, digits, and hyphens")
        }
    }

    /// Tags written on every snapshot: identify the companion and the job so
    /// history is grouped by actual source.
    public var snapshotTags: [String] {
        ["files-backups", "job-\(id)"] + tags
    }
}

public struct AgentConfiguration: Codable, Hashable, Sendable {
    public var jobs: [BackupJobConfiguration]
    public var resticPath: String?
    /// Opt-in status reporting to Home Services (nil = off).
    public var reporting: ReportingConfiguration?

    public init(jobs: [BackupJobConfiguration] = [], resticPath: String? = nil, reporting: ReportingConfiguration? = nil) {
        self.jobs = jobs
        self.resticPath = resticPath
        self.reporting = reporting
    }
}

public enum BackupError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case destinationUnavailable(String)
    case sourceUnavailable(String)
    case alreadyRunning
    case resticMissing
    case resticFailed(code: Int32, message: String)
    case unsupported(String)
    case unsafeRestoreTarget(String)
    case passwordUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "Invalid backup configuration: \(detail)."
        case .destinationUnavailable(let detail): return "Backup destination unavailable: \(detail)."
        case .sourceUnavailable(let detail): return "Backup source unavailable: \(detail)."
        case .alreadyRunning: return "Another run of this backup job is already in progress."
        case .resticMissing: return "restic was not found. Install it (for example `brew install restic`) or set resticPath."
        case .resticFailed(let code, let message): return "restic exited with status \(code): \(message)"
        case .unsupported(let detail): return "Not supported: \(detail)."
        case .unsafeRestoreTarget(let detail): return "Refusing to restore: \(detail)."
        case .passwordUnavailable(let detail): return "Repository password unavailable: \(detail)."
        }
    }
}

/// The companion's private directory layout. Defaults to
/// `~/Library/Application Support/FilesBackups`; `FILES_BACKUPS_HOME`
/// overrides it for isolated fixtures.
public struct AgentPaths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentPaths {
        if let override = environment["FILES_BACKUPS_HOME"], !override.isEmpty {
            return AgentPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AgentPaths(home: support.appendingPathComponent("FilesBackups", isDirectory: true))
    }

    public var configFile: URL { home.appendingPathComponent("config.json") }
    public var statusDirectory: URL { home.appendingPathComponent("status", isDirectory: true) }
    public var locksDirectory: URL { home.appendingPathComponent("locks", isDirectory: true) }
    public var secretsDirectory: URL { home.appendingPathComponent("secrets", isDirectory: true) }
    public var logsDirectory: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var binDirectory: URL { home.appendingPathComponent("bin", isDirectory: true) }

    public func statusFile(for jobID: String) -> URL { statusDirectory.appendingPathComponent("\(jobID).json") }
    public func lockFile(for jobID: String) -> URL { locksDirectory.appendingPathComponent("\(jobID).lock") }

    /// Creates the private directories with owner-only permissions.
    public func prepare() throws {
        let manager = FileManager.default
        for directory in [home, statusDirectory, locksDirectory, secretsDirectory, logsDirectory, binDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    public func loadConfiguration() throws -> AgentConfiguration {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return AgentConfiguration() }
        return try JSONDecoder.backup.decode(AgentConfiguration.self, from: Data(contentsOf: configFile))
    }

    public func saveConfiguration(_ configuration: AgentConfiguration) throws {
        try prepare()
        try writePrivate(try JSONEncoder.backup.encode(configuration), to: configFile)
    }
}

/// Atomic write readable only by the owner.
func writePrivate(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw BackupError.invalidConfiguration("cannot write \(url.lastPathComponent)")
    }
    if rename(temp.path, url.path) != 0 {
        try? FileManager.default.removeItem(at: temp)
        throw BackupError.invalidConfiguration("cannot replace \(url.lastPathComponent)")
    }
}

extension JSONEncoder {
    static var backup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var backup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
