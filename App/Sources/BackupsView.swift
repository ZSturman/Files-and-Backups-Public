import BackupCore
import FileCore
import SwiftUI

/// Backup protection is shown by source. File uploads are not listed here:
/// a copy on one disk is storage, not a versioned backup.
struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var statuses: [JobStatus] = []
    @State private var configuredJobs: [BackupJobConfiguration] = []
    @State private var companionReadable = false
    @State private var protection: [UUID: Result<[BackupProtectionGroup], String>] = [:]

    var body: some View {
        NavigationStack {
            List {
                #if os(macOS)
                macCompanionSection
                #endif
                homeServicesSection
                Section("What counts as protection") {
                    Text("Only a successful snapshot from a versioned backup (the Mac companion or a Home Services backup API) protects a source. Uploading files to a share is storage. Pi test snapshots do not establish Mac protection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Backups")
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    #if os(macOS)
    private var macCompanionSection: some View {
        Section {
            if !companionReadable || configuredJobs.isEmpty {
                Label("This Mac is unprotected by Files & Backups", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text("Install the standalone companion and add a job; see README “Mac backup companion”. It runs on its own schedule (daily 02:00 plus catch-up) without this app or Home Services.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(configuredJobs) { job in
                let status = statuses.first { $0.jobID == job.id }?.normalized(now: Date()) ?? JobStatus(jobID: job.id, jobName: job.name)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(job.name).font(.headline)
                        Spacer()
                        Text(status.state.rawValue.capitalized).font(.caption)
                    }
                    Text(job.destination.summary).font(.caption).foregroundStyle(.secondary)
                    protectionLabel(status.protection)
                    if status.state == .running, let percent = status.progress?.percentDone {
                        ProgressView(value: percent) { Text("Backing up…").font(.caption) }
                    }
                    if let checked = status.lastCheckAt {
                        Label("Integrity check \(status.lastCheckPassed == true ? "passed" : "FAILED") \(checked.formatted(date: .abbreviated, time: .shortened))",
                              systemImage: status.lastCheckPassed == true ? "checkmark.seal" : "exclamationmark.octagon")
                            .font(.caption)
                            .foregroundStyle(status.lastCheckPassed == true ? Color.secondary : Color.red)
                    }
                    if let next = status.nextScheduledAt {
                        Text("Next scheduled: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = status.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("This Mac")
        }
    }
    #endif

    private var homeServicesSection: some View {
        let servers = model.connections.filter { $0.kind == .homeServices }
        return Section("Home Services backups") {
            if servers.isEmpty {
                Text("Backup history and restore on this device need a provider with backup APIs, such as Home Services. SMB, SFTP, and WebDAV shares do not provide snapshot history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                switch protection[server.id] {
                case .none:
                    HStack { Text(server.name); Spacer(); ProgressView() }
                case .failure(let message):
                    Label("\(server.name): \(message)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                case .success(let groups):
                    ForEach(groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.tags.isEmpty ? group.paths.joined(separator: ", ") : group.tags.joined(separator: ", "))
                                .font(.headline)
                            Text("\(group.host) · \(group.paths.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            serverProtectionLabel(group)
                        }
                    }
                    NavigationLink("Browse snapshots on \(server.name)") { SnapshotListView(connection: server) }
                }
            }
        }
    }

    @ViewBuilder
    private func serverProtectionLabel(_ group: BackupProtectionGroup) -> some View {
        let when = group.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
        switch group.state {
        case "current":
            Label("Protected — last snapshot \(when)", systemImage: "checkmark.shield").foregroundStyle(.green)
        case "overdue":
            Label("Overdue — last snapshot \(when)", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
        default:
            Label("Unknown — \(group.snapshotCount) snapshot(s)", systemImage: "questionmark.diamond").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func protectionLabel(_ protection: ProtectionStatus) -> some View {
        switch protection {
        case .unprotected:
            Label("Unprotected — no successful snapshot yet", systemImage: "xmark.shield").foregroundStyle(.red)
        case .current(let date):
            Label("Protected — last snapshot \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.shield").foregroundStyle(.green)
        case .overdue(let date, let hours):
            Label("Overdue — last snapshot \(date.formatted(date: .abbreviated, time: .shortened)) (\(hours) h ago)", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
        }
    }

    private func refresh() async {
        #if os(macOS)
        // The sandboxed app reads the companion's status read-only from the
        // user's real home (granted by a temporary-exception entitlement).
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            let paths = AgentPaths(home: URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/FilesBackups"))
            let configuration = try? paths.loadConfiguration()
            companionReadable = configuration != nil
            configuredJobs = configuration?.jobs ?? []
            statuses = StatusStore(paths: paths).loadAll()
        }
        #endif
        for server in model.connections where server.kind == .homeServices {
            do {
                protection[server.id] = .success(try await connectedHomeServices(model, server).protection())
            } catch {
                protection[server.id] = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

extension String: @retroactive Error {}
