// Connected Apps UI/runtime 1. Vendored with ConnectedAppsCore.swift; no sibling runtime dependency.
import Foundation
import Combine
import CryptoKit
import Security
import SwiftUI
#if canImport(ConnectedAppsCore)
import ConnectedAppsCore
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor public final class ConnectedApps: ObservableObject {
    public static let shared = ConnectedApps()
    @Published public private(set) var ledger = ConnectionLedger()
    @Published public var status: String?
    @Published public var showRequests = false
    @Published public private(set) var latestResults: [String: Data] = [:]
    @Published public private(set) var resultCapabilities: [String: String] = [:]
    @Published public private(set) var resultIDs: [String: UUID] = [:]
    public var onSummary: ((String, Data) -> Void)?
    public var onConnected: ((String) -> Void)?
    public var onDisconnected: ((String) -> Void)?
    public var onFailure: ((String, String) -> Void)?
    private var handlers: [String: (UUID, Data?) throws -> Data] = [:]
    private var asyncHandlers: [String: (UUID, Data?) async throws -> Data] = [:]
    private var descriptors: [String: ConnectionCapability] = [:]
    private var activeCalls = Set<UUID>()
    public var onResult: ((String, String, UUID, Data) -> Void)?
    @Published public private(set) var manifests: [String: ConnectedCapabilityManifest] = [:]
    @Published public private(set) var failures: [String: String] = [:]
    private var refreshTasks: [String: Date] = [:]
    private var retiredReads: [UUID: (String, String, Date, String)] = [:]
    private var summaries: Data?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var blocked = false
    private var observer: NSObjectProtocol?
    private var seen: [UUID: Date] = [:]
    private var pendingCalls: [UUID: (String, String, Date, String)] = [:]
    // Isolated runtime fixtures inject transport and keys; production never uses these hooks.
    var testURLSender: ((URL) -> Void)?
    var testBroadcastSender: ((Data) -> Void)?
    func testReceiveBroadcast(_ data: Data) { receive(data, background: true) }
    private var isRuntimeFixture = false
    private static let channel = "com.zacharysturman.connected-apps.message.v1"
    public let app: ConnectedApp
    private let file: URL
    private let isolated: Bool
    public var capabilities: [ConnectionCapability] {
        var result: [ConnectionCapability] = app.id == "home-page" ? [] : [.summary, .manifest]
        result += descriptors.values.sorted { $0.id < $1.id }
        return result
    }
    public var supported: Set<String> { Set(capabilities.map(\.id)) }
    public var identityCode: String {
        guard let privateKey else { return "Unavailable" }
        return ConnectionGrant(peerID: app.id, publicKey: privateKey.publicKey.rawRepresentation, capabilities: []).verificationCode
    }
    private init() {
        let bundle = (Bundle.main.bundleIdentifier ?? "").lowercased()
        let id: String
        if bundle.contains("homepage") { id = "home-page" }
        else if bundle.contains("betterworkspace") { id = "better-workspace" }
        else if bundle.contains("checkin2") || bundle.contains("bettersignals") { id = "better-signals" }
        else if bundle.contains("recallable") { id = "recallable" }
        else if bundle.contains("habittap") || bundle.contains("trackables") { id = "trackables" }
        else if bundle.contains("contentmanager") { id = "content-manager" }
        else if bundle.contains("casinoexit") { id = "casino-exit" }
        else if bundle.contains("cameramonitor") { id = "camera-monitor" }
        else if bundle.contains("filesbackups") { id = "files-backups" }
        else if bundle.contains("inboxreview") { id = "inbox-review" }
        else { id = "unknown" }
        app = ConnectedApp.named(id) ?? .init(id, "Unsupported application", "unsupported")
        let process = ProcessInfo.processInfo
        isolated = id == "unknown" || NSClassFromString("XCTestCase") != nil
            || process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains { arg in ["uitest", "fixture", "acceptance", "isolated", "--state-directory", "--bridge-test-id"].contains { arg.lowercased().contains($0) } }
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConnectedApps/" + id + "/permissions-v1.json")
        guard !isolated else { return }
        do { ledger = try ConnectionLedger.load(file) }
        catch { blocked = true; status = "Could not open connection permissions. Original settings were preserved." }
        // Defer Keychain creation until an explicit pairing action.
        #if os(macOS)
        observer = DistributedNotificationCenter.default().addObserver(forName: .init(Self.channel), object: nil, queue: .main) { [weak self] note in
            guard let raw = note.object as? String, raw.utf8.count <= 100000, let data = Data(base64Encoded: raw) else { return }
            Task { @MainActor in self?.receive(data, background: true) }
        }
        #endif
    }
    init(testingApp: ConnectedApp, file: URL, privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        app = testingApp; self.file = file; self.privateKey = privateKey
        isolated = false; isRuntimeFixture = true
        ledger = try ConnectionLedger.load(file)
    }
    private func key(createIfMissing: Bool = true) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let privateKey { return privateKey }
        guard !isolated, !blocked else { throw ConnectionFailure.storage }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zacharysturman.connected-apps.v1",
            kSecAttrAccount as String: app.id]
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(read as CFDictionary, &value)
        if result == errSecSuccess, let data = value as? Data {
            let loaded = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data); privateKey = loaded; return loaded
        }
        guard result == errSecItemNotFound else { throw ConnectionFailure.storage }
        guard createIfMissing else { throw ConnectionFailure.denied }
        // Missing keys never silently reset existing pairings.
        guard ledger.granted.isEmpty, ledger.received.isEmpty, ledger.outgoing.isEmpty else { throw ConnectionFailure.changedIdentity }
        let created = Curve25519.KeyAgreement.PrivateKey()
        var write = query; write[kSecValueData as String] = created.rawRepresentation
        write[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(write as CFDictionary, nil) == errSecSuccess else { throw ConnectionFailure.storage }
        privateKey = created; return created
    }
    @discardableResult private func commit(_ next: ConnectionLedger) -> Bool {
        guard !blocked, !isolated else { status = ConnectionFailure.storage.localizedDescription; return false }
        do { try next.save(file, replacing: ledger); ledger = next; return true }
        catch {
            if let current = try? ConnectionLedger.load(file) { ledger = current }
            else { blocked = true }
            status = error.localizedDescription; return false
        }
    }
    private func synchronizePermissions() throws {
        guard !blocked, !isolated else { throw ConnectionFailure.storage }
        let current = try ConnectionLedger.load(file)
        if current != ledger { ledger = current }
    }
    public func register(_ capability: String, handler: @escaping (UUID, Data?) throws -> Data) {
        let known: [ConnectionCapability] = [.signalCatalog, .signalHistory, .createSignal]
        guard let descriptor = known.first(where: { $0.id == capability }) else { return }
        register(descriptor, handler: handler)
    }
    public func register(_ capability: ConnectionCapability, handler: @escaping (UUID, Data?) throws -> Data) {
        descriptors[capability.id] = capability; handlers[capability.id] = handler
    }
    public func registerAsync(_ capability: ConnectionCapability, handler: @escaping (UUID, Data?) async throws -> Data) {
        descriptors[capability.id] = capability; asyncHandlers[capability.id] = handler
    }
    /// Metadata uses an existing summary grant; it never grants data or mutation access.
    public func discover(_ grant: ConnectionGrant) { call(grant, capability: "capabilities.read.v1", body: nil) }
    private func authorize(_ grant: ConnectionGrant, capability: String, supported: Set<String>, publicKey: Data) throws {
        if capability == "capabilities.read.v1", grant.capabilities.contains("summary.read.v1") {
            try grant.authorize("summary.read.v1", supported: supported, publicKey: publicKey)
        } else { try grant.authorize(capability, supported: supported, publicKey: publicKey) }
    }
    /// Only silent native transport is used for automatic reconciliation. No app is launched.
    public func reconcile(_ grant: ConnectionGrant, capabilities: [String], body: Data? = nil, now: Date = .now) {
        expirePending(now: now)
        for capability in capabilities where grant.capabilities.contains(capability) {
            let scope = callScope(peerID: grant.peerID, capability: capability, body: body)
            guard now.timeIntervalSince(refreshTasks[scope] ?? .distantPast) >= 60,
                  !pendingCalls.values.contains(where: { $0.3 == scope }) else { continue }
            refreshTasks[scope] = now
            call(grant, capability: capability, body: body, background: true)
        }
    }
    private func resolveReadScope(_ scope: String) {
        for (id, call) in pendingCalls where call.3 == scope && call.1.hasSuffix(".read.v1") {
            retiredReads[id] = call
            pendingCalls[id] = nil
        }
    }
    private func callScope(peerID: String, capability: String, body: Data?) -> String {
        peerID + ":" + capability + ":" + SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public func expirePending(now: Date = .now) {
        retiredReads = retiredReads.filter { $0.value.2 > now }
        for (id, call) in pendingCalls where call.2 <= now {
            pendingCalls[id] = nil
            let text = call.1.hasSuffix(".read.v1")
                ? "No response from the source. Showing last received data; read again when it is available."
                : "No save receipt from the source. The outcome is unknown; reload or retry the same action."
            failures[call.0] = text; onFailure?(call.0, text)
        }
    }
    public func showIdentity() {
        do { _ = try key(); status = "App verification code: \(identityCode)" }
        catch { status = error.localizedDescription }
    }
    public func request(_ peer: ConnectedApp, capabilities: [String] = ["summary.read.v1"]) {
        do {
            let key = try key()
            let request = ConnectionRequest(requesterID: app.id, providerID: peer.id,
                publicKey: key.publicKey.rawRepresentation, capabilities: capabilities)
            var next = ledger
            next.outgoing.removeAll { $0.providerID == peer.id || $0.expiresAt <= .now }
            next.outgoing.append(request)
            guard commit(next) else { return }
            status = "Compare request code \(request.verificationCode) in \(peer.name) before allowing access."
            open(try ConnectionWire.url(request, kind: "request", destination: peer))
        } catch { status = error.localizedDescription }
    }
    @discardableResult public func handle(_ url: URL) -> Bool {
        guard url.host == "connected-apps" else { return false }
        do {
            let (kind, data) = try ConnectionWire.decode(url, for: app)
            guard !isolated, !blocked else { throw ConnectionFailure.storage }
            if kind == "request" {
                let request = try JSONDecoder().decode(ConnectionRequest.self, from: data)
                var next = ledger
                try next.enqueue(request, providerID: app.id, supported: supported)
                if commit(next) { showRequests = true }
            } else { receive(data, background: false) }
        } catch { status = error.localizedDescription }
        return true
    }
    public func approve(_ request: ConnectionRequest, selection: Set<String>) {
        do {
            let key = try key()
            let reply = try ConnectionMessage(senderID: app.id, recipientID: request.requesterID, privateKey: key,
                peerKey: request.publicKey, payload: .init(id: request.id, kind: "grant", capabilities: selection))
            var next = ledger
            try next.approve(request, selection: selection, providerID: app.id, supported: supported)
            guard commit(next), let peer = ConnectedApp.named(request.requesterID) else { return }
            status = "Source verification code: \(identityCode). Compare it in \(peer.name) to finish pairing."
            open(try ConnectionWire.url(reply, kind: "message", destination: peer))
        } catch { status = error.localizedDescription }
    }
    public func deny(_ request: ConnectionRequest) {
        var next = ledger; next.incoming.removeAll { $0.id == request.id }
        guard commit(next) else { return }
        status = request.expiresAt <= .now ? "Expired request removed." : "Request denied. Existing approved access is unchanged."
        guard request.expiresAt > .now, let peer = ConnectedApp.named(request.requesterID),
              let key = try? key(), let message = try? ConnectionMessage(senderID: app.id, recipientID: request.requesterID,
                privateKey: key, peerKey: request.publicKey, payload: .init(id: request.id, kind: "denied")),
              let url = try? ConnectionWire.url(message, kind: "message", destination: peer) else { return }
        open(url)
    }
    /// Clears requests that expired while the app was closed. Grants are untouched.
    public func removeExpiredRequests() {
        guard !isolated, !blocked else { return }
        let next = ledger.removingExpiredRequests()
        if next != ledger { commit(next) }
    }
    public func verify(_ grant: ConnectionGrant) {
        var next = ledger
        guard let index = next.received.firstIndex(where: { $0.peerID == grant.peerID && $0.publicKey == grant.publicKey }) else { return }
        next.received[index].verified = true
        if commit(next) { onConnected?(grant.peerID); status = "Connected. Choose Read now to get current data." }
    }
    public func revoke(_ grant: ConnectionGrant, incoming: Bool) {
        var next = ledger
        if incoming {
            next.granted.removeAll { $0.peerID == grant.peerID }
            next.incoming.removeAll { $0.requesterID == grant.peerID }
        } else {
            next.received.removeAll { $0.peerID == grant.peerID }
            next.outgoing.removeAll { $0.providerID == grant.peerID }
        }
        guard commit(next) else { return }
        if !incoming {
            latestResults[grant.peerID] = nil; resultIDs[grant.peerID] = nil; resultCapabilities[grant.peerID] = nil
            onDisconnected?(grant.peerID)
        }
        // Local revocation succeeds even when Keychain or the peer is unavailable.
        if let key = try? key(createIfMissing: false),
           let message = try? ConnectionMessage(senderID: app.id, recipientID: grant.peerID,
                privateKey: key, peerKey: grant.publicKey, payload: .init(kind: "revoke")) { broadcast(message) }
        status = incoming ? "Access revoked. Future requests are denied." : "Disconnected. Future messages will be ignored."
    }
    public func read(_ grant: ConnectionGrant) { call(grant, capability: "summary.read.v1", body: nil) }
    public func call(_ grant: ConnectionGrant, capability: String, body: Data?, requestID: UUID = UUID(), background: Bool = false) {
        do {
            try authorize(grant, capability: capability, supported: grant.capabilities, publicKey: grant.publicKey)
            guard let peer = ConnectedApp.named(grant.peerID) else { throw ConnectionFailure.invalidMessage }
            let payload = ConnectionPayload(id: requestID, kind: "call", capability: capability, data: body)
            let message = try ConnectionMessage(senderID: app.id, recipientID: peer.id, privateKey: key(), peerKey: grant.publicKey, payload: payload)
            pendingCalls = pendingCalls.filter { $0.value.2 > .now }
            pendingCalls[payload.id] = (peer.id, capability, payload.expiresAt, callScope(peerID: peer.id, capability: capability, body: body))
            failures[peer.id] = nil
            if background { broadcast(message) }
            else { open(try ConnectionWire.url(message, kind: "message", destination: peer)) }
        } catch { failures[grant.peerID] = error.localizedDescription; status = error.localizedDescription; onFailure?(grant.peerID, error.localizedDescription) }
    }
    /// Called by the source's existing summary builder, independently of legacy broadcast opt-in.
    public func publish(_ data: Data) {
        guard data.count <= 32768, !isolated, !blocked else { return }
        summaries = data
        do { try synchronizePermissions() } catch { status = error.localizedDescription; return }
        for grant in ledger.granted where grant.capabilities.contains("summary.read.v1") {
            do {
                let message = try ConnectionMessage(senderID: app.id, recipientID: grant.peerID, privateKey: key(),
                    peerKey: grant.publicKey, payload: .init(kind: "summary", data: data))
                broadcast(message)
            } catch { status = error.localizedDescription }
        }
    }
    public func publishSummary(_ summary: String, generatedAt: Date, state: String = "normal") {
        let formatter = ISO8601DateFormatter()
        let value: [String: Any] = ["schemaVersion": 1, "sourceID": app.id, "summary": summary,
            "generatedAt": formatter.string(from: generatedAt),
            "expiresAt": formatter.string(from: generatedAt.addingTimeInterval(900)), "state": state, "items": []]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { publish(data) }
    }
    /// A source may push only explicitly granted read results, never a write receipt.
    public func publishRead(_ capability: String, data: Data) {
        guard capability.hasSuffix(".read.v1"), data.count <= 32768, !isolated, !blocked else { return }
        do {
            try synchronizePermissions()
            for grant in ledger.granted where grant.capabilities.contains(capability) {
                let message = try ConnectionMessage(senderID: app.id, recipientID: grant.peerID, privateKey: key(), peerKey: grant.publicKey,
                    payload: .init(kind: "update", capability: capability, data: data))
                broadcast(message)
            }
        } catch { status = error.localizedDescription }
    }
    private func receive(_ data: Data, background: Bool) {
        do {
            guard !isolated, !blocked, data.count <= 65536 else { return }
            try synchronizePermissions()
            let message = try JSONDecoder().decode(ConnectionMessage.self, from: data)
            guard message.recipientID == app.id else { return }
            let incoming = ledger.granted.first { $0.peerID == message.senderID }
            let outgoing = ledger.received.first { $0.peerID == message.senderID }
            if background, incoming == nil, outgoing == nil { return }
            let payload = try message.open(recipientID: app.id, privateKey: key(createIfMissing: false), pinnedKey: incoming?.publicKey ?? outgoing?.publicKey)
            seen = seen.filter { $0.value > .now }
            let pending = pendingCalls[payload.id]
            let expectedReply = ["summary", "error"].contains(payload.kind) && pending?.0 == message.senderID
                && pending?.1 == payload.capability && (pending?.2 ?? .distantPast) > .now
            guard seen[payload.id] == nil || payload.kind == "call" || expectedReply else { throw ConnectionFailure.expired }
            switch payload.kind {
            case "denied":
                guard !background, ledger.outgoing.contains(where: { $0.id == payload.id && $0.providerID == message.senderID }) else { throw ConnectionFailure.denied }
                var next = ledger; next.outgoing.removeAll { $0.id == payload.id }
                if commit(next) { status = "The source denied this request. Existing approved access is unchanged." }
            case "grant":
                guard !background, let request = ledger.outgoing.first(where: { $0.id == payload.id && $0.providerID == message.senderID }),
                      request.expiresAt > .now, let selection = payload.capabilities,
                      selection.isSubset(of: Set(request.capabilities)) else { throw ConnectionFailure.denied }
                if let outgoing, outgoing.publicKey != message.publicKey { throw ConnectionFailure.changedIdentity }
                var next = ledger
                next.outgoing.removeAll { $0.id == payload.id }
                next.received.removeAll { $0.peerID == message.senderID }
                if !selection.isEmpty { next.received.append(.init(peerID: message.senderID, publicKey: message.publicKey, capabilities: selection, verified: false)) }
                if commit(next) { status = selection.isEmpty ? "The source denied access." : "Verify the source code in Connected Apps to finish pairing." }
            case "call":
                if activeCalls.contains(payload.id) { return }
                if let handler = asyncHandlers[payload.capability] {
                    guard let incoming else { throw ConnectionFailure.denied }
                    try authorize(incoming, capability: payload.capability, supported: supported, publicKey: message.publicKey)
                    activeCalls.insert(payload.id)
                    Task { @MainActor in
                        let response: ConnectionPayload
                        do {
                            let result = try await handler(payload.id, payload.data)
                            guard result.count <= 32768 else { throw ConnectionFailure.invalidMessage }
                            response = .init(id: payload.id, kind: "summary", capability: payload.capability, data: result)
                        } catch {
                            response = .init(id: payload.id, kind: "error", capability: payload.capability, data: Data(error.localizedDescription.prefix(500).utf8))
                        }
                        self.activeCalls.remove(payload.id)
                        self.reply(response, to: message, background: background)
                    }
                    return
                }
                seen[payload.id] = payload.expiresAt
                let response: ConnectionPayload
                do {
                    guard let incoming else { throw ConnectionFailure.denied }
                    try authorize(incoming, capability: payload.capability, supported: supported, publicKey: message.publicKey)
                    let result: Data
                    if payload.capability == "summary.read.v1" {
                        guard let summaries else { throw ConnectionFailure.unavailable }; result = summaries
                    } else if payload.capability == "capabilities.read.v1" {
                        result = try JSONEncoder().encode(ConnectedCapabilityManifest(sourceID: app.id, capabilities: capabilities))
                    } else if let handler = handlers[payload.capability] { result = try handler(payload.id, payload.data) }
                    else { throw ConnectionFailure.denied }
                    guard result.count <= 32768 else { throw ConnectionFailure.invalidMessage }
                    response = .init(id: payload.id, kind: "summary", capability: payload.capability, data: result)
                } catch {
                    response = .init(id: payload.id, kind: "error", capability: payload.capability, data: Data(error.localizedDescription.prefix(500).utf8))
                }
                reply(response, to: message, background: background)
            case "summary", "update":
                guard let outgoing, let result = payload.data, result.count <= 32768 else { throw ConnectionFailure.denied }
                try authorize(outgoing, capability: payload.capability, supported: outgoing.capabilities, publicKey: message.publicKey)
                if let retired = retiredReads[payload.id], retired.0 == message.senderID,
                   retired.1 == payload.capability, retired.2 > .now { return }
                if payload.kind == "update" {
                    guard payload.capability.hasSuffix(".read.v1") else { throw ConnectionFailure.denied }
                    // Unparameterized source pushes satisfy only the default read scope.
                    resolveReadScope(callScope(peerID: message.senderID, capability: payload.capability, body: nil))
                } else if payload.capability != "summary.read.v1" {
                    guard let pending = pendingCalls.removeValue(forKey: payload.id), pending.0 == message.senderID,
                          pending.1 == payload.capability, pending.2 > .now else { throw ConnectionFailure.denied }
                    if payload.capability.hasSuffix(".read.v1") { resolveReadScope(pending.3) }
                } else {
                    resolveReadScope(callScope(peerID: message.senderID, capability: payload.capability, body: nil))
                }
                if payload.capability == "capabilities.read.v1" {
                    let manifest = try JSONDecoder().decode(ConnectedCapabilityManifest.self, from: result)
                    guard manifest.version == 1, manifest.sourceID == message.senderID, manifest.capabilities.count <= 32,
                          Set(manifest.capabilities.map(\.id)).count == manifest.capabilities.count,
                          manifest.capabilities.allSatisfy({ $0.id.count <= 200 && $0.title.count <= 200 && ["read", "create", "update", "delete"].contains($0.operation) }) else { throw ConnectionFailure.invalidMessage }
                    manifests[message.senderID] = manifest
                }
                failures[message.senderID] = nil
                onResult?(message.senderID, payload.capability, payload.id, result)
                if payload.capability == "summary.read.v1", let call = pendingCalls[payload.id], call.0 == message.senderID && call.1 == payload.capability {
                    pendingCalls[payload.id] = nil
                }
                resultCapabilities[message.senderID] = payload.capability
                resultIDs[message.senderID] = payload.id
                latestResults[message.senderID] = result
                if payload.capability == "summary.read.v1" { onSummary?(message.senderID, result) }
                status = "Received data from \(ConnectedApp.named(message.senderID)?.name ?? message.senderID)."
            case "error":
                guard outgoing != nil, let pending = pendingCalls.removeValue(forKey: payload.id),
                      pending.0 == message.senderID, pending.1 == payload.capability, pending.2 > .now,
                      let data = payload.data, data.count <= 2000 else { throw ConnectionFailure.denied }
                status = String(decoding: data, as: UTF8.self)
                failures[message.senderID] = status
                onFailure?(message.senderID, status ?? "Source request failed.")
            case "revoke":
                guard incoming != nil || outgoing != nil else { return }
                var next = ledger
                next.granted.removeAll { $0.peerID == message.senderID }
                next.received.removeAll { $0.peerID == message.senderID }
                if commit(next) { latestResults[message.senderID] = nil; onDisconnected?(message.senderID); status = "The other app disconnected." }
            default: throw ConnectionFailure.invalidMessage
            }
            seen[payload.id] = payload.expiresAt
        } catch { if !background { status = error.localizedDescription } }
    }
    private func reply(_ response: ConnectionPayload, to message: ConnectionMessage, background: Bool) {
        do {
            // Re-read permissions after an async handler: revocation must prevent disclosure.
            try synchronizePermissions()
            if response.kind != "error" {
                guard let grant = ledger.granted.first(where: { $0.peerID == message.senderID }) else { return }
                try authorize(grant, capability: response.capability, supported: supported, publicKey: message.publicKey)
            }
            let reply = try ConnectionMessage(senderID: app.id, recipientID: message.senderID, privateKey: key(), peerKey: message.publicKey, payload: response)
            if background { broadcast(reply) }
            else if let peer = ConnectedApp.named(message.senderID) { open(try ConnectionWire.url(reply, kind: "message", destination: peer)) }
        } catch { status = error.localizedDescription }
    }
    private func broadcast(_ message: ConnectionMessage) {
        if let testBroadcastSender, let data = try? JSONEncoder().encode(message) { testBroadcastSender(data); return }
        guard !isRuntimeFixture else { return }
        #if os(macOS)
        guard let data = try? JSONEncoder().encode(message), data.count <= 65536 else { return }
        DistributedNotificationCenter.default().postNotificationName(.init(Self.channel), object: data.base64EncodedString(), userInfo: nil, deliverImmediately: true)
        #endif
    }
    private func open(_ url: URL) {
        if let testURLSender { testURLSender(url); return }
        guard !isRuntimeFixture else { return }
        #if os(macOS)
        if !NSWorkspace.shared.open(url) { status = "Install and open the updated destination app, then try again." }
        #elseif os(iOS)
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { Task { @MainActor in self.status = "Install and open the updated destination app, then try again." } }
        }
        #endif
    }
}

