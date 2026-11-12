import FileCore
import Foundation
import Network

/// Confirms a TCP connection can be opened before an SMB session is attempted,
/// so an unreachable host (asleep PC, wrong address, Tailscale down, Local
/// Network access denied) is reported as such rather than as a login failure.
enum TCPProbe {
    static func check(host: String, port: Int, timeout: TimeInterval) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw FileCoreError.invalidConfiguration("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "FileCoreSMB.TCPProbe")
        let gate = ResumeGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                @Sendable func finish(_ result: Result<Void, any Error>) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                    case .failed(let error):
                        finish(.failure(FileCoreError.unreachable("\(host):\(port) — \(error.localizedDescription)")))
                    case .waiting(let error):
                        // Waiting means no usable path: refused, no route, or
                        // Local Network permission denied on iOS.
                        finish(.failure(FileCoreError.unreachable("\(host):\(port) — \(error.localizedDescription). Check the address, that the computer is awake, and Local Network access in Settings")))
                    case .cancelled:
                        finish(.failure(FileCoreError.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(FileCoreError.unreachable("\(host):\(port) did not respond within \(Int(timeout)) seconds")))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
