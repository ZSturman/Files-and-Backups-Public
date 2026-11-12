import FileCore
import SwiftUI

/// One file: metadata and every action in plain sight (Open, Share, Rename,
/// Move, Delete/Trash). Navigation links work reliably on iPhone, iPad, and
/// Mac, unlike tap targets inside list rows.
struct FileDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: ConnectionProfile
    @State var item: RemoteItem

    @State private var capabilities: ProviderCapabilities?
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var working: String?
    @State private var error: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var moving = false
    @State private var confirmingDelete = false

    private var trash: Bool { capabilities?.restorableTrash.isSupported == true }

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: item.name)
                LabeledContent("Folder", value: item.path.parent.map { $0.isRoot ? connection.name : $0.description } ?? connection.name)
                if let size = item.size { LabeledContent("Size", value: Format.bytes(size)) }
                if let modified = item.modified { LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section {
                Button { Task { await open(share: false) } } label: { Label("Open", systemImage: "eye") }
                    .accessibilityIdentifier("openFile")
                Button { Task { await open(share: true) } } label: { Label("Share or Save…", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("shareFile")
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share \(item.name)", systemImage: "square.and.arrow.up.on.square") }
                }
            }
            Section {
                Button { renameText = item.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    .disabled(capabilities?.rename.isSupported != true)
                    .accessibilityIdentifier("renameFile")
                Button { moving = true } label: { Label("Move…", systemImage: "folder") }
                    .disabled(capabilities?.rename.isSupported != true)
                    .accessibilityIdentifier("moveFile")
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(trash ? "Move to Trash" : "Delete Permanently", systemImage: "trash")
                }
                .accessibilityIdentifier("deleteFile")
            }
        }
        .overlay { if let working { ProgressView(working).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle(item.name)
        .task { await loadCapabilities() }
        .filePreview($previewURL)
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Rename") {
                let name = renameText
                Task { await rename(to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("\(trash ? "Move" : "Delete") “\(item.name)”\(trash ? " to Trash" : "")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(trash ? "Move to Trash" : "Delete Permanently", role: .destructive) { Task { await delete() } }
        } message: {
            Text(trash ? "The server keeps it in its managed Trash for 7 days." : "This server has no restorable Trash. The file will be permanently deleted.")
        }
        .sheet(isPresented: $moving) {
            FolderPickerView(connection: connection, moving: item) { destination in
                Task { await move(to: destination) }
            }
        }
    }

    private func report(_ error: any Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func withProvider<T>(_ label: String, _ body: (any StorageProvider) async throws -> T) async throws -> T {
        working = label
        defer { working = nil }
        let provider = try model.provider(for: connection)
        try await provider.connect()
        capabilities = provider.capabilities
        defer { Task { await provider.disconnect() } }
        return try await body(provider)
    }

    private func loadCapabilities() async {
        do { _ = try await withProvider("Connecting…") { _ in () } } catch { report(error) }
    }

    private func open(share: Bool) async {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Previews/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(item.name)
            try await withProvider("Downloading…") { try await $0.download(item.path, to: destination) { _ in } }
            error = nil
            if share { shareURL = destination } else { previewURL = destination }
        } catch {
            report(error)
        }
    }

    private func rename(to name: String) async {
        guard let parent = item.path.parent else { return }
        do {
            let target = try parent.appending(name.trimmingCharacters(in: .whitespaces))
            try await withProvider("Renaming…") { try await $0.move(item.path, to: target) }
            item.path = target
            error = nil
        } catch {
            report(error)
        }
    }

    private func move(to directory: RemotePath) async {
        do {
            let target = try directory.appending(item.name)
            try await withProvider("Moving…") { try await $0.move(item.path, to: target) }
            dismiss()
        } catch {
            report(error)
        }
    }

    private func delete() async {
        do {
            try await withProvider(trash ? "Moving to Trash…" : "Deleting…") { try await $0.delete(item.path) }
            dismiss()
        } catch {
            report(error)
        }
    }
}
