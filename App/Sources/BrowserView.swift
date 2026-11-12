import FileCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Browses one folder of one destination. Uploads always target the folder
/// being viewed, so the destination is explicit.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let connection: ConnectionProfile
    let path: RemotePath

    @State private var items: [RemoteItem] = []
    @State private var capacity: StorageCapacity?
    @State private var capabilities: ProviderCapabilities?
    @State private var loading = false
    @State private var error: String?
    @State private var importingFiles = false
    @State private var importingFolder = false
    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var renaming: RemoteItem?
    @State private var renameText = ""
    @State private var deleting: RemoteItem?
    @State private var previewURL: URL?
    @State private var downloading: RemotePath?
    @State private var dropTargeted = false
    @State private var showingTrash = false
    @State private var moving: RemoteItem?

    /// Uploads still running into this exact folder (top level).
    private var activeUploads: [TransferJob] {
        model.jobs.filter { $0.connectionID == connection.id && $0.destination == path && [.queued, .transferring, .verifying, .paused].contains($0.state) }
    }

    private var completedUploadIDs: [UUID] {
        model.jobs.filter { $0.connectionID == connection.id && $0.destination == path && $0.state == .complete }.map(\.id)
    }

    var body: some View {
        List {
            if !path.isRoot {
                NavigationLink("Browse Files Root", value: BrowseLocation(connection: connection, path: .root))
            }
            if !activeUploads.isEmpty {
                Section {
                    ForEach(activeUploads) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Uploading \(job.displayName)").lineLimit(1)
                                Spacer()
                                Text(job.state == .paused ? "Paused" : "\(Int(Double(job.committedBytes) / Double(max(job.totalBytes, 1)) * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(job.committedBytes), total: Double(max(job.totalBytes, 1)))
                        }
                    }
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("browserError")
                    Button("Try Again") { Task { await reload() } }
                }
            }
            Section {
                ForEach(items) { item in
                    row(item)
                }
            } footer: {
                if path.isRoot {
                    Text("Capacity: " + (capacity.map { "\(Format.bytes($0.availableBytes)) free of \(Format.bytes($0.totalBytes))" } ?? "unknown"))
                }
            }
        }
        .overlay {
            if loading && items.isEmpty {
                ProgressView()
            } else if !loading && items.isEmpty && error == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Upload files or a folder here."))
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(4)
            }
        }
        .navigationTitle(path.isRoot ? connection.name : path.name)
        .refreshable { await reload() }
        // Reload on every appearance: returning from a file's detail screen
        // reflects its rename, move, or deletion.
        .onAppear { Task { await reload() } }
        // Show uploaded files as soon as their transfer completes.
        .onChange(of: completedUploadIDs) { Task { await reload() } }
        .sheet(isPresented: $showingTrash) {
            TrashView(connection: connection) { Task { await reload() } }
        }
        .sheet(item: $moving) { item in
            FolderPickerView(connection: connection, moving: item) { destination in
                Task { await move(item, to: destination) }
            }
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            upload(result)
        }
        .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            upload(result)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.enqueueUpload(urls: urls, connection: connection, destination: path) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
                .autocorrectionDisabled()
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) {}
        }
        // `presenting:` hands the item to the action: dismissing the dialog
        // clears the state before an async action would run.
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { item in
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Rename") {
                let name = renameText
                Task { await rename(item, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { item in
            Button(capabilities?.restorableTrash.isSupported == true ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                Task { await delete(item) }
            }
        } message: { _ in
            Text(capabilities?.restorableTrash.isSupported == true
                 ? "The server keeps deleted items in its managed Trash."
                 : "This server has no restorable Trash. The item will be permanently deleted.")
        }
        .filePreview($previewURL)
    }

    private var deleteTitle: String { "Delete “\(deleting?.name ?? "")”?" }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Upload Files…", systemImage: "doc.badge.arrow.up") { importingFiles = true }
                    .accessibilityIdentifier("uploadFiles")
                Button("Upload Folder…", systemImage: "folder.badge.plus") { importingFolder = true }
                    .accessibilityIdentifier("uploadFolder")
                if ProcessInfo.processInfo.environment["FB_UITEST_FIXTURE_UPLOAD"] == "1" {
                    Button("Upload Test Fixture") { Task { await uploadFixture() } }
                        .accessibilityIdentifier("uploadFixture")
                }
                Divider()
                Button("New Folder", systemImage: "folder") {
                    newFolderName = ""
                    showingNewFolder = true
                }
                .disabled(capabilities?.createFolder.isSupported != true)
                if capabilities?.restorableTrash.isSupported == true {
                    Button("Trash", systemImage: "trash") { showingTrash = true }
                        .accessibilityIdentifier("openTrash")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("browserAdd")
        }
    }

    @ViewBuilder
    private func row(_ item: RemoteItem) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : icon(for: item.name))
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                HStack(spacing: 6) {
                    if let size = item.size { Text(Format.bytes(size)) }
                    if let modified = item.modified { Text(modified, style: .date) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if downloading == item.path { ProgressView() }
        }
        Group {
            if item.isDirectory {
                NavigationLink(value: BrowseLocation(connection: connection, path: item.path)) { label }
            } else {
                NavigationLink { FileDetailView(connection: connection, item: item) } label: { label }
            }
        }
        .accessibilityIdentifier("item-\(item.name)")
        .swipeActions {
            Button(capabilities?.restorableTrash.isSupported == true ? "Trash" : "Delete", role: .destructive) { deleting = item }
            Button("Move") { moving = item }.tint(.indigo)
            Button("Rename") {
                renameText = item.name
                renaming = item
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button("Preview", systemImage: "eye") { Task { await preview(item) } }
            }
            Button("Rename", systemImage: "pencil") {
                renameText = item.name
                renaming = item
            }
            .disabled(capabilities?.rename.isSupported != true)
            Button("Move…", systemImage: "folder") { moving = item }
                .disabled(capabilities?.rename.isSupported != true)
            Button(capabilities?.restorableTrash.isSupported == true ? "Move to Trash" : "Delete", systemImage: "trash", role: .destructive) { deleting = item }
        }
    }

    private func icon(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "archivebox" }
        return "doc"
    }

    // MARK: Actions

    private func withProvider<T>(_ body: (any StorageProvider) async throws -> T) async throws -> T {
        let provider = try model.provider(for: connection)
        try await provider.connect()
        capabilities = provider.capabilities
        do {
            let result = try await body(provider)
            await provider.disconnect()
            return result
        } catch {
            await provider.disconnect()
            throw error
        }
    }

    private func report(_ error: any Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let isRoot = path.isRoot
            let (listing, capacity) = try await withProvider { provider in
                (try await provider.list(path), isRoot ? try? await provider.capacity() : nil)
            }
            items = listing.filter { !$0.name.hasPrefix(TempFileUploadSink.tempPrefix) }
            self.capacity = capacity
            error = nil
        } catch {
            report(error)
        }
    }

    private func upload(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task { await model.enqueueUpload(urls: urls, connection: connection, destination: path) }
        case .failure(let error):
            report(error)
        }
    }

    private func upload(_ result: Result<URL, any Error>) {
        upload(result.map { [$0] })
    }

    private func createFolder() async {
        do {
            let target = try path.appending(newFolderName.trimmingCharacters(in: .whitespaces))
            try await withProvider { try await $0.createDirectory(target) }
            await reload()
        } catch {
            report(error)
        }
    }

    private func rename(_ item: RemoteItem, to name: String) async {
        guard let parent = item.path.parent else { return }
        do {
            let target = try parent.appending(name.trimmingCharacters(in: .whitespaces))
            try await withProvider { try await $0.move(item.path, to: target) }
            await reload()
        } catch {
            report(error)
        }
        renaming = nil
    }

    private func move(_ item: RemoteItem, to directory: RemotePath) async {
        do {
            let target = try directory.appending(item.name)
            try await withProvider { try await $0.move(item.path, to: target) }
            await reload()
        } catch {
            report(error)
        }
    }

    private func delete(_ item: RemoteItem) async {
        do {
            try await withProvider { try await $0.delete(item.path) }
            await reload()
        } catch {
            report(error)
        }
        deleting = nil
    }

    private func preview(_ item: RemoteItem) async {
        downloading = item.path
        defer { downloading = nil }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Previews/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(item.name)
            try await withProvider { try await $0.download(item.path, to: destination) { _ in } }
            previewURL = destination
        } catch {
            report(error)
        }
    }

    /// UI-test-only: builds a disposable nested folder and uploads it.
    private func uploadFixture() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)/FB Acceptance", isDirectory: true)
        let files: [String: Data] = [
            "notes.txt": Data("Files & Backups acceptance fixture\n".utf8),
            "Day 1/photo.bin": Data((0..<750_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }),
            "Day 1/Café ☕️/menu.txt": Data("crème brûlée\n".utf8),
            "Day 2/empty.dat": Data(),
        ]
        var all = files
        if let megabytes = Int(ProcessInfo.processInfo.environment["FB_UITEST_FIXTURE_MB"] ?? ""), megabytes > 0 {
            all["Day 2/large.bin"] = Data((0..<(megabytes << 20)).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 11)) })
        }
        for (relative, data) in all {
            let url = root.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Empty Folder"), withIntermediateDirectories: true)
        await model.enqueueUpload(urls: [root], connection: connection, destination: path)
    }
}
