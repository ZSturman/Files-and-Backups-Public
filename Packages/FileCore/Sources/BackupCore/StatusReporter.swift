import Foundation

/// Opt-in, status-only reporting of companion runs to Home Services
/// (contract 1.2 "external" sources). Home Services never sees the repository
/// password; it records what the companion reports (`verified: false`) and
/// raises overdue / did-not-finish alerts.
///
/// Reporting is best effort: every failure is logged and swallowed so it can
/// never fail, delay, or block a backup.
public struct ReportingConfiguration: Codable, Hashable, Sendable {
    public var baseURL: String
    /// Owner-only file in the companion's secrets directory holding a token
    /// with the `files-backups-companion` scope.
    public var tokenFile: String
    /// Home Services source ID per job, filled in on first registration.
    public var sourceIDs: [String: String]
    public var jobs: [String]

    public init(baseURL: String, tokenFile: String, sourceIDs: [String: String] = [:], jobs: [String] = []) {
        self.baseURL = baseURL
        self.tokenFile = tokenFile
        self.sourceIDs = sourceIDs
        self.jobs = jobs
    }
}

public final class StatusReporter: @unchecked Sendable {
    let configuration: ReportingConfiguration
    let token: String
    let session: URLSession
    let log: (String) -> Void

    public init(configuration: ReportingConfiguration, token: String, session: URLSession = .shared, log: @escaping (String) -> Void) {
        self.configuration = configuration
        self.token = token
        self.session = session
        self.log = log
    }

    public static func repositoryLabel(for job: BackupJobConfiguration) -> String {
        switch job.destination {
        case .sftpRepository(_, _, let path, _, _):
            let trimmed = path.replacingOccurrences(of: "/mnt/workspace-backup/", with: "")
            return "external:" + String(trimmed.filter { $0.isLetter || $0.isNumber || "._/-".contains($0) }.prefix(90))
        case .localRepository(let path, _):
            return "external:local/" + String(URL(fileURLWithPath: path).lastPathComponent.filter { $0.isLetter || $0.isNumber || "._-".contains($0) }.prefix(80))
        case .homeServices:
            return "external:home-services"
        }
    }

    private func call(_ method: String, _ path: String, json: [String: Any], idempotencyKey: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: configuration.baseURL)?.appendingPathComponent("api/v1/" + path), url.scheme == "https" else {
            throw BackupError.invalidConfiguration("Home Services reporting requires an https URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Home-Services-Contract")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? "http_\(status)"
            throw BackupError.unsupported("Home Services reporting: \(code)")
        }
        return object
    }

    /// Registers the job's source if needed; returns the source ID.
    public func register(_ job: BackupJobConfiguration, host: String) async -> String? {
        if let existing = configuration.sourceIDs[job.id] { return existing }
        do {
            let object = try await call("POST", "backups/sources", json: [
                "host": host, "path": job.sourcePath, "tag": "job-\(job.id)",
                "scheduler": "files-backups-companion", "repository": Self.repositoryLabel(for: job),
            ])
            return object["id"] as? String
        } catch {
            log("reporting: register \(job.id) failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func start(sourceID: String, runKey: String) async -> String? {
        do {
            return try await call("POST", "backups/sources/\(sourceID)/runs", json: ["scheduler": "files-backups-companion"], idempotencyKey: runKey)["id"] as? String
        } catch {
            log("reporting: start failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func heartbeat(runID: String, progress: JobProgress?) async {
        var data: [String: Any] = [:]
        if let p = progress {
            if let v = p.filesDone { data["files_done"] = v }
            if let v = p.totalFiles { data["total_files"] = v }
            if let v = p.bytesDone { data["bytes_done"] = v }
            if let v = p.totalBytes { data["total_bytes"] = v }
            if let v = p.percentDone { data["percent_done"] = v }
        }
        do { _ = try await call("POST", "backups/runs/\(runID)/heartbeat", json: ["progress": data]) } catch {
            log("reporting: heartbeat failed: \(error.localizedDescription)")
        }
    }

    public func finish(runID: String, succeeded: Bool, snapshotID: String?, totals: JobProgress?, message: String?) async {
        var body: [String: Any] = ["state": succeeded ? "succeeded" : "failed"]
        if let snapshotID { body["snapshot_id"] = snapshotID }
        var summary: [String: Any] = [:]
        if let files = totals?.totalFiles ?? totals?.filesDone { summary["total_files"] = files }
        if let bytes = totals?.totalBytes ?? totals?.bytesDone { summary["total_bytes"] = bytes }
        if !summary.isEmpty { body["summary"] = summary }
        if !succeeded, let message { body["error"] = ["message": String(message.prefix(500))] }
        do { _ = try await call("POST", "backups/runs/\(runID)/finish", json: body) } catch {
            log("reporting: finish failed: \(error.localizedDescription)")
        }
    }
}
