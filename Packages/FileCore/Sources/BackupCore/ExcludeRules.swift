import Darwin
import Foundation

/// The job's exclusions, evaluated the way restic evaluates them during a
/// backup, so restore verification skips exactly what was never backed up.
///
/// Patterns follow restic's `--exclude` rules: split on `/`; a pattern that
/// does not start with `/` may match at any depth (as if prefixed by `**/`);
/// `**` spans any number of path components; other components use `fnmatch`.
/// A matching folder excludes everything below it. A folder marked by
/// `excludeIfPresent` or a valid CACHEDIR.TAG keeps only the folder and the
/// marker file itself, as restic does.
public struct ExcludeRules: Sendable {
    let patterns: [[String]]
    let excludeCaches: Bool
    let excludeIfPresent: [String]

    static let cacheTagSignature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    public init(patterns: [String], excludeCaches: Bool = false, excludeIfPresent: [String] = []) {
        self.patterns = patterns.compactMap(Self.parse)
        self.excludeCaches = excludeCaches
        self.excludeIfPresent = excludeIfPresent
    }

    public init(job: BackupJobConfiguration) {
        self.init(patterns: job.excludes, excludeCaches: job.excludeCaches, excludeIfPresent: job.excludeIfPresent)
    }

    static func parse(_ raw: String) -> [String]? {
        let pattern = raw.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
        var components = pattern.split(separator: "/").map(String.init)
        if !pattern.hasPrefix("/"), components.first != "**" { components.insert("**", at: 0) }
        return components
    }

    /// Reads an exclude file (one pattern per line, `#` comments), as
    /// `restic --exclude-file` does.
    public static func patterns(fromFile path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// True when `path` (absolute) matches an exclude pattern.
    public func matchesPattern(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return patterns.contains { Self.match($0[...], components[...]) }
    }

    /// True when the item at `url` was left out of the backup.
    public func excludes(_ url: URL, isDirectory: Bool) -> Bool {
        if matchesPattern(url.standardizedFileURL.path) { return true }
        guard let marker = marker(of: url.deletingLastPathComponent()) else { return false }
        return url.lastPathComponent != marker
    }

    /// The marker file that makes restic skip `directory`'s contents, if any.
    func marker(of directory: URL) -> String? {
        let manager = FileManager.default
        if let name = excludeIfPresent.first(where: { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
            return name
        }
        if excludeCaches, let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("CACHEDIR.TAG")) {
            defer { try? handle.close() }
            if (try? handle.read(upToCount: Self.cacheTagSignature.count)) == Self.cacheTagSignature { return "CACHEDIR.TAG" }
        }
        return nil
    }

    static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            let rest = pattern.dropFirst()
            return (path.startIndex...path.endIndex).contains { match(rest, path[$0...]) }
        }
        guard let first = path.first, fnmatch(head, first, 0) == 0 else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }
}
