import FileCore
import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("SMB transfers run while the app is open. If iOS suspends or closes the app, uploads pause and continue from a verified point when you reopen it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.jobs.isEmpty {
                    ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down", description: Text("Upload files or folders from a destination in Files."))
                }
                ForEach(model.jobs) { job in
                    NavigationLink(value: job.id) { JobRow(job: job) }
                        .swipeActions { actions(job) }
                        .contextMenu { actions(job) }
                }
            }
            .navigationTitle("Transfers")
            .navigationDestination(for: UUID.self) { id in
                if let job = model.jobs.first(where: { $0.id == id }) { JobDetailView(job: job) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Finished") { model.clearFinished() }
                        .disabled(!model.jobs.contains { $0.state == .complete || $0.state == .cancelled })
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ job: TransferJob) -> some View {
        switch job.state {
        case .queued, .transferring, .verifying:
            Button("Pause") { model.pause(job) }
            Button("Cancel", role: .destructive) { model.cancel(job) }
        case .paused:
            Button("Resume") { model.resume(job) }
            Button("Cancel", role: .destructive) { model.cancel(job) }
        case .failed:
            Button("Retry") { model.retry(job) }
            Button("Cancel", role: .destructive) { model.cancel(job) }
        case .complete, .cancelled:
            EmptyView()
        }
    }
}

struct JobRow: View {
    let job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.displayName).lineLimit(1)
                Spacer()
                Text(stateText).font(.caption).foregroundStyle(stateColor)
                    .accessibilityIdentifier("jobState")
            }
            ProgressView(value: Double(job.committedBytes), total: Double(max(job.totalBytes, 1)))
            HStack {
                Text("\(job.connectionName) · \(job.destination.description)")
                Spacer()
                Text("\(Format.bytes(job.committedBytes)) of \(Format.bytes(job.totalBytes))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let reason = job.failureReason {
                Text(reason).font(.caption).foregroundStyle(.red)
            } else if job.state == .complete, let level = job.verificationSummary {
                Text(level.displayName).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stateText: String {
        switch job.state {
        case .paused:
            switch job.pauseReason {
            case .system: return "Paused (app closed)"
            case .connectionLost: return "Paused (connection lost)"
            default: return "Paused"
            }
        default: return job.state.rawValue.capitalized
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .complete: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .secondary
        }
    }
}

struct JobDetailView: View {
    let job: TransferJob

    var body: some View {
        List {
            Section {
                JobRow(job: job)
                if let root = job.resolvedRootName, root != job.rootFolderName {
                    Text("A folder named “\(job.rootFolderName ?? "")” already existed, so this upload was saved as “\(root)”.")
                        .font(.footnote)
                }
            }
            Section("Files") {
                ForEach(job.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.relativePath).lineLimit(2)
                            Spacer()
                            Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        if let final = item.finalPath, final.name != item.manifestComponents.last {
                            Text("Saved as \(final.name)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let offset = item.resumedFromOffset {
                            Text("Resumed at \(Format.bytes(offset))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = item.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle(job.displayName)
    }
}
