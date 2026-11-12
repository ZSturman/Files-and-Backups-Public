@testable import BackupCore
import Foundation
import XCTest

final class ExcludeRulesTests: XCTestCase {
    func testPatternsFollowResticRules() {
        let rules = ExcludeRules(patterns: ["**/node_modules", "venv", "**/Build/Products", "**/*.pyc", "/Users/me/Workspace/Temporary", "# comment", ""])
        XCTAssertTrue(rules.matchesPattern("/Users/me/Workspace/Projects/app/node_modules"))
        XCTAssertTrue(rules.matchesPattern("/Users/me/Workspace/Projects/app/venv"), "a bare name matches at any depth")
        XCTAssertTrue(rules.matchesPattern("/Users/me/Workspace/Projects/x/build/DerivedData-mac/Build/Products"))
        XCTAssertFalse(rules.matchesPattern("/Users/me/Workspace/Projects/x/build/DerivedData-mac/Build"))
        XCTAssertTrue(rules.matchesPattern("/a/b/c.pyc"))
        XCTAssertFalse(rules.matchesPattern("/a/b/c.py"))
        XCTAssertTrue(rules.matchesPattern("/Users/me/Workspace/Temporary"))
        XCTAssertFalse(rules.matchesPattern("/Users/me/Workspace/Projects/Temporary"), "an absolute pattern is anchored")
        XCTAssertFalse(rules.matchesPattern("/Users/me/Workspace/Projects/app/node_modules_notes.md"))
    }

    func testExclusionFlagsReachResticArgv() {
        var job = BackupJobConfiguration(id: "w", name: "W", sourcePath: "/src", destination: .localRepository(path: "/r", volumeUUID: "u"), password: .privateFile("p"))
        job.excludeCaches = true
        job.excludeIfPresent = [".nobackup"]
        let args = ResticCommand.backup(job, host: "h")
        XCTAssertTrue(args.contains("--exclude-caches"))
        XCTAssertEqual(args.firstIndex(of: "--exclude-if-present").map { args[$0 + 1] }, ".nobackup")
        XCTAssertEqual(Array(args.suffix(2)), ["--", "/src"])
    }

    func testOlderConfigurationsDecodeWithoutExclusionFlags() throws {
        let json = #"{"id":"x","name":"X","sourcePath":"/s","destination":{"localRepository":{"path":"/r","volumeUUID":"u"}},"password":{"privateFile":{"_0":"p"}},"excludes":["a"]}"#
        let job = try JSONDecoder().decode(BackupJobConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(job.excludeCaches)
        XCTAssertEqual(job.excludeIfPresent, [])
    }

    func testExcludeFileParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("excl-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# header\n**/node_modules\n\n  **/.venv  \n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ExcludeRules.patterns(fromFile: url.path), ["**/node_modules", "**/.venv"])
    }
}
