import Foundation

/// A path relative to a connection's approved root (share root, folder root,
/// or provider root). It can never address anything above that root: every
/// component is validated, and `..`/`.` are rejected rather than resolved.
///
/// Server permissions remain the final boundary for generic shares; this type
/// only guarantees the app never asks for an escaping path.
public struct RemotePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let components: [String]

    public static let root = RemotePath(uncheckedComponents: [])

    private init(uncheckedComponents: [String]) {
        self.components = uncheckedComponents
    }

    /// Parses a slash-separated provider-relative path. Leading, trailing, and
    /// repeated slashes are tolerated; traversal and unsafe names are not.
    public init(_ string: String) throws {
        let parts = string.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        try self.init(components: parts)
    }

    public init(components: [String]) throws {
        for component in components {
            try RemotePath.validate(name: component)
        }
        self.components = components
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    /// Validates one file or folder name. Rejects names that could change the
    /// meaning of a path on any supported server (POSIX, SMB, or HTTP).
    public static func validate(name: String) throws {
        guard !name.isEmpty else { throw FileCoreError.invalidPath("Empty name") }
        guard name != ".", name != ".." else {
            throw FileCoreError.invalidPath("Relative path components are not allowed")
        }
        guard name.utf8.count <= 255 else { throw FileCoreError.invalidPath("Name is too long") }
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == "\\" {
                throw FileCoreError.invalidPath("Names cannot contain path separators")
            }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw FileCoreError.invalidPath("Names cannot contain control characters")
            }
        }
    }

    public var isRoot: Bool { components.isEmpty }
    public var name: String { components.last ?? "" }
    public var string: String { components.joined(separator: "/") }
    public var description: String { "/" + string }

    public var parent: RemotePath? {
        guard !components.isEmpty else { return nil }
        return RemotePath(uncheckedComponents: Array(components.dropLast()))
    }

    public func appending(_ name: String) throws -> RemotePath {
        try RemotePath.validate(name: name)
        return RemotePath(uncheckedComponents: components + [name])
    }

    public func appending(_ other: RemotePath) -> RemotePath {
        RemotePath(uncheckedComponents: components + other.components)
    }

    /// True when `self` is `other` or is contained by it.
    public func isWithin(_ other: RemotePath) -> Bool {
        components.count >= other.components.count
            && Array(components.prefix(other.components.count)) == other.components
    }

    /// Joins this provider-relative path onto a provider root path such as an
    /// SMB in-share folder. The root is configuration, validated the same way.
    public func joined(toRoot root: RemotePath) -> RemotePath {
        root.appending(self)
    }
}
