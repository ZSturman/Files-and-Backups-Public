// Connected Apps protocol 1. Keep vendored copies byte-identical. No private database access.
import Foundation
import CryptoKit
import Darwin

public struct ConnectedApp: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let scheme: String
    public init(_ id: String, _ name: String, _ scheme: String) {
        self.id = id; self.name = name; self.scheme = scheme
    }
    public static let catalog: [Self] = [
        .init("home-page", "Home Page", "homepage"),
        .init("better-workspace", "Better Workspace", "betterworkspace"),
        .init("better-signals", "Better Signals", "bettersignals"),
        .init("recallable", "Recallable", "recallable"),
        .init("trackables", "Trackables", "trackables"),
        .init("content-manager", "Content Manager", "contentmanager"),
        .init("casino-exit", "Casino Exit", "casinoexit"),
        .init("camera-monitor", "Camera Monitor", "cameramonitor"),
        .init("files-backups", "Files & Backups", "filesbackups"),
        .init("inbox-review", "Inbox Review", "inboxreview")
    ]
    public static func named(_ id: String) -> Self? { catalog.first { $0.id == id } }
}

public struct ConnectionCapability: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let operation: String
    public init(_ id: String, _ title: String, operation: String) {
        self.id = id; self.title = title; self.operation = operation
    }
    public static let manifest = Self("capabilities.read.v1", "Discover available controls", operation: "read")
    public static let workspaceTasks = Self("workspace.tasks.read.v1", "Read tasks, due dates and project names", operation: "read")
    public static let workspaceUpdate = Self("workspace.tasks.update.v1", "Change task status", operation: "update")
    public static let recallStudy = Self("recall.study.read.v1", "Read study cards and review progress", operation: "read")
    public static let recallRate = Self("recall.review.create.v1", "Record card reviews", operation: "create")
    public static let summary = Self("summary.read.v1", "Read status and counts", operation: "read")
    public static let signalCatalog = Self("signals.catalog.read.v1", "Read signal questions and rating labels", operation: "read")
    public static let signalHistory = Self("signals.history.read.v1", "Read the 50 most recent signal ratings", operation: "read")
    public static let createSignal = Self("signals.create.v1", "Record a signal", operation: "create")
}

public enum ConnectionFailure: String, Error, LocalizedError {
    case invalidMessage, incompatibleVersion, expired, denied, changedIdentity, unavailable, storage, staleSettings, conflict
    public var errorDescription: String? {
        switch self {
        case .conflict: "The source changed since this card was read. Reload before trying again."
        case .invalidMessage: "The connection message is invalid."
        case .incompatibleVersion: "These app versions cannot connect. Update the older app."
        case .expired: "This connection request has expired. Request access again."
        case .denied: "The source app has not granted this operation."
        case .changedIdentity: "This app's installation key changed. Disconnect and pair again."
        case .unavailable: "The source has no current data available. Open it and try again."
        case .storage: "Connection settings could not be saved. Existing settings were preserved."
        case .staleSettings: "Connection permissions changed in another app instance. Review the current settings and try again."
        }
    }
}

