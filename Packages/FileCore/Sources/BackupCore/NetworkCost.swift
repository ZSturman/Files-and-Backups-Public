#if os(macOS)
import Foundation
import Network

/// Current network cost, so unattended backups do not run over a phone
/// hotspot or in Low Data Mode.
public enum NetworkCost {
    public struct Snapshot: Sendable {
        public var isExpensive: Bool
        public var isConstrained: Bool
        public var isSatisfied: Bool
        public var metered: Bool { isExpensive || isConstrained }
    }

    /// Reads the current path once (waits at most `timeout`).
    public static func current(timeout: TimeInterval = 3) -> Snapshot? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "BackupCore.NetworkCost")
        let semaphore = DispatchSemaphore(value: 0)
        let box = SnapshotBox()
        monitor.pathUpdateHandler = { path in
            box.set(Snapshot(isExpensive: path.isExpensive, isConstrained: path.isConstrained, isSatisfied: path.status == .satisfied))
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return box.get()
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private var value: NetworkCost.Snapshot?
    private let lock = NSLock()
    func set(_ snapshot: NetworkCost.Snapshot) { lock.withLock { if value == nil { value = snapshot } } }
    func get() -> NetworkCost.Snapshot? { lock.withLock { value } }
}
#endif
