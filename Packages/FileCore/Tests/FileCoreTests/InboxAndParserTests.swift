@testable import FileCore
import Foundation
import XCTest

final class InboxAndParserTests: XCTestCase {
    func testShareExtensionInboxRoundTripAndOrphanAgeProtection() throws {
        let temp = try TempDirectory()
        let staging = StagingArea(root: temp.url.appendingPathComponent("Staging"), volumeReserveBytes: 0)
        let file = try temp.file("in/photo.heic", Data("img".utf8))
        let jobID = UUID()
        let staged = try staging.stage(files: [file], jobID: jobID)
        let job = TransferJob(id: jobID, connectionID: UUID(), connectionName: "Mac", destination: .root,
                              rootFolderName: nil, directories: [], items: staged.items, verifyContents: true)

        // Fresh staged folder of an unknown job survives an age-limited sweep.
        staging.removeOrphans(keeping: [], olderThan: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.root.appendingPathComponent(jobID.uuidString).path))

        let inbox = TransferInbox(directory: temp.url.appendingPathComponent("Inbox"))
        try inbox.deposit(job)
        let collected = inbox.collect()
        XCTAssertEqual(collected.map(\.id), [jobID])
        XCTAssertEqual(collected.first?.items.first?.sha256, SHA256Stream.hex(of: Data("img".utf8)))
        XCTAssertTrue(inbox.collect().isEmpty, "collected jobs are removed")

        staging.removeOrphans(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.root.appendingPathComponent(jobID.uuidString).path))
    }

    func testWebDAVMultistatusParsing() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/Photos/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
            <D:quota-available-bytes>1000</D:quota-available-bytes><D:quota-used-bytes>24</D:quota-used-bytes></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>http://nas.local/dav/Photos/Caf%C3%A9%20%E2%98%95%EF%B8%8F.jpg</D:href><D:propstat><D:prop><D:resourcetype/>
            <D:getcontentlength>42</D:getcontentlength><D:getlastmodified>Tue, 20 Oct 2026 10:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            <D:propstat><D:prop><D:quota-used-bytes/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let entries = WebDAVMultistatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isCollection)
        XCTAssertEqual(entries[0].quotaAvailable, 1000)
        XCTAssertEqual(entries[1].path, "/dav/Photos/Café ☕️.jpg")
        XCTAssertEqual(entries[1].length, 42)
        XCTAssertNotNil(entries[1].modified)
        XCTAssertFalse(entries[1].isCollection)
    }
}