public struct ConnectionRequest: Codable, Equatable, Identifiable, Sendable {
    public var version = 1
    public let id: UUID
    public let requesterID: String
    public let providerID: String
    public let publicKey: Data
    public let capabilities: [String]
    public let expiresAt: Date
    public init(requesterID: String, providerID: String, publicKey: Data, capabilities: [String], now: Date = .now) {
        id = UUID(); self.requesterID = requesterID; self.providerID = providerID
        self.publicKey = publicKey; self.capabilities = capabilities; expiresAt = now.addingTimeInterval(600)
    }
    public func validate(providerID: String, supported: Set<String>, now: Date = .now) throws {
        guard version == 1 else { throw ConnectionFailure.incompatibleVersion }
        guard self.providerID == providerID, requesterID != providerID,
              ConnectedApp.named(requesterID) != nil, ConnectedApp.named(providerID) != nil,
              publicKey.count == 32, !capabilities.isEmpty, capabilities.count <= 32,
              Set(capabilities).count == capabilities.count, Set(capabilities).isSubset(of: supported)
        else { throw ConnectionFailure.invalidMessage }
        guard expiresAt > now, expiresAt <= now.addingTimeInterval(605) else { throw ConnectionFailure.expired }
    }
    /// Compare in both apps before approving. A URL scheme alone does not authenticate an app.
    public var verificationCode: String {
        SHA256.hash(data: publicKey + Data(id.uuidString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ConnectionGrant: Codable, Equatable, Sendable, Identifiable {
    public var id: String { peerID }
    public let peerID: String
    public let publicKey: Data
    public var capabilities: Set<String>
    public let approvedAt: Date
    public var verified: Bool
    public init(peerID: String, publicKey: Data, capabilities: Set<String>, verified: Bool = true, now: Date = .now) {
        self.peerID = peerID; self.publicKey = publicKey; self.capabilities = capabilities
        self.verified = verified; approvedAt = now
    }
    public func authorize(_ capability: String, supported: Set<String>, publicKey: Data) throws {
        guard self.publicKey == publicKey else { throw ConnectionFailure.changedIdentity }
        guard verified, capabilities.contains(capability), supported.contains(capability) else { throw ConnectionFailure.denied }
    }
    public var verificationCode: String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// All grants/inbox/outbox live in the owner app's private container. No shared writable store.
public struct ConnectionLedger: Codable, Equatable, Sendable {
    public var version = 1
    public var incoming: [ConnectionRequest] = []
    public var outgoing: [ConnectionRequest] = []
    public var granted: [ConnectionGrant] = []
    public var received: [ConnectionGrant] = []
    public init() {}
    public mutating func enqueue(_ request: ConnectionRequest, providerID: String, supported: Set<String>, now: Date = .now) throws {
        try request.validate(providerID: providerID, supported: supported, now: now)
        if let grant = granted.first(where: { $0.peerID == request.requesterID }), grant.publicKey != request.publicKey {
            throw ConnectionFailure.changedIdentity
        }
        // A retry by the same verified key replaces its obsolete pending code.
        // A different key cannot hide another identity's request or change a grant.
        incoming.removeAll { $0.expiresAt <= now || $0.id == request.id ||
            ($0.requesterID == request.requesterID && $0.publicKey == request.publicKey) }
        guard incoming.count < 20 else { throw ConnectionFailure.invalidMessage }
        // An untrusted request never overwrites an existing grant or extends its scope.
        incoming.append(request)
    }
    public mutating func approve(_ request: ConnectionRequest, selection: Set<String>, providerID: String,
                                 supported: Set<String>, now: Date = .now) throws {
        try request.validate(providerID: providerID, supported: supported, now: now)
        guard incoming.contains(request), selection.isSubset(of: Set(request.capabilities)),
              selection.isSubset(of: supported) else { throw ConnectionFailure.denied }
        if let old = granted.first(where: { $0.peerID == request.requesterID }), old.publicKey != request.publicKey {
            throw ConnectionFailure.changedIdentity
        }
        granted.removeAll { $0.peerID == request.requesterID }
        if !selection.isEmpty { granted.append(.init(peerID: request.requesterID, publicKey: request.publicKey, capabilities: selection, now: now)) }
        incoming.removeAll { $0.id == request.id }
    }
    /// Expired requests can never be approved or answered; drop them so they do not
    /// reopen the request sheet at every launch.
    public func removingExpiredRequests(now: Date = .now) -> Self {
        var next = self
        next.incoming.removeAll { $0.expiresAt <= now }
        next.outgoing.removeAll { $0.expiresAt <= now }
        return next
    }
    public func hasPendingIncoming(now: Date = .now) -> Bool { incoming.contains { $0.expiresAt > now } }
    public static func load(_ url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        guard data.count <= 262144 else { throw ConnectionFailure.storage }
        let ledger = try JSONDecoder().decode(Self.self, from: data)
        guard ledger.version == 1 else { throw ConnectionFailure.incompatibleVersion }
        return ledger
    }
    public func save(_ url: URL, replacing expected: Self? = nil) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 262144 else { throw ConnectionFailure.storage }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ConnectionFailure.storage }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ConnectionFailure.storage }
        defer { flock(descriptor, LOCK_UN) }
        if let expected, try Self.load(url) != expected { throw ConnectionFailure.staleSettings }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

public struct ConnectionMessage: Codable, Sendable {
    public var version = 1
    public let senderID: String
    public let recipientID: String
    public let publicKey: Data
    public let ciphertext: Data
    public init(senderID: String, recipientID: String, privateKey: Curve25519.KeyAgreement.PrivateKey,
                peerKey: Data, payload: ConnectionPayload) throws {
        self.senderID = senderID; self.recipientID = recipientID; publicKey = privateKey.publicKey.rawRepresentation
        let key = try Self.key(privateKey, peerKey, senderID, recipientID)
        ciphertext = try AES.GCM.seal(JSONEncoder().encode(payload), using: key).combined!
    }
    public func open(recipientID: String, privateKey: Curve25519.KeyAgreement.PrivateKey, pinnedKey: Data? = nil) throws -> ConnectionPayload {
        guard version == 1 else { throw ConnectionFailure.incompatibleVersion }
        guard self.recipientID == recipientID, senderID != recipientID,
              ConnectedApp.named(senderID) != nil, ciphertext.count <= 65536 else { throw ConnectionFailure.invalidMessage }
        if let pinnedKey, pinnedKey != publicKey { throw ConnectionFailure.changedIdentity }
        let key = try Self.key(privateKey, publicKey, senderID, recipientID)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let payload = try JSONDecoder().decode(ConnectionPayload.self, from: AES.GCM.open(box, using: key))
        guard payload.expiresAt > .now, payload.expiresAt <= Date().addingTimeInterval(605) else { throw ConnectionFailure.expired }
        return payload
    }
    private static func key(_ key: Curve25519.KeyAgreement.PrivateKey, _ peer: Data, _ sender: String, _ recipient: String) throws -> SymmetricKey {
        let secret = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("connected-apps.v1".utf8),
                                             sharedInfo: Data((sender + "|" + recipient).utf8), outputByteCount: 32)
    }
}

public struct ConnectionPayload: Codable, Sendable {
    public let id: UUID
    public let kind: String
    public let capability: String
    public let capabilities: Set<String>?
    public let data: Data?
    public let expiresAt: Date
    public init(id: UUID = UUID(), kind: String, capability: String = "summary.read.v1",
                capabilities: Set<String>? = nil, data: Data? = nil, now: Date = .now) {
        self.id = id; self.kind = kind; self.capability = capability
        self.capabilities = capabilities; self.data = data; expiresAt = now.addingTimeInterval(120)
    }
}

public enum ConnectionWire {
    public static func url<T: Encodable>(_ value: T, kind: String, destination: ConnectedApp) throws -> URL {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65536 else { throw ConnectionFailure.invalidMessage }
        var parts = URLComponents(); parts.scheme = destination.scheme; parts.host = "connected-apps"
        parts.queryItems = [.init(name: kind, value: data.base64EncodedString())]
        guard let url = parts.url else { throw ConnectionFailure.invalidMessage }; return url
    }
    public static func decode(_ url: URL, for app: ConnectedApp) throws -> (String, Data) {
        guard url.absoluteString.utf8.count <= 100000, url.scheme == app.scheme, url.host == "connected-apps",
              url.path.isEmpty, url.fragment == nil, url.user == nil, url.port == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, ["request", "message"].contains(items[0].name),
              let raw = items[0].value, let data = Data(base64Encoded: raw), data.count <= 65536
        else { throw ConnectionFailure.invalidMessage }
        return (items[0].name, data)
    }
}

/// Source-owned definitions keep the consumer's input cards compatible with catalog updates.
public struct ConnectedSignalMetric: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let question: String
    public let anchors: [String]
    public init(id: String, title: String, question: String, anchors: [String]) {
        self.id = id; self.title = title; self.question = question; self.anchors = anchors
    }
}
public struct ConnectedSignalInput: Codable, Sendable {
    public let metricID: String
    public let rating: Int
    public init(metricID: String, rating: Int) { self.metricID = metricID; self.rating = rating }
}
public struct ConnectedSignalObservation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let metricID: String
    public let rating: Int
    public init(id: UUID, timestamp: Date, metricID: String, rating: Int) {
        self.id = id; self.timestamp = timestamp; self.metricID = metricID; self.rating = rating
    }
}

public struct ConnectedCapabilityManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceID: String
    public let capabilities: [ConnectionCapability]
    public init(version: Int = 1, sourceID: String, capabilities: [ConnectionCapability]) {
        self.version = version
        self.sourceID = sourceID
        self.capabilities = capabilities
    }
}

