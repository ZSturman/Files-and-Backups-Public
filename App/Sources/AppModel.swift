import FileCore
import FileCoreSFTP
import FileCoreSMB
import Foundation
import HomeServicesConnection
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// App-wide state: saved destinations, the persistent transfer queue, and
/// settings. Each connection's provider is built on demand from its profile
/// and its own Keychain secret.
@MainActor
@Observable
final class AppModel {
    private(set) var connections: [ConnectionProfile] = []
    private(set) var jobs: [TransferJob] = []
    var verifyByReadBack: Bool {
        didSet { AppModel.defaults.set(verifyByReadBack, forKey: "verifyByReadBack") }
    }
    var stagingQuotaGB: Int {
        didSet {
            AppModel.defaults.set(stagingQuotaGB, forKey: "stagingQuotaGB")
            staging.quotaBytes = Int64(stagingQuotaGB) << 30
        }
    }
    var homePageBackupWarnings: Int?
    var lastError: String?

    let credentials: any CredentialStore
    let connectionStore: ConnectionStore
    let staging: StagingArea
    let queue: TransferQueue
    let appSupport: URL

    init(appSupport: URL? = nil, credentials: (any CredentialStore)? = nil) {
        let support = appSupport ?? AppModel.sharedSupportDirectory()
        self.appSupport = support
        let credentials = credentials ?? KeychainCredentialStore()
        self.credentials = credentials
        connectionStore = ConnectionStore(url: support.appendingPathComponent("connections.json"), credentials: credentials)
        let quota = AppModel.defaults.object(forKey: "stagingQuotaGB") as? Int ?? 10
        stagingQuotaGB = quota
        verifyByReadBack = AppModel.defaults.object(forKey: "verifyByReadBack") as? Bool ?? true
        staging = StagingArea(root: support.appendingPathComponent("Staging", isDirectory: true), quotaBytes: Int64(quota) << 30)
        let connectionStore = connectionStore
        queue = TransferQueue(store: TransferStore(url: support.appendingPathComponent("transfers.json")), staging: staging) { id in
            guard let profile = connectionStore.load().first(where: { $0.id == id }) else {
                throw FileCoreError.invalidConfiguration("this destination was removed")
            }
            return try ProviderFactory.make(profile: profile, secret: try credentials.secret(for: id))
        }
        connections = connectionStore.load()
        observeQueue()
        Task { await refreshPiPreferences() }
        let pending = TransferInbox(directory: support.appendingPathComponent("Inbox", isDirectory: true)).collect()
        Task { [staging, queue] in
            for job in pending { await queue.enqueue(job) }
            staging.removeOrphans(keeping: Set(await queue.jobs.map(\.id)), olderThan: 3600)
        }
    }

    static let appGroup = "group.com.zacharysturman.filesbackups"

