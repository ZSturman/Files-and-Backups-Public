import Foundation

/// Fixed argv builders for every restic operation the companion performs.
/// Nothing is passed through a shell, and user-supplied IDs are validated.
public enum ResticCommand {
    public static func validateSnapshotID(_ id: String) throws -> String {
        let value = id.lowercased()
        guard (8...64).contains(value.count), value.allSatisfy({ $0.isHexDigit }) else {
            throw BackupError.invalidConfiguration("snapshot IDs are 8–64 hexadecimal characters")
        }
        return value
    }

    /// SSH keepalives for SFTP repositories: a dead path is detected and
    /// reported instead of hanging, and brief stalls are ridden out.
    public static func backendOptions(_ job: BackupJobConfiguration) -> [String] {
        guard case .sftpRepository = job.destination else { return [] }
        return ["-o", "sftp.args=-o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o BatchMode=yes"]
    }

    public static func backup(_ job: BackupJobConfiguration, host: String) -> [String] {
        var args = backendOptions(job) + ["backup", "--json", "--host", host]
        for tag in job.snapshotTags { args += ["--tag", tag] }
        for pattern in job.excludes { args += ["--exclude", pattern] }
        if job.excludeCaches { args.append("--exclude-caches") }
        for name in job.excludeIfPresent { args += ["--exclude-if-present", name] }
        args += ["--", job.sourcePath]
        return args
    }

    public static func snapshots(_ job: BackupJobConfiguration) -> [String] {
        ["snapshots", "--json", "--tag", "job-\(job.id)"]
    }

    public static func restore(snapshotID: String, target: String, include: String?) throws -> [String] {
        var args = ["restore", try validateSnapshotID(snapshotID), "--target", target]
        if let include { args += ["--include", include] }
        return args
    }

    /// Retention preview only: `--dry-run` never removes snapshots.
    public static func forgetPreview(_ job: BackupJobConfiguration, policy: RetentionPolicy) -> [String] {
        ["forget", "--dry-run", "--json", "--tag", "job-\(job.id)", "--group-by", "host,tags,paths"] + policy.arguments
    }

    public static let initialize = ["init"]
    public static let catConfig = ["cat", "config"]
}

/// Migration retention: 24 hourly / 14 daily / 8 weekly / 12 monthly.
public struct RetentionPolicy: Codable, Hashable, Sendable {
    public var hourly = 24
    public var daily = 14
    public var weekly = 8
    public var monthly = 12

    public init() {}

    public var arguments: [String] {
        ["--keep-hourly", "\(hourly)", "--keep-daily", "\(daily)", "--keep-weekly", "\(weekly)", "--keep-monthly", "\(monthly)"]
    }
}

public struct ResticSnapshot: Codable, Hashable, Sendable {
    public var id: String
    public var shortID: String?
    public var time: Date
    public var hostname: String
    public var paths: [String]
    public var tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id, time, hostname, paths, tags
        case shortID = "short_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shortID = try container.decodeIfPresent(String.self, forKey: .shortID)
        hostname = try container.decode(String.self, forKey: .hostname)
        paths = try container.decode([String].self, forKey: .paths)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        let raw = try container.decode(String.self, forKey: .time)
        guard let parsed = ResticOutput.parseDate(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .time, in: container, debugDescription: "unparseable time \(raw)")
        }
        time = parsed
    }
}

public enum ResticEvent: Equatable, Sendable {
    case status(JobProgress)
    case summary(snapshotID: String, filesNew: Int?, filesChanged: Int?, dataAdded: Int64?)
    case error(String)
}

public enum ResticOutput {
    /// Parses one `--json` line from `restic backup`.
    public static func parse(line: String) -> ResticEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["message_type"] as? String else { return nil }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        func int64(_ key: String) -> Int64? { (object[key] as? NSNumber)?.int64Value }
        switch type {
        case "status":
            return .status(JobProgress(
                filesDone: int("files_done"), totalFiles: int("total_files"),
                bytesDone: int64("bytes_done"), totalBytes: int64("total_bytes"),
                percentDone: (object["percent_done"] as? NSNumber)?.doubleValue
            ))
        case "summary":
            guard let id = object["snapshot_id"] as? String else { return nil }
            return .summary(snapshotID: id, filesNew: int("files_new"), filesChanged: int("files_changed"), dataAdded: int64("data_added"))
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "error"
            return .error(message)
        default:
            return nil
        }
    }

    /// Final totals from a `summary` line (present even for tiny backups
    /// that finish before any status line).
    public static func summaryTotals(line: String) -> JobProgress? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["message_type"] as? String == "summary" else { return nil }
        let files = (object["total_files_processed"] as? NSNumber)?.intValue
        let bytes = (object["total_bytes_processed"] as? NSNumber)?.int64Value
        return JobProgress(filesDone: files, totalFiles: files, bytesDone: bytes, totalBytes: bytes, percentDone: 1)
    }

    public static func parseSnapshots(_ data: Data) throws -> [ResticSnapshot] {
        try JSONDecoder().decode([ResticSnapshot].self, from: data)
    }

    /// restic prints RFC 3339 with nanoseconds, which ISO8601DateFormatter
    /// cannot parse directly; trim the fraction to milliseconds.
    static func parseDate(_ raw: String) -> Date? {
        var value = raw
        if let dot = value.firstIndex(of: "."),
           let zone = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = value[value.index(after: dot)..<zone].prefix(3)
            value = String(value[..<dot]) + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0) + String(value[zone...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Identity of the volume holding a path.
public struct VolumeIdentity: Equatable, Sendable {
    public var uuid: String
    public var mountPoint: String
    public var isRootVolume: Bool

    public static func of(path: String) throws -> VolumeIdentity {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .volumeIsRootFileSystemKey])
        guard let uuid = values.volumeUUIDString, let mount = values.volume else {
            throw BackupError.destinationUnavailable("the volume identity of the destination cannot be read")
        }
        return VolumeIdentity(uuid: uuid, mountPoint: mount.path, isRootVolume: values.volumeIsRootFileSystem ?? false)
    }

    /// Validates the repository path still lives on the configured volume.
    /// A missing disk leaves either no path or a path on another volume
    /// (e.g. an empty folder under /Volumes); both are refused.
    public static func require(path: String, uuid expected: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw BackupError.destinationUnavailable("the backup disk is not mounted")
        }
        let identity = try of(path: path)
        guard identity.uuid == expected else {
            throw BackupError.destinationUnavailable("a different volume is mounted at the backup location")
        }
    }
}
