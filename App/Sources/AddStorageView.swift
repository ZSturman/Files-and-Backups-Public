import FileCore
import FileCoreSFTP
import FileCoreSMB
import SwiftUI

/// Add Storage: provider type, name, server/share or URL/root, credentials,
/// Test Connection, capability summary, Save.
struct AddStorageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: ConnectionProfile?

    @State private var kind: ProviderKind = .smb
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var share = ""
    @State private var rootPath = ""
    @State private var username = ""
    @State private var domain = ""
    @State private var secret = ""
    @State private var baseURL = ""
    @State private var requireEncryption = false
    @State private var bookmark: Data?
    @State private var pinnedHostKey: String?
    @State private var folderName: String?
    @State private var choosingFolder = false

    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var shares: [String] = []
    @State private var findingShares = false

    enum TestResult {
        case success(ProviderCapabilities, StorageCapacity?)
        case failure(String)
    }

    private var availableKinds: [ProviderKind] {
        #if os(macOS)
        return ProviderKind.allCases
        #else
        return ProviderKind.allCases.filter { $0 != .localFolder }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(availableKinds) { kind in
                            Text(kind.isAvailable ? kind.displayName : "\(kind.displayName) — planned").tag(kind)
                        }
                    }
                    .accessibilityIdentifier("providerType")
                    .disabled(existing != nil)
                    TextField("Name", text: $name, prompt: Text("e.g. Studio Mac HDD"))
                        .accessibilityIdentifier("connectionName")
                }

                switch kind {
                case .smb: smbFields
                case .homeServices: homeServicesFields
                case .localFolder: localFolderFields
                case .webDAV: webDAVFields
                case .sftp: sftpFields
                }

                if kind.isAvailable {
                    Section {
                        Button {
                            dismissKeyboard()
                            Task {
                                await test()
                                // Let the result rows exist before scrolling to them.
                                try? await Task.sleep(for: .milliseconds(250))
                                withAnimation { proxy.scrollTo("testResult", anchor: .center) }
                            }
                        } label: {
                            HStack {
                                Text("Test Connection")
                                if testing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(testing || !isComplete)
                        .accessibilityIdentifier("testConnection")
                    } footer: {
                        Text(networkFooter)
                    }
                    if let testResult { resultSection(testResult) }
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(existing == nil ? "Add Storage" : "Edit Storage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!kind.isAvailable || !isComplete)
                        .accessibilityIdentifier("saveConnection")
                }
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                chooseFolder(result)
            }
            .onAppear(perform: load)
            .onChange(of: kind) { testResult = nil }
            .onChange(of: host) { if existing == nil { pinnedHostKey = nil } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var networkFooter: String {
        switch kind {
        case .smb:
            return "Use a LAN address, a .local name, or a Tailscale address/MagicDNS name. The computer or NAS must be awake with file sharing on, and its drive mounted. Tailscale provides the route only."
        case .homeServices:
            return "Home Services is optional. It adds managed transfers, Trash, storage health, and backup history."
        default:
            return ""
        }
    }

    private var smbFields: some View {
        Group {
            Section("Server") {
                TextField("Host", text: $host, prompt: Text("192.168.1.20, studio.local, or host.example.net"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("smbHost")
                TextField("Port (optional, default 445)", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityIdentifier("smbPort")
            }
            Section("Account") {
                TextField("User name", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("smbUser")
                SecureField(existing == nil ? "Password" : "Password (leave blank to keep)", text: $secret)
                    .textContentType(.password)
                    .accessibilityIdentifier("smbPassword")
                TextField("Domain (optional)", text: $domain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Section {
                HStack {
                    TextField("Share", text: $share, prompt: Text("e.g. Files"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("smbShare")
                    Button(findingShares ? "Finding…" : "Find Shares") { Task { await findShares() } }
                        .disabled(host.isEmpty || username.isEmpty || effectiveSecret == nil || findingShares)
                        .accessibilityIdentifier("findShares")
                }
                if !shares.isEmpty {
                    Picker("Available shares", selection: $share) {
                        ForEach(shares, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Folder inside share (optional)", text: $rootPath, prompt: Text("e.g. Uploads"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("smbRoot")
                Toggle("Require SMB3 encryption", isOn: $requireEncryption)
            } header: {
                Text("Share")
            } footer: {
                Text("This connection can only reach files inside the chosen share and folder. SMB1 is never used.")
            }
        }
    }

    private var homeServicesFields: some View {
        Section {
            TextField("https://host.example.net:8443", text: $baseURL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            SecureField(existing == nil ? "App token" : "App token (leave blank to keep)", text: $secret)
            TextField("Root folder (optional)", text: $rootPath)
        } header: {
            Text("Home Services")
        } footer: {
            Text("Home Services contract v1. Use a token created with the files-backups preset. Deletes go to its 7-day managed Trash.")
        }
    }

    private var webDAVFields: some View {
        Section {
            TextField("https://nas.example.com/dav/", text: $baseURL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityIdentifier("webdavURL")
            TextField("User name", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField(existing == nil ? "Password" : "Password (leave blank to keep)", text: $secret)
                .textContentType(.password)
            TextField("Folder (optional)", text: $rootPath)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("WebDAV server")
        } footer: {
            Text("HTTPS only. Interrupted uploads restart the current file because WebDAV has no standard partial upload. Deletes are permanent.")
        }
    }

    private var sftpFields: some View {
        Group {
            Section("Server") {
                TextField("Host", text: $host, prompt: Text("pi.local or host.example.net"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Port (optional, default 22)", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                TextField("User name", text: $username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(existing == nil ? "Password" : "Password (leave blank to keep)", text: $secret)
                TextField("Folder", text: $rootPath, prompt: Text("/srv/files or files (relative to home)"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Section {
                if let pinnedHostKey {
                    LabeledContent("Host key", value: SFTPProvider.fingerprint(ofOpenSSHKey: pinnedHostKey) ?? "recorded")
                        .font(.caption)
                } else {
                    Text("Test Connection to see the server's host key fingerprint. Compare it with the server (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) before saving.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("The saved host key is required on every connection; a changed key is refused.")
            }
        }
    }

    private var localFolderFields: some View {
        Section {
            Button(folderName ?? "Choose Folder or Disk…") { choosingFolder = true }
        } footer: {
            Text("Access is limited to the folder you choose. An external disk must be connected to browse or upload.")
        }
    }

    @ViewBuilder
    private func resultSection(_ result: TestResult) -> some View {
        switch result {
        case .failure(let message):
            Section("Test result") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("testFailure")
                    .id("testResult")
            }
        case .success(let capabilities, let capacity):
            Section("Capabilities") {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("connectedSummary")
                    .id("testResult")
                ForEach(capabilities.summaryRows, id: \.0) { row in
                    CapabilityRow(title: row.0, support: row.1)
                }
                LabeledContent("Verification", value: capabilities.bestVerification.displayName)
                LabeledContent("Capacity", value: capacity.map { "\(Format.bytes($0.availableBytes)) free of \(Format.bytes($0.totalBytes))" } ?? "Unknown")
            }
            .accessibilityIdentifier("testSuccess")
        }
    }

    // MARK: Logic

    private var effectiveSecret: String? {
        if !secret.isEmpty { return secret }
        if let existing { return try? model.credentials.secret(for: existing.id) }
        return nil
    }

    private var isComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .smb: return !host.isEmpty && !share.isEmpty && !username.isEmpty && effectiveSecret != nil && (port.isEmpty || Int(port) != nil)
        case .homeServices: return URL(string: baseURL)?.scheme == "https" && effectiveSecret != nil
        case .webDAV: return URL(string: baseURL)?.scheme == "https" && !username.isEmpty && effectiveSecret != nil
        case .localFolder: return bookmark != nil
        case .sftp: return !host.isEmpty && !username.isEmpty && effectiveSecret != nil && pinnedHostKey != nil && (port.isEmpty || Int(port) != nil)
        }
    }

    private func profile() -> ConnectionProfile {
        ConnectionProfile(
            id: existing?.id ?? UUID(), kind: kind, name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces), port: Int(port), share: share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ")),
            rootPath: rootPath, username: username, domain: domain, baseURL: baseURL, requireEncryption: requireEncryption,
            bookmark: bookmark, pinnedHostKey: pinnedHostKey, createdAt: existing?.createdAt ?? Date()
        )
    }

    private func load() {
        guard let existing else {
            prefillForUITests()
            return
        }
        kind = existing.kind
        name = existing.name
        host = existing.host
        port = existing.port.map(String.init) ?? ""
        share = existing.share
        rootPath = existing.rootPath
        username = existing.username
        domain = existing.domain
        baseURL = existing.baseURL
        requireEncryption = existing.requireEncryption
        bookmark = existing.bookmark
        pinnedHostKey = existing.pinnedHostKey
        folderName = existing.kind == .localFolder ? existing.rootPath : nil
    }

    /// UI tests on devices prefill the SMB form instead of typing (XCUITest
    /// typing on iPad waits for idle after every keystroke).
    private func prefillForUITests() {
        let env = ProcessInfo.processInfo.environment
        guard env["FB_UITEST_PREFILL"] == "1" else { return }
        if env["FB_UITEST_PREFILL_KIND"] == "homeServices" {
            kind = .homeServices
            name = env["FB_UITEST_NAME"] ?? "Home Services"
            baseURL = env["FB_HS_TEST_URL"] ?? ""
            secret = env["FB_HS_TEST_TOKEN"] ?? ""
            rootPath = env["FB_HS_TEST_ROOT"] ?? ""
            return
        }
        kind = .smb
        name = env["FB_UITEST_NAME"] ?? "Test Share"
        host = env["FB_SMB_TEST_HOST"] ?? ""
        port = env["FB_SMB_TEST_PORT"] ?? ""
        share = env["FB_SMB_TEST_SHARE"] ?? ""
        username = env["FB_SMB_TEST_USER"] ?? ""
        secret = env["FB_SMB_TEST_PASSWORD"] ?? ""
        rootPath = env["FB_SMB_TEST_ROOT"] ?? ""
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let candidate = profile()
            if candidate.kind != .sftp { _ = try candidate.validatedRoot() }
            let provider: any StorageProvider
            if candidate.kind == .sftp {
                // First contact records the presented key; afterwards it is required.
                let sftp = SFTPProvider(configuration: .init(
                    host: candidate.host, port: candidate.port ?? 22, root: candidate.rootPath, username: candidate.username,
                    password: effectiveSecret ?? "", pinnedHostKey: candidate.pinnedHostKey
                ))
                defer { if pinnedHostKey == nil { pinnedHostKey = sftp.presentedHostKey } }
                provider = sftp
                try await provider.connect()
            } else {
                provider = try ProviderFactory.make(profile: candidate, secret: effectiveSecret)
                try await provider.connect()
            }
            let capacity = try? await provider.capacity()
            let capabilities = provider.capabilities
            await provider.disconnect()
            testResult = .success(capabilities, capacity)
        } catch {
            testResult = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func findShares() async {
        guard let password = effectiveSecret else { return }
        findingShares = true
        defer { findingShares = false }
        do {
            shares = try await SMBProvider.listShares(host: host, port: Int(port), username: username, domain: domain, password: password)
            if share.isEmpty, let first = shares.first { share = first }
        } catch {
            testResult = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func chooseFolder(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        bookmark = try? url.bookmarkData()
        #endif
        folderName = url.lastPathComponent
        rootPath = url.lastPathComponent
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func save() {
        do {
            let candidate = profile()
            if candidate.kind != .sftp { _ = try candidate.validatedRoot() }
            try model.save(candidate, secret: secret.isEmpty ? nil : secret)
            dismiss()
        } catch {
            testResult = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

struct CapabilityRow: View {
    let title: String
    let support: CapabilitySupport

    var body: some View {
        switch support {
        case .supported:
            Label(title, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.primary, .green)
        case .unsupported(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: "minus.circle")
                    .foregroundStyle(.secondary, .secondary)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
