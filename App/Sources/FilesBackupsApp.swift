import FileCore
import SwiftUI

@main
struct FilesBackupsApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // UI tests run against isolated state with in-memory credentials.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-FBUITestState"), index + 1 < arguments.count {
            // Named test state that survives relaunch (interruption tests);
            // its Keychain items live under a separate test service.
            let name = arguments[index + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let support = FileManager.default.temporaryDirectory.appendingPathComponent("FilesBackupsUITest-\(name)")
            _model = State(initialValue: AppModel(appSupport: support, credentials: KeychainCredentialStore(service: "com.zacharysturman.filesbackups.uitest.\(name)")))
        } else if arguments.contains("-FBUITestIsolatedState") {
            let support = FileManager.default.temporaryDirectory.appendingPathComponent("FilesBackupsUITest-\(UUID().uuidString)")
            _model = State(initialValue: AppModel(appSupport: support, credentials: InMemoryCredentialStore()))
        } else {
            _model = State(initialValue: AppModel())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .homePageExport(model.homePageSummary)
                #if os(macOS)
                .task {
                    while !Task.isCancelled {
                        await model.refreshHomePageBackupSummary()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: model.didBecomeActive()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// `-FBInitialTab backups` opens a specific tab (screenshots, support).
    @State private var tab: String = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-FBInitialTab"), index + 1 < arguments.count else { return "files" }
        return arguments[index + 1]
    }()

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            FilesTab()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag("files")
            TransfersView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                .badge(model.jobs.filter { [.queued, .transferring, .verifying, .paused].contains($0.state) }.count)
                .tag("transfers")
            BackupsView()
                .tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }
                .tag("backups")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .onOpenURL { url in
            guard url.scheme == "filesbackups", let host = url.host, ["files", "transfers", "backups"].contains(host) else { return }
            tab = host
        }
        .alert("Files & Backups", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}
