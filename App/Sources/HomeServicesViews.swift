import FileCore
import QuickLook
import SwiftUI

/// Connects a Home Services provider for one screen's use.
@MainActor
func connectedHomeServices(_ model: AppModel, _ connection: ConnectionProfile) async throws -> HomeServicesProvider {
    guard let provider = try model.provider(for: connection) as? HomeServicesProvider else {
        throw FileCoreError.unsupported("this connection is not Home Services")
    }
    try await provider.connect()
    return provider
}

/// Managed Trash (Home Services): items are kept 7 days and can be restored.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: ConnectionProfile
    var onRestore: () -> Void = {}

    @State private var items: [TrashItem] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section { Text(message).font(.footnote) }
                }
                ForEach(items) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.originalPath.name)
                            Text(item.originalPath.parent.map { $0.isRoot ? "/" : $0.description } ?? "/")
                                .font(.caption).foregroundStyle(.secondary)
                            if let purge = item.purgeAfter {
                                Text("Removed permanently \(purge.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Restore") { Task { await restore(item) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("restore-\(item.originalPath.name)")
                    }
                }
            }
            .overlay {
                if loading { ProgressView() } else if items.isEmpty { ContentUnavailableView("Trash Is Empty", systemImage: "trash") }
            }
            .navigationTitle("Trash")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await connectedHomeServices(model, connection).trashItems()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restore(_ item: TrashItem) async {
        do {
            let restored = try await connectedHomeServices(model, connection).restoreFromTrash(item.id)
            message = restored == item.originalPath ? "Restored \(restored.name)." : "Restored as \(restored.description) (a newer item had the same name)."
            onRestore()
            await load()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Snapshot history from a Home Services server, grouped by source.
struct SnapshotListView: View {
    @Environment(AppModel.self) private var model
    let connection: ConnectionProfile
    @State private var snapshots: [BackupSnapshotSummary] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(Dictionary(grouping: snapshots, by: \.source).sorted { $0.key < $1.key }, id: \.key) { source, items in
                Section(source) {
                    ForEach(items.sorted { $0.time > $1.time }) { snapshot in
                        NavigationLink {
                            SnapshotBrowserView(connection: connection, snapshot: snapshot, path: snapshot.paths.first ?? "/")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
                                Text("\(snapshot.host) · \(String(snapshot.id.prefix(8)))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Snapshots")
        .task {
            defer { loading = false }
            do {
                snapshots = try await connectedHomeServices(model, connection).snapshots()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Browses a snapshot read-only. Files can be downloaded; any item can be
/// restored by the server into a fresh `Restores/<job>` folder, never over
/// existing files.
struct SnapshotBrowserView: View {
    @Environment(AppModel.self) private var model
    let connection: ConnectionProfile
    let snapshot: BackupSnapshotSummary
    let path: String

    @State private var entries: [SnapshotEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var previewURL: URL?
    @State private var restoring: SnapshotEntry?
    @State private var restoreStatus: RestoreJobStatus?
    @State private var busy = false

    var body: some View {
        List {
            if let restoreStatus {
                Section("Restore") {
                    if restoreStatus.isFinished {
                        if restoreStatus.state == "succeeded" {
                            Label("Restored \(restoreStatus.filesRestored.map { "\($0) file(s)" } ?? "") into \(restoreStatus.destination ?? "Restores")", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Restore \(restoreStatus.state): \(restoreStatus.error ?? "")", systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                    } else {
                        HStack { ProgressView(); Text("Restoring (\(restoreStatus.state))…") }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(entries) { entry in
                Group {
                    if entry.isDirectory {
                        NavigationLink {
                            SnapshotBrowserView(connection: connection, snapshot: snapshot, path: entry.path)
                        } label: { row(entry) }
                    } else {
                        Button { Task { await download(entry) } } label: { row(entry) }.buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    if !entry.isDirectory { Button("Download", systemImage: "arrow.down.circle") { Task { await download(entry) } } }
                    Button("Restore to Files › Restores", systemImage: "clock.arrow.circlepath") { restoring = entry }
                }
                .swipeActions { Button("Restore") { restoring = entry }.tint(.blue) }
            }
        }
        .overlay {
            if loading { ProgressView() } else if entries.isEmpty && error == nil { ContentUnavailableView("Empty Folder", systemImage: "folder") }
            if busy { ProgressView().controlSize(.large) }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Restore Folder") { restoring = SnapshotEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: true) }
                    .disabled(restoreStatus.map { !$0.isFinished } ?? false)
            }
        }
        .confirmationDialog("Restore “\(restoring?.name ?? "")”?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible, presenting: restoring) { entry in
            Button("Restore to a New Folder") { Task { await restore(entry) } }
        } message: { _ in
            Text("The server restores a copy into a new Restores folder on the destination. Nothing existing is overwritten.")
        }
        .filePreview($previewURL)
        .task { await load() }
    }

    private func row(_ entry: SnapshotEntry) -> some View {
        HStack {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(entry.name)
                if let size = entry.size { Text(Format.bytes(size)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func report(_ error: any Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func load() async {
        defer { loading = false }
        do {
            entries = try await connectedHomeServices(model, connection).snapshotEntries(snapshot.id, path: path)
        } catch {
            report(error)
        }
    }

    private func download(_ entry: SnapshotEntry) async {
        busy = true
        defer { busy = false }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotFiles/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(entry.name)
            try await connectedHomeServices(model, connection).downloadSnapshotFile(snapshot.id, path: entry.path, to: target)
            previewURL = target
        } catch {
            report(error)
        }
    }

    private func restore(_ entry: SnapshotEntry) async {
        do {
            let provider = try await connectedHomeServices(model, connection)
            let jobID = try await provider.startRestore(snapshotID: snapshot.id, include: [entry.path], idempotencyKey: "app-restore-\(UUID().uuidString.lowercased())")
            restoreStatus = RestoreJobStatus(id: jobID, state: "waiting")
            while let status = restoreStatus, !status.isFinished {
                try await Task.sleep(for: .seconds(2))
                restoreStatus = try await provider.restoreJob(jobID)
            }
        } catch is CancellationError {
        } catch {
            report(error)
        }
        restoring = nil
    }
}

/// Picks a destination folder within one connection for Move.
struct FolderPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: ConnectionProfile
    let moving: RemoteItem
    let onPick: (RemotePath) -> Void

    var body: some View {
        NavigationStack {
            FolderPickerLevel(connection: connection, path: .root, moving: moving) { destination in
                onPick(destination)
                dismiss()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct FolderPickerLevel: View {
    @Environment(AppModel.self) private var model
    let connection: ConnectionProfile
    let path: RemotePath
    let moving: RemoteItem
    let onPick: (RemotePath) -> Void
    @State private var folders: [RemoteItem] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(folders) { folder in
                NavigationLink {
                    FolderPickerLevel(connection: connection, path: folder.path, moving: moving, onPick: onPick)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
                .accessibilityIdentifier("pick-\(folder.name)")
            }
        }
        .navigationTitle(path.isRoot ? connection.name : path.name)
        .safeAreaInset(edge: .bottom) {
            Button("Move “\(moving.name)” Here") { onPick(path) }
                .buttonStyle(.borderedProminent)
                .disabled(moving.path.parent == path)
                .padding()
                .accessibilityIdentifier("moveHere")
        }
        .task {
            do {
                let provider = try model.provider(for: connection)
                try await provider.connect()
                defer { Task { await provider.disconnect() } }
                // A folder cannot be moved into itself.
                folders = try await provider.list(path).filter { $0.isDirectory && !$0.path.isWithin(moving.path) }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