public struct ConnectedWorkspaceTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let revision: String
    public let title: String
    public let status: String
    public let stage: String
    public let dueDate: Date?
    public let project: String?
    public init(id: String, revision: String, title: String, status: String, stage: String, dueDate: Date?, project: String?) {
        self.id = id
        self.revision = revision
        self.title = title
        self.status = status
        self.stage = stage
        self.dueDate = dueDate
        self.project = project
    }
}

public struct ConnectedWorkspaceQuery: Codable, Sendable {
    public let search: String
    public init(search: String) { self.search = search }
}
public struct ConnectedWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let tasks: [ConnectedWorkspaceTask]
    public let openCount: Int
    public let overdueCount: Int
    public let syncStatus: String
    public let query: String?
    public init(generatedAt: Date, tasks: [ConnectedWorkspaceTask], openCount: Int, overdueCount: Int, syncStatus: String, query: String? = nil) {
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.openCount = openCount
        self.overdueCount = overdueCount
        self.syncStatus = syncStatus
        self.query = query
    }
}

public struct ConnectedWorkspaceUpdate: Codable, Equatable, Sendable {
    public let taskID: String
    public let revision: String
    public let status: String
    public let query: String?
    public init(taskID: String, revision: String, status: String, query: String? = nil) {
        self.taskID = taskID
        self.revision = revision
        self.status = status
        self.query = query
    }
}

