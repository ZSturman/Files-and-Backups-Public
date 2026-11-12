import Foundation

public enum JobRunState: String, Codable, Sendable {
    case idle
    case running
    case succeeded
    case failed
    /// Prerequisite missing (destination disk absent, source unreadable).
    case blocked
    /// A run stopped without reporting a result (crash, sleep, kill).
    case interrupted
}

public struct JobProgress: Codable, Hashable, Sendable {
    public var filesDone: Int?
    public var totalFiles: Int?
    public var bytesDone: Int64?
    public var totalBytes: Int64?
    public var percentDone: Double?

    public init(filesDone: Int? = nil, totalFiles: Int? = nil, bytesDone: Int64? = nil, totalBytes: Int64? = nil, percentDone: Double? = nil) {
        self.filesDone = filesDone
        self.totalFiles = totalFiles
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.percentDone = percentDone
    }
}

/// The one status record per job that the app and CLI read. Written
/// atomically by the companion; heartbeat and progress are separate so a
/// stalled restic is distinguishable from a slow one.
public struct JobStatus: Codable, Hashable, Sendable {
    public var jobID: String
    public var jobName: String
    public var state: JobRunState
    public var reason: RunReason?
    public var runID: String?
    public var pid: Int32?
    public var startedAt: Date?
    public var heartbeatAt: Date?
    public var lastProgressAt: Date?
    public var progress: JobProgress?
    public var finishedAt: Date?
    public var snapshotID: String?
    public var message: String?
    public var scheduler: SchedulerState
    public var nextScheduledAt: Date?
    /// Last read-only integrity check (`restic check --read-data-subset`).
    public var lastCheckAt: Date?
    public var lastCheckPassed: Bool?
    public var lastCheckMessage: String?

    public static let heartbeatDeadline: TimeInterval = 300

    public init(jobID: String, jobName: String) {
        self.jobID = jobID
        self.jobName = jobName
        self.state = .idle
        self.scheduler = SchedulerState()
    }

    /// Reads status, treating a running record with an old heartbeat as
    /// interrupted rather than still protecting anything.
    public func normalized(now: Date) -> JobStatus {
        guard state == .running else { return self }
        guard let heartbeatAt, now.timeIntervalSince(heartbeatAt) <= Self.heartbeatDeadline else {
            var copy = self
            copy.state = .interrupted
            copy.message = "No heartbeat from the backup process since \(heartbeatAt.map { ISO8601DateFormatter().string(from: $0) } ?? "it started"); it likely stopped unexpectedly."
            return copy
        }
        return self
    }

    public var protection: ProtectionStatus {
        ProtectionStatus.evaluate(lastSuccess: scheduler.lastSuccessAt, now: Date())
    }
}

public struct StatusStore: Sendable {
    public let paths: AgentPaths

    public init(paths: AgentPaths) {
        self.paths = paths
    }

    public func load(_ job: BackupJobConfiguration) -> JobStatus {
        guard let data = try? Data(contentsOf: paths.statusFile(for: job.id)),
              var status = try? JSONDecoder.backup.decode(JobStatus.self, from: data) else {
            return JobStatus(jobID: job.id, jobName: job.name)
        }
        status.jobName = job.name
        return status
    }

    public func loadAll() -> [JobStatus] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: paths.statusDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder.backup.decode(JobStatus.self, from: data)
        }
        .sorted { $0.jobName < $1.jobName }
    }

    public func save(_ status: JobStatus) {
        // Status telemetry must never fail a backup.
        try? paths.prepare()
        if let data = try? JSONEncoder.backup.encode(status) {
            try? writePrivate(data, to: paths.statusFile(for: status.jobID))
        }
    }
}

/// Removes the configured source path and home directory from text that
/// may be logged or shown, so logs never reveal workspace locations.
public func redact(_ text: String, sourcePath: String?) -> String {
    var output = text
    if let sourcePath, !sourcePath.isEmpty {
        output = output.replacingOccurrences(of: sourcePath, with: "<source>")
    }
    output = output.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    return output
}
