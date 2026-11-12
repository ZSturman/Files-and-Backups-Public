import FileCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share Extension: copies shared files into the app's bounded transfer
/// storage and queues an upload to an explicitly chosen destination. The
/// upload itself runs in the app (credentials never enter the extension).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor
@Observable
final class ShareModel {
    static let appGroup = "group.com.zacharysturman.filesbackups"

    let context: NSExtensionContext?
    let support: URL?
    var connections: [ConnectionProfile] = []
    var selected: ConnectionProfile.ID? {
        didSet { if oldValue != selected { applyDefaultFolder() } }
    }
    var folder = ""
    var itemCount = 0
    var status: String?
    var working = false
    var finished = false

    init(context: NSExtensionContext?) {
        self.context = context
        support = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("FilesBackupsApp", isDirectory: true)
        if let support {
            connections = ConnectionStore(url: support.appendingPathComponent("connections.json"), credentials: InMemoryCredentialStore()).load()
            selected = connections.first?.id
        }
        applyDefaultFolder()
        itemCount = providers.count
    }

    private func applyDefaultFolder() {
        let defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        if defaults.string(forKey: "piConnection.profile.v1") == selected?.uuidString {
            folder = defaults.string(forKey: "piConnection.uploadFolder.v1") ?? ""
        } else { folder = "" }
    }

    private var providers: [NSItemProvider] {
        (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    func queue() async {
        guard let support, let connection = connections.first(where: { $0.id == selected }) else { return }
        working = true
        defer { working = false }
        do {
            let destination = try RemotePath(folder)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            var files: [URL] = []
            for provider in providers {
                files.append(try await Self.copy(provider, into: scratch))
            }
            let staging = StagingArea(
                root: support.appendingPathComponent("Staging", isDirectory: true),
                quotaBytes: Int64(UserDefaults(suiteName: Self.appGroup)?.object(forKey: "stagingQuotaGB") as? Int ?? 10) << 30
            )
            let jobID = UUID()
            let staged = try staging.stage(files: files, jobID: jobID)
            let verify = UserDefaults(suiteName: Self.appGroup)?.object(forKey: "verifyByReadBack") as? Bool ?? true
            let job = TransferJob(
                id: jobID, connectionID: connection.id, connectionName: connection.name, destination: destination,
                rootFolderName: nil, directories: [], items: staged.items, verifyContents: verify
            )
            try TransferInbox(directory: support.appendingPathComponent("Inbox", isDirectory: true)).deposit(job)
            status = "Queued \(staged.items.count) item(s) for \(connection.name). Open Files & Backups to upload; SMB and SFTP uploads run while the app is open."
            finished = true
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func done() {
        context?.completeRequest(returningItems: nil)
    }

    /// Copies one shared item to `directory` while its temporary URL is valid.
    static func copy(_ provider: NSItemProvider, into directory: URL) async throws -> URL {
        let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) ?? UTType.data.identifier
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? FileCoreError.permissionDenied("the shared item could not be read"))
                    return
                }
                let name = (provider.suggestedName.map { $0 + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)") }) ?? url.lastPathComponent
                let safe = name.replacingOccurrences(of: "/", with: "-")
                let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(safe)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if model.support == nil {
                    Text("Shared storage is unavailable. Open Files & Backups once, then try again.")
                } else if model.connections.isEmpty {
                    Text("Add a destination in Files & Backups first.")
                } else {
                    Section("Destination") {
                        Picker("Upload to", selection: $model.selected) {
                            ForEach(model.connections) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("Folder (optional)", text: $model.folder, prompt: Text("e.g. Phone Uploads"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Section {
                        Text("\(model.itemCount) item(s). Existing files are never overwritten; same names are kept as “Name (2)”.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let status = model.status {
                    Section { Text(status) }
                }
            }
            .navigationTitle("Files & Backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }.disabled(model.working || model.finished)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.finished {
                        Button("Done") { model.done() }
                    } else {
                        Button(model.working ? "Copying…" : "Queue Upload") { Task { await model.queue() } }
                            .disabled(model.working || model.selected == nil || model.itemCount == 0)
                    }
                }
            }
        }
    }
}
