// Home Page feed v1. Ship with ConnectedAppsCore.swift and ConnectedAppsUI.swift.
// Consumer copies have no dependency on another checkout.
// Changes to the wire format must remain compatible with docs/INTEGRATIONS.md.
import Foundation
import Combine
import CryptoKit
import SwiftUI
import AppIntents
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

struct HomePageExportItem: Codable, Equatable {
    var id: String
    var revision: String
    var priority: String
    var title: String
    var detail: String? = nil
    var createdAt: Date = .distantPast
    var expiresAt: Date? = nil
    var actionID: String? = nil
    var originID: String? = nil
}
struct HomePageExportContent: Equatable {
    var sourceID: String
    var summary: String
    var state = "normal"
    var items: [HomePageExportItem] = []
}
private struct HomePageExportSnapshot: Codable {
    var schemaVersion = 1
    var sourceID: String
    var generatedAt: Date
    var expiresAt: Date
    var summary: String
    var state: String
    var items: [HomePageExportItem]
}

@MainActor final class HomePageExport: ObservableObject {
    static let shared = HomePageExport()
    private static let queue = DispatchQueue(label: "HomePageExport.writer", qos: .utility)
    @Published var enabled = UserDefaults.standard.bool(forKey: "homePageExport.enabled.v1") {
        didSet {
            guard !Self.isolated else { return }
            UserDefaults.standard.set(enabled, forKey: "homePageExport.enabled.v1")
            if enabled { heartbeat() } else { removeExport() }
        }
    }
    static let downloadURL = URL(string: "https://apps.apple.com/app/id6826961996")!
    nonisolated static var summaryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePageShare/" + (Bundle.main.bundleIdentifier ?? "source") + "/summary.json")
    }
    @Published private(set) var error: String?
    private var latest: HomePageExportContent?
    private var heartbeatTask: Task<Void, Never>?
    private var onsets: [String: (String, Date)] = [:]
    static var supported: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #elseif os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac
        #else
        return false
        #endif
    }
    private static var isolated: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains { arg in
                ["uitest", "fixture", "acceptance", "isolated"].contains { arg.lowercased().contains($0) }
            }
    }
    func update(_ content: HomePageExportContent) {
        if !Self.isolated, let latest {
            let currentIDs = Set(content.items.map(\.id))
            for item in latest.items where !currentIDs.contains(item.id) {
                onsets[item.id] = nil
                UserDefaults.standard.removeObject(forKey: "homePageExport.onset.\(latest.sourceID).\(item.id)")
            }
        }
        latest = content; heartbeat()
    }
    static func revision(_ identities: [String]) -> String {
        SHA256.hash(data: Data(identities.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Used by menu-bar / AppKit apps whose dashboard window can be absent.
    func start(summary: @escaping @MainActor () -> HomePageExportContent?) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task {
            while !Task.isCancelled {
                if let content = summary() { update(content) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    func heartbeat() {
        guard !Self.isolated, let latest else { return }
        do {
            let now = Date()
            var items = latest.items
            for index in items.indices {
                let item = items[index]
                if onsets[item.id]?.0 != item.revision {
                    let key = "homePageExport.onset.\(latest.sourceID).\(item.id)"
                    let saved = UserDefaults.standard.dictionary(forKey: key)
                    let date = saved?["revision"] as? String == item.revision ? (saved?["date"] as? Date ?? now) : now
                    onsets[item.id] = (item.revision, date)
                    UserDefaults.standard.set(["revision": item.revision, "date": date], forKey: key)
                }
                items[index].createdAt = onsets[item.id]?.1 ?? now
                items[index].revision = item.revision + "|" + String(Int(items[index].createdAt.timeIntervalSince1970))
                items[index].expiresAt = now.addingTimeInterval(900)
            }
            let snapshot = HomePageExportSnapshot(sourceID: latest.sourceID, generatedAt: now,
                expiresAt: now.addingTimeInterval(900), summary: latest.summary, state: latest.state, items: items)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            ConnectedApps.shared.publish(data)
            guard enabled, Self.supported else { return }
            guard data.count <= 32768 else { error = "Summary is too large to share."; return }
            let file = Self.summaryURL
            Self.queue.async { [weak self] in
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                    #if os(macOS)
                    if let raw = String(data: data, encoding: .utf8) {
                        DistributedNotificationCenter.default().postNotificationName(.init("com.zacharysturman.homepage.snapshot.v1"), object: raw, userInfo: nil, deliverImmediately: true)
                    }
                    #endif
                    Task { @MainActor in self?.error = nil }
                } catch { Task { @MainActor in self?.error = "Could not save the shared summary." } }
            }
        } catch { self.error = "Could not prepare the summary." }
    }
    func sendCurrentSummary() {
        guard enabled, !Self.isolated else { return }
        Self.queue.async { [weak self] in
            guard let data = try? Data(contentsOf: Self.summaryURL), data.count <= 32768,
                  let raw = String(data: data, encoding: .utf8) else { return }
            var c = URLComponents(); c.scheme = "homepage"; c.host = "receive"
            c.queryItems = [.init(name: "snapshot", value: raw)]
            guard let url = c.url else { return }
            Task { @MainActor in
                #if os(macOS)
                if !NSWorkspace.shared.open(url) { self?.error = "Install Home Page using the download link below." }
                #elseif os(iOS)
                UIApplication.shared.open(url, options: [:]) { opened in
                    if !opened { Task { @MainActor in self?.error = "Install Home Page using the download link below." } }
                }
                #endif
            }
        }
    }
    private func removeExport() {
        guard !Self.isolated else { return }
        let file = Self.summaryURL
        Self.queue.async { try? FileManager.default.removeItem(at: file) }
    }

}

struct HomePageExportSettings: View {
    @ObservedObject private var exporter = HomePageExport.shared
    var body: some View {
        ConnectedAppsSettings()
        if HomePageExport.supported {
            Section("Legacy Home Page Summary") {
                Toggle("Broadcast a legacy summary locally", isOn: $exporter.enabled)
                Button("Send Current Summary") { exporter.sendCurrentSummary() }.disabled(!exporter.enabled)
                Link("Get Home Page on the Mac App Store", destination: HomePageExport.downloadURL)
                Text("Home Page is a separate Mac dashboard. Native Mac summaries are shared locally while both apps run. No shared folder is required. For Shortcuts, add Get Home Page Summary and connect it in Home Page. On iOS-on-Mac and Catalyst, use Shortcuts or Send Current Summary.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shares status and counts only, with other local apps able to receive the Mac summary. No notes, histories, credentials, or media. Summaries become stale after 15 minutes. Disable sharing to stop future updates.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = exporter.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct GetHomePageSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Home Page Summary"
    static let description = IntentDescription("Returns the latest optional status summary as JSON. Enable Share with Home Page in this app first. The summary includes its original update time and expiry.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard UserDefaults.standard.bool(forKey: "homePageExport.enabled.v1"),
              let data = try? Data(contentsOf: HomePageExport.summaryURL), data.count <= 32768,
              let text = String(data: data, encoding: .utf8) else { throw HomePageSummaryUnavailable() }
        return .result(value: text)
    }
}
private struct HomePageSummaryUnavailable: LocalizedError {
    var errorDescription: String? { "Enable Share with Home Page and open the source app to prepare a current summary." }
}

private struct HomePageExportModifier: ViewModifier {
    var summary: @MainActor () -> HomePageExportContent
    func body(content: Content) -> some View {
        content.onAppear { HomePageExport.shared.update(summary()) }
            .onChange(of: summary()) { _, value in HomePageExport.shared.update(value) }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    HomePageExport.shared.update(summary())
                }
            }
    }
}
extension View {
    func homePageExport(_ summary: @autoclosure @escaping @MainActor () -> HomePageExportContent) -> some View { modifier(HomePageExportModifier(summary: summary)).connectedApps() }
}

#if os(macOS)
import BackupCore
#endif
extension AppModel {
    var homePageSummary: HomePageExportContent {
        let failed = jobs.filter { $0.state == .failed }.count
        let active = jobs.filter { [.queued, .transferring, .verifying, .paused].contains($0.state) }.count
        var alerts: [HomePageExportItem] = failed == 0 ? [] : [
            .init(id: "transfers", revision: String(failed), priority: "critical", title: "\(failed) transfers need attention", actionID: "transfers")]
        var summary = "\(active) active transfers · \(failed) failed"
        if let unprotected = homePageBackupWarnings {
            summary += " · \(unprotected) backup jobs need review"
            if unprotected > 0 { alerts.append(.init(id: "backup", revision: String(unprotected), priority: "critical", title: "\(unprotected) backup jobs need review", actionID: "backups")) }
        } else { summary += " · backup status unavailable" }

        return .init(sourceID: "files-backups", summary: summary, state: alerts.isEmpty ? "normal" : "attention", items: alerts)
    }
}


#if os(macOS)
extension AppModel {
    func refreshHomePageBackupSummary() async {
        guard HomePageExport.shared.enabled, appSupport.standardizedFileURL == Self.sharedSupportDirectory().standardizedFileURL else { return }
        homePageBackupWarnings = await Task.detached(priority: .utility) { () -> Int? in
            guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
            let paths = AgentPaths(home: URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/FilesBackups"))
            guard let config = try? paths.loadConfiguration() else { return nil }
            let statuses = StatusStore(paths: paths).loadAll()
            return config.jobs.filter { job in
                guard let status = statuses.first(where: { $0.jobID == job.id }) else { return true }
                if case .current = status.protection { return [.failed, .blocked, .interrupted].contains(status.normalized(now: .now).state) }
                return true
            }.count
        }.value
    }
}
#endif