public struct ConnectedWorkspaceReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let task: ConnectedWorkspaceTask
    public init(requestID: UUID, task: ConnectedWorkspaceTask) {
        self.requestID = requestID
        self.task = task
    }
}

public struct ConnectedStudyCard: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: String
    public let question: String
    public let answer: String
    public let deck: String?
    public init(id: UUID, revision: String, question: String, answer: String, deck: String?) {
        self.id = id
        self.revision = revision
        self.question = question
        self.answer = answer
        self.deck = deck
    }
}

public struct ConnectedStudyDeck: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public init(id: UUID, title: String) { self.id = id; self.title = title }
}
public struct ConnectedStudyRequest: Codable, Sendable {
    public let deckID: UUID?
    public init(deckID: UUID? = nil) { self.deckID = deckID }
}
public struct ConnectedStudySnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let queuedCount: Int
    public let reviewedToday: Int
    public let card: ConnectedStudyCard?
    public let decks: [ConnectedStudyDeck]?
    public let deckID: UUID?
    public init(generatedAt: Date, queuedCount: Int, reviewedToday: Int, card: ConnectedStudyCard?, decks: [ConnectedStudyDeck]? = nil, deckID: UUID? = nil) {
        self.generatedAt = generatedAt; self.queuedCount = queuedCount; self.reviewedToday = reviewedToday
        self.card = card; self.decks = decks; self.deckID = deckID
    }
}
public struct ConnectedReviewInput: Codable, Equatable, Sendable {
    public let cardID: UUID
    public let revision: String
    public let outcome: String
    public let shownAt: Date
    public let deckID: UUID?
    public init(cardID: UUID, revision: String, outcome: String, shownAt: Date, deckID: UUID? = nil) {
        self.cardID = cardID; self.revision = revision; self.outcome = outcome; self.shownAt = shownAt; self.deckID = deckID
    }
}

public struct ConnectedReviewReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let cardID: UUID
    public let outcome: String
    public init(requestID: UUID, cardID: UUID, outcome: String) {
        self.requestID = requestID
        self.cardID = cardID
        self.outcome = outcome
    }
}
