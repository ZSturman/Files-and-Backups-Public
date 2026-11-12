import CryptoKit
import Foundation

/// Incremental SHA-256 for files too large to hold in memory.
public final class SHA256Stream: @unchecked Sendable {
    private var hasher = SHA256()

    public init() {}

    public func update(_ data: Data) {
        hasher.update(data: data)
    }

    public func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(ofFileAt url: URL, chunkSize: Int = 4 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let stream = SHA256Stream()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            stream.update(data)
        }
        return stream.finalizeHex()
    }
}
