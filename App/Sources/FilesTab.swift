import FileCore
import SwiftUI

struct BrowseLocation: Hashable {
    var connection: ConnectionProfile
    var path: RemotePath
}

/// One sheet drives both add and edit; SwiftUI honors only one `.sheet`
/// modifier per view.
enum StorageSheet: Identifiable {
    case add
    case edit(ConnectionProfile)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let profile): return profile.id.uuidString
        }
    }
}

struct FilesTab: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: StorageSheet?
    @State private var removing: ConnectionProfile?

    var body: some View {
        NavigationStack {
            Group {
                if model.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No Storage Yet", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Add an SMB share on a Mac, PC, NAS, or Raspberry Pi, a Home Services server, or a folder on this Mac. Home Services is optional.")
                    } actions: {
                        Button("Add Storage") { sheet = .add }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("addStorageEmpty")
                    }
                } else {
                    List {
                        Section("Destinations") {
                            ForEach(model.connections) { connection in
                                NavigationLink(value: BrowseLocation(connection: connection, path: model.initialFolder(for: connection))) {
                                    ConnectionRow(connection: connection)
                                }
                                .contextMenu {
                                    Button("Edit", systemImage: "pencil") { sheet = .edit(connection) }
                                    Button("Remove", systemImage: "trash", role: .destructive) { removing = connection }
                                }
                                .swipeActions {
                                    Button("Remove", role: .destructive) { removing = connection }
                                    Button("Edit") { sheet = .edit(connection) }
                                }
                            }
                        }
                        Section {
                            Text("Uploading copies files to the destination. It is not a versioned backup; see Backups for protection status.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Files")
            .navigationDestination(for: BrowseLocation.self) { location in
                BrowserView(connection: location.connection, path: location.path)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .add } label: { Label("Add Storage", systemImage: "plus") }
                        .accessibilityIdentifier("addStorage")
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .add: AddStorageView(existing: nil)
                case .edit(let connection): AddStorageView(existing: connection)
                }
            }
            .confirmationDialog(
                "Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible, presenting: removing
            ) { connection in
                Button("Remove Destination", role: .destructive) {
                    do { try model.remove(connection) } catch { model.lastError = error.localizedDescription }
                }
            } message: { _ in
                Text("Removes the saved connection and its password from this device. Files on the server are not touched.")
            }
        }
    }
}

struct ConnectionRow: View {
    let connection: ConnectionProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                Text(connection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var icon: String {
        switch connection.kind {
        case .smb: return "server.rack"
        case .homeServices: return "house"
        case .localFolder: return "internaldrive"
        case .webDAV: return "globe"
        case .sftp: return "terminal"
        }
    }
}
