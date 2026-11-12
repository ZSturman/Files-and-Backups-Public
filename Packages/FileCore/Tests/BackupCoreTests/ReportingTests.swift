@testable import BackupCore
import Foundation
import XCTest

final class ReportingStub: URLProtocol {
    nonisolated(unsafe) static var requests: [(String, String, [String: Any])] = []
    nonisolated(unsafe) static var failEverything = false
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = request.url!.path
        Self.lock.withLock { Self.requests.append((request.httpMethod ?? "", path, json)) }
        var status = 200
        var response: [String: Any] = [:]
        if Self.failEverything {
            status = 503
            response = ["error": ["code": "volume_unavailable", "message": "down"]]
        } else if path.hasSuffix("/backups/sources") {
            status = 201; response = ["id": "src_test"]
        } else if path.hasSuffix("/runs") {
            status = 201; response = ["id": "run_test", "state": "running"]
        } else {
            response = ["id": "run_test"]
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ReportingTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/restic") else { throw XCTSkip("restic missing") }
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("reporting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "hello".write(to: temp.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("repo"), withIntermediateDirectories: true)
        ReportingStub.requests = []
        ReportingStub.failEverything = false
    }

    override func tearDownWithError() throws { if let temp { try? FileManager.default.removeItem(at: temp) } }

    private func makeRunner() throws -> (BackupRunner, BackupJobConfiguration) {
        let paths = AgentPaths(home: temp.appendingPathComponent("home"))
        try paths.prepare()
        FileManager.default.createFile(atPath: paths.secretsDirectory.appendingPathComponent("p").path, contents: Data("pw-\(UUID())".utf8), attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: paths.secretsDirectory.appendingPathComponent("hs.token").path, contents: Data("hst_test".utf8), attributes: [.posixPermissions: 0o600])
        let job = BackupJobConfiguration(id: "rep", name: "Rep", sourcePath: temp.appendingPathComponent("src").path,
                                         destination: .localRepository(path: temp.appendingPathComponent("repo").path, volumeUUID: try VolumeIdentity.of(path: temp.path).uuid),
                                         password: .privateFile("p"))
        let config = AgentConfiguration(jobs: [job], reporting: ReportingConfiguration(baseURL: "https://host.example.net:8443", tokenFile: "hs.token", jobs: ["rep"]))
        try paths.saveConfiguration(config)
        let runner = BackupRunner(paths: paths, configuration: config)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ReportingStub.self]
        runner.reportingSession = URLSession(configuration: session)
        return (runner, job)
    }

    func testSuccessfulRunIsRegisteredStartedAndFinishedWithSnapshot() async throws {
        let (runner, job) = try makeRunner()
        try await runner.initializeRepository(job)
        let status = try await runner.run(job, reason: .scheduled)
        XCTAssertEqual(status.state, .succeeded)
        let calls = ReportingStub.requests.map { "\($0.0) \($0.1)" }
        XCTAssertEqual(calls, ["POST /api/v1/backups/sources", "POST /api/v1/backups/sources/src_test/runs", "POST /api/v1/backups/runs/run_test/finish"])
        let register = ReportingStub.requests[0].2
        XCTAssertEqual(register["repository"] as? String, "external:local/repo")
        XCTAssertEqual(register["tag"] as? String, "job-rep")
        let finish = ReportingStub.requests[2].2
        XCTAssertEqual(finish["state"] as? String, "succeeded")
        XCTAssertEqual(finish["snapshot_id"] as? String, status.snapshotID)
        XCTAssertNotNil((finish["summary"] as? [String: Any])?["total_files"])
        XCTAssertEqual(try runner.paths.loadConfiguration().reporting?.sourceIDs["rep"], "src_test", "source ID is remembered")
        let log = try String(contentsOf: runner.paths.logsDirectory.appendingPathComponent("agent.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("hst_test"), "token never logged")
    }

    func testReportingOutageNeverFailsTheBackup() async throws {
        ReportingStub.failEverything = true
        let (runner, job) = try makeRunner()
        try await runner.initializeRepository(job)
        let status = try await runner.run(job, reason: .scheduled)
        XCTAssertEqual(status.state, .succeeded)
        XCTAssertNotNil(status.snapshotID)
    }

    func testFailedRunIsReportedAsFailed() async throws {
        let (runner, original) = try makeRunner()
        var job = original
        job.sourcePath = temp.appendingPathComponent("missing").path
        runner.configuration.jobs = [job]
        do { _ = try await runner.run(job, reason: .scheduled); XCTFail("must fail") } catch {}
        let finish = try XCTUnwrap(ReportingStub.requests.last)
        XCTAssertTrue(finish.1.hasSuffix("/finish"))
        XCTAssertEqual(finish.2["state"] as? String, "failed")
        XCTAssertNotNil((finish.2["error"] as? [String: Any])?["message"])
    }
}