public struct ConnectedAppsSettings: View {
    @ObservedObject private var connections = ConnectedApps.shared
    public init() {}
    public var body: some View {
        Section("Connected Apps") {
            if let status = connections.status { Text(status).font(.callout).textSelection(.enabled) }
            Text("App verification code: \(connections.identityCode)").font(.caption.monospaced()).textSelection(.enabled)
            if connections.identityCode == "Unavailable" {
                Button("Show app verification code") { connections.showIdentity() }
            }
            Text("Approve access in the app that owns the data. Compare verification codes in both apps. Disconnecting stops future access; data already copied to another app remains there.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(connections.ledger.incoming) { request in
                ConnectionRequestRow(request: request)
            }
            ForEach(connections.ledger.outgoing) { request in
                Text("Waiting for \(ConnectedApp.named(request.providerID)?.name ?? request.providerID) · code \(request.verificationCode)")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            ForEach(connections.ledger.granted) { grant in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(ConnectedApp.named(grant.peerID)?.name ?? grant.peerID) can access this app").font(.headline)
                    Text(grant.capabilities.sorted().joined(separator: ", ")).font(.caption)
                    Button("Revoke access", role: .destructive) { connections.revoke(grant, incoming: true) }
                }
            }
            ForEach(connections.ledger.received) { grant in
                VStack(alignment: .leading, spacing: 6) {
                    Text(ConnectedApp.named(grant.peerID)?.name ?? grant.peerID).font(.headline)
                    if !grant.verified {
                        Text("Compare source code \(grant.verificationCode) with the code shown in the source app's Connected Apps settings.")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Button("Codes match — finish connecting") { connections.verify(grant) }
                    } else {
                        Text(grant.capabilities.sorted().joined(separator: ", ")).font(.caption)
                        if grant.capabilities.contains("summary.read.v1") {
                            Button("Read now") { connections.read(grant) }
                            Button("Discover available controls") { connections.discover(grant) }
                        }
                        if let manifest = connections.manifests[grant.peerID], let peer = ConnectedApp.named(grant.peerID) {
                            ForEach(manifest.capabilities) { capability in
                                Text("\(capability.title) · \(grant.capabilities.contains(capability.id) ? "approved" : "needs approval")").font(.caption)
                            }
                            Button("Request discovered capabilities…") { connections.request(peer, capabilities: manifest.capabilities.map(\.id)) }
                        }
                        if connections.resultCapabilities[grant.peerID] == "summary.read.v1",
                           let data = connections.latestResults[grant.peerID],
                           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let summary = value["summary"] as? String {
                            Text(String(summary.prefix(500))).font(.callout)
                        }
                    }
                    Button("Disconnect", role: .destructive) { connections.revoke(grant, incoming: false) }
                }
            }
            DisclosureGroup("Connect another app") {
                ForEach(ConnectedApp.catalog.filter { $0.id != connections.app.id && $0.id != "home-page" }) { app in
                    Button("Request access to \(app.name)") { connections.request(app) }
                }
            }
            Text("Only implemented capabilities are offered. Read, create, update and delete permissions are separate; new capabilities always need a new approval. Opening a source app or Shortcut follows that app's own confirmation rules.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // A Form/List row must not implicitly invoke its approval/deny buttons
        // when the user taps another control in the same permission row.
        .buttonStyle(.borderless)
    }
}

private struct ConnectionRequestRow: View {
    let request: ConnectionRequest
    @ObservedObject private var connections = ConnectedApps.shared
    @State private var checkedCode = false
    @State private var selected = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(ConnectedApp.named(request.requesterID)?.name ?? request.requesterID) requests access").font(.headline)
            Text("Request code: \(request.verificationCode)").font(.caption.monospaced()).textSelection(.enabled)
            Toggle("I checked this code in the requesting app", isOn: $checkedCode)
            ForEach(request.capabilities, id: \.self) { id in
                Toggle(connections.capabilities.first { $0.id == id }?.title ?? id,
                    isOn: Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } }))
            }
            HStack {
                Button("Allow all requested") { connections.approve(request, selection: Set(request.capabilities)) }.disabled(!checkedCode || request.expiresAt <= .now)
                Button("Allow selected") { connections.approve(request, selection: selected) }.disabled(!checkedCode || selected.isEmpty || request.expiresAt <= .now)
                Button("Deny", role: .destructive) { connections.deny(request) }
            }
        }
    }
}

private struct ConnectedAppsModifier: ViewModifier {
    @ObservedObject private var connections = ConnectedApps.shared
    func body(content: Content) -> some View {
        content.onOpenURL { _ = connections.handle($0) }
            .sheet(isPresented: $connections.showRequests) {
                NavigationStack {
                    Form { ConnectedAppsSettings() }.formStyle(.grouped)
                        .navigationTitle("Connected Apps")
                        .toolbar { Button("Done") { connections.showRequests = false } }
                }.frame(minWidth: 340, minHeight: 440)
            }
            .onAppear {
                connections.removeExpiredRequests()
                if connections.ledger.hasPendingIncoming() { connections.showRequests = true }
            }
    }
}
public extension View {
    func connectedApps() -> some View { modifier(ConnectedAppsModifier()) }
}