    /// Settings shared with the Share Extension on iOS.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        #if os(iOS)
        return UserDefaults(suiteName: appGroup) ?? .standard
        #else
        return .standard
        #endif
    }()

    /// On iOS the app and Share Extension share an App Group container; the
    /// Mac app (no extension) uses its own Application Support folder.
    static func sharedSupportDirectory() -> URL {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appendingPathComponent("FilesBackupsApp", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilesBackupsApp", isDirectory: true)
    }

    var inbox: TransferInbox { TransferInbox(directory: appSupport.appendingPathComponent("Inbox", isDirectory: true)) }

    /// Enqueues uploads prepared by the Share Extension.
    func importInbox() {
        let jobs = inbox.collect()
        guard !jobs.isEmpty else { return }
        Task { [queue] in
            for job in jobs { await queue.enqueue(job) }
        }
    }

    private func observeQueue() {
        Task { [weak self, queue] in
            for await jobs in await queue.updates() {
                self?.jobs = jobs.sorted { $0.createdAt > $1.createdAt }
            }
        }
    }

    // MARK: Connections

    func refreshPiPreferences() async {
        guard AppModel.defaults.string(forKey: "piConnection.profile.v1") != nil else { return }
        do {
            let client = try PairingClient(expectedPreset: "files-backups", keychainService: "com.zacharysturman.filesbackups.pi")
            guard client.credential != nil else { return }
            try await client.refresh()
            AppModel.defaults.set(client.connection?.preferences["upload_folder"], forKey: "piConnection.uploadFolder.v1")
        } catch {
            // The adapter's ordinary requests report availability/auth errors.
            // Keep the last good preference during an outage.
        }
    }

    func provider(for profile: ConnectionProfile) throws -> any StorageProvider {
        try ProviderFactory.make(profile: profile, secret: try credentials.secret(for: profile.id))
    }

    func save(_ profile: ConnectionProfile, secret: String?) throws {
        try connectionStore.upsert(profile, secret: secret)
        connections = connectionStore.load()
    }

    func remove(_ profile: ConnectionProfile) throws {
        try connectionStore.remove(profile.id)
        connections = connectionStore.load()
    }

    // MARK: Transfers

    /// Imports picked or dropped items into staging and queues uploads to an
    /// explicit destination folder. Folders become one job each.
    func enqueueUpload(urls: [URL], connection: ConnectionProfile, destination: RemotePath) async {
        let verify = verifyByReadBack
        let staging = staging
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if scoped { url.stopAccessingSecurityScopedResource() }
            if isDirectory { folders.append(url) } else { files.append(url) }
        }
        do {
            var newJobs: [TransferJob] = []
            for folder in folders {
                let jobID = UUID()
                let staged = try await Task.detached { try staging.stage(folder: folder, jobID: jobID) }.value
                if staged.skippedSymbolicLinks > 0 {
                    lastError = "\(staged.skippedSymbolicLinks) symbolic link(s) in \(staged.rootFolderName ?? "the folder") were skipped."
                }
                newJobs.append(TransferJob(
                    id: jobID, connectionID: connection.id, connectionName: connection.name, destination: destination,
                    rootFolderName: staged.rootFolderName, directories: staged.directories, items: staged.items, verifyContents: verify
                ))
            }
            if !files.isEmpty {
                let jobID = UUID()
                let staged = try await Task.detached { try staging.stage(files: files, jobID: jobID) }.value
                newJobs.append(TransferJob(
                    id: jobID, connectionID: connection.id, connectionName: connection.name, destination: destination,
                    rootFolderName: nil, directories: [], items: staged.items, verifyContents: verify
                ))
            }
            for job in newJobs { await queue.enqueue(job) }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func pause(_ job: TransferJob) { Task { await queue.pause(job.id) } }
    func resume(_ job: TransferJob) { Task { await queue.resume(job.id) } }
    func retry(_ job: TransferJob) { Task { await queue.retry(job.id) } }
    func cancel(_ job: TransferJob) { Task { await queue.cancel(job.id) } }
    func clearFinished() { Task { await queue.removeFinished() } }

    var stagingUsedBytes: Int64 { staging.usedBytes() }

    // MARK: Lifecycle

    /// iOS suspends sockets in the background: stop at a durable point and
    /// continue when the app becomes active again.
    func didEnterBackground() {
        #if canImport(UIKit)
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Pause transfers") {
            UIApplication.shared.endBackgroundTask(task)
        }
        Task {
            await queue.suspendForBackground()
            UIApplication.shared.endBackgroundTask(task)
        }
        #endif
    }

    func didBecomeActive() {
        Task { await refreshPiPreferences() }
        connections = connectionStore.load()
        importInbox()
        Task { await queue.resumeAfterInterruption() }
    }
}

enum ProviderFactory {
    static func make(profile: ConnectionProfile, secret: String?) throws -> any StorageProvider {
        switch profile.kind {
        case .smb:
            guard let secret else { throw FileCoreError.missingCredential }
            return SMBProvider(configuration: try SMBProvider.Configuration(profile: profile, password: secret))
        case .homeServices:
            guard let secret else { throw FileCoreError.missingCredential }
            guard let url = URL(string: profile.baseURL) else { throw FileCoreError.invalidConfiguration("invalid URL") }
            return try HomeServicesProvider(baseURL: url, token: secret, root: try profile.validatedRoot())
        case .localFolder:
            guard let bookmark = profile.bookmark else { throw FileCoreError.invalidConfiguration("choose the folder again") }
            var stale = false
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            #endif
            return LocalFolderProvider(rootURL: url, bookmark: bookmark)
        case .webDAV:
            guard let secret else { throw FileCoreError.missingCredential }
            guard let url = URL(string: profile.baseURL) else { throw FileCoreError.invalidConfiguration("invalid URL") }
            return try WebDAVProvider(baseURL: url, root: try profile.validatedRoot(), username: profile.username, password: secret)
        case .sftp:
            guard let secret else { throw FileCoreError.missingCredential }
            guard let pinned = profile.pinnedHostKey else {
                throw FileCoreError.invalidConfiguration("run Test Connection to record the server's host key")
            }
            return SFTPProvider(configuration: .init(
                host: profile.host, port: profile.port ?? 22, root: profile.rootPath,
                username: profile.username, password: secret, pinnedHostKey: pinned
            ))
        }
    }
}
