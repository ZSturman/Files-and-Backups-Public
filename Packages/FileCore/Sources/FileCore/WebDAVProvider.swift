import Foundation

/// WebDAV (RFC 4918) over HTTPS with Basic authentication. Plain HTTP is
/// accepted only for loopback hosts, which the test fixtures use.
///
/// WebDAV has no standard partial write, so each file is uploaded whole to a
/// temp name with `If-None-Match: *`, verified, and published with
/// `MOVE` + `Overwrite: F`. An interrupted file restarts from zero.
public final class WebDAVProvider: StorageProvider, @unchecked Sendable {
    private let baseURL: URL
    private let root: RemotePath
    private let authorization: String
    private let session: URLSession
    private var reportsQuota = false
    private let lock = NSLock()

    public init(baseURL: URL, root: RemotePath = .root, username: String, password: String, session: URLSession? = nil) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host else {
            throw FileCoreError.invalidConfiguration("enter a full https:// URL")
        }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw FileCoreError.invalidConfiguration("WebDAV requires https:// (plain HTTP would expose the password)")
        }
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        self.baseURL = URL(string: base)!
        self.root = root
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        // URLSession owns the Authorization header; answer Basic/Digest
        // challenges through a delegate instead, and only for this host.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(
            configuration: configuration,
            delegate: WebDAVAuthDelegate(credential: URLCredential(user: username, password: password, persistence: .forSession), host: host),
            delegateQueue: nil
        )
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            browse: .supported, download: .supported, upload: .supported, createFolder: .supported,
            rename: .supported, permanentDelete: .supported,
            restorableTrash: .unsupported("WebDAV has no standard restorable Trash; deletes are permanent"),
            capacity: lock.withLock { reportsQuota } ? .supported : .unsupported("this server does not report quota"),
            resumableUpload: .unsupported("WebDAV has no standard partial upload; an interrupted file restarts"),
            bestVerification: .sha256Readback,
            backgroundTransfers: .unsupported("transfers run while the app is open"),
            versionedBackups: .unsupported("a WebDAV folder stores files; it is not a versioned backup service")
        )
    }

    // MARK: HTTP

    func url(for path: RemotePath, directory: Bool = false) -> URL {
        var url = baseURL
        let components = root.appending(path).components
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            url.appendPathComponent(component, isDirectory: !isLast || directory)
        }
        return url
    }

    private func request(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")  // preemptive; delegate answers challenges
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw FileCoreError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FileCoreError.protocolError("not an HTTP response") }
        try Self.checkCommon(http.statusCode)
        return (data, http)
    }

    static func checkCommon(_ status: Int) throws {
        switch status {
        case 401: throw FileCoreError.authenticationFailed
        case 403: throw FileCoreError.permissionDenied("the server refused this operation")
        case 507: throw FileCoreError.insufficientSpace
        case 500..<600 where status != 507: throw FileCoreError.protocolError("server returned \(status)")
        default: break
        }
    }

    private func propfind(_ path: RemotePath, depth: String) async throws -> [WebDAVEntry]? {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await request("PROPFIND", url(for: path, directory: depth == "1"), headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"], body: body)
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 207 else { throw FileCoreError.protocolError("PROPFIND returned \(response.statusCode)") }
        return WebDAVMultistatusParser.parse(data)
    }

    // MARK: StorageProvider

    public func connect() async throws {
        guard let entries = try await propfind(.root, depth: "0") else {
            throw FileCoreError.notFound(root)
        }
        guard entries.first?.isCollection == true else { throw FileCoreError.notADirectory(root) }
        lock.withLock { reportsQuota = entries.first?.quotaAvailable != nil }
    }

    public func disconnect() async {}

    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        guard let entries = try await propfind(directory, depth: "1") else { throw FileCoreError.notFound(directory) }
        let trim = { (path: String) in path.hasSuffix("/") ? String(path.dropLast()) : path }
        let selfPath = trim(url(for: directory, directory: true).path)
        return entries.compactMap { entry -> RemoteItem? in
            let entryPath = trim(entry.path)
            guard entryPath != selfPath else { return nil }
            let name = (entryPath as NSString).lastPathComponent
            guard !name.isEmpty, let path = try? directory.appending(name) else { return nil }
            return RemoteItem(path: path, isDirectory: entry.isCollection, size: entry.isCollection ? nil : entry.length, modified: entry.modified)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem? {
        guard let entry = try await propfind(path, depth: "0")?.first else { return nil }
        return RemoteItem(path: path, isDirectory: entry.isCollection, size: entry.isCollection ? nil : entry.length, modified: entry.modified)
    }

    public func createDirectory(_ path: RemotePath) async throws {
        let (_, response) = try await request("MKCOL", url(for: path, directory: true))
        switch response.statusCode {
        case 201: return
        case 405: throw FileCoreError.alreadyExists(path)
        case 409: throw FileCoreError.notFound(path.parent ?? path)
        default: throw FileCoreError.protocolError("MKCOL returned \(response.statusCode)")
        }
    }

    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        let isDirectory = try await item(at: source)?.isDirectory ?? false
        let (_, response) = try await request("MOVE", url(for: source, directory: isDirectory), headers: [
            "Destination": url(for: destination, directory: isDirectory).absoluteString, "Overwrite": "F",
        ])
        switch response.statusCode {
        case 201, 204: return
        case 412: throw FileCoreError.alreadyExists(destination)
        case 404: throw FileCoreError.notFound(source)
        case 409: throw FileCoreError.notFound(destination.parent ?? destination)
        default: throw FileCoreError.protocolError("MOVE returned \(response.statusCode)")
        }
    }

    public func delete(_ path: RemotePath) async throws {
        guard !path.isRoot else { throw FileCoreError.permissionDenied("the connection root cannot be deleted") }
        let isDirectory = try await item(at: path)?.isDirectory ?? false
        let (_, response) = try await request("DELETE", url(for: path, directory: isDirectory))
        switch response.statusCode {
        case 200, 204: return
        case 404: throw FileCoreError.notFound(path)
        default: throw FileCoreError.protocolError("DELETE returned \(response.statusCode)")
        }
    }

    public func capacity() async throws -> StorageCapacity? {
        guard let entry = try await propfind(.root, depth: "0")?.first, let available = entry.quotaAvailable else { return nil }
        return StorageCapacity(totalBytes: available + (entry.quotaUsed ?? 0), availableBytes: available)
    }

    public func read(_ path: RemotePath, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let (data, response) = try await request("GET", url(for: path), headers: ["Range": "bytes=\(offset)-\(offset + Int64(length) - 1)"])
        switch response.statusCode {
        case 206: return data
        case 200:
            // Server ignored Range: slice locally.
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(start + length, data.count))
        case 404: throw FileCoreError.notFound(path)
        case 416: return Data()
        default: throw FileCoreError.protocolError("GET returned \(response.statusCode)")
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url(for: path))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")  // preemptive; delegate answers challenges
        let (temp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw FileCoreError.protocolError("not an HTTP response") }
        try Self.checkCommon(http.statusCode)
        if http.statusCode == 404 { throw FileCoreError.notFound(path) }
        guard http.statusCode == 200 else { throw FileCoreError.protocolError("GET returned \(http.statusCode)") }
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: temp, to: localURL)
        progress(Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    public func makeUploadSink(for request: UploadRequest) async throws -> any UploadSink {
        let tempPath = try request.directory.appending(TempFileUploadSink.tempName(for: request.itemID))
        let existing = try await item(at: tempPath)
        if existing == nil, let result = try await TempFileUploadSink.recoveredCommit(provider: self, request: request) {
            return WebDAVUploadSink(provider: self, request: request, tempPath: tempPath, state: .alreadyCommitted(result))
        }
        // No partial writes: any earlier partial (ours by name) is discarded.
        if existing != nil { try await delete(tempPath) }
        return WebDAVUploadSink(provider: self, request: request, tempPath: tempPath, state: .upload(fromOffset: 0, resumed: false))
    }

    public func discardUpload(resumeToken: String) async {
        guard let path = try? RemotePath(resumeToken), path.name.hasPrefix(TempFileUploadSink.tempPrefix) else { return }
        try? await delete(path)
    }

    fileprivate func put(file: URL, to path: RemotePath, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "PUT"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")  // preemptive; delegate answers challenges
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(progress: progress)
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw FileCoreError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FileCoreError.protocolError("not an HTTP response") }
        try Self.checkCommon(http.statusCode)
        switch http.statusCode {
        case 200, 201, 204: return
        case 412: throw FileCoreError.alreadyExists(path)
        case 409: throw FileCoreError.notFound(path.parent ?? path)
        default: throw FileCoreError.protocolError("PUT returned \(http.statusCode)")
        }
    }
}

private final class WebDAVAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let credential: URLCredential
    let host: String
    init(credential: URLCredential, host: String) {
        self.credential = credential
        self.host = host
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame,
              method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            return (.performDefaultHandling, nil)
        }
        // A rejected credential is not retried in a loop.
        return challenge.previousFailureCount == 0 ? (.useCredential, credential) : (.rejectProtectionSpace, nil)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}

final class WebDAVUploadSink: UploadSink, @unchecked Sendable {
    private let provider: WebDAVProvider
    private let request: UploadRequest
    private let tempPath: RemotePath
    let state: UploadSinkState
    var resumeToken: String { tempPath.string }
    var uploadsWholeFile: Bool { true }

    init(provider: WebDAVProvider, request: UploadRequest, tempPath: RemotePath, state: UploadSinkState) {
        self.provider = provider
        self.request = request
        self.tempPath = tempPath
        self.state = state
    }

    func append(_ data: Data, at offset: Int64) async throws {
        throw FileCoreError.unsupported("WebDAV partial writes")
    }

    func uploadWholeFile(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await provider.put(file: url, to: tempPath, progress: progress)
    }

    func finish(verifyContents: Bool, willCommit: @escaping @Sendable (RemotePath) async -> Void) async throws -> UploadResult {
        if case .alreadyCommitted(let result) = state { return result }
        return try await TempFileUploadSink.publish(provider: provider, tempPath: tempPath, request: request, verifyContents: verifyContents, willCommit: willCommit)
    }

    func abort() async {
        try? await provider.delete(tempPath)
    }
}

struct WebDAVEntry {
    var path: String
    var isCollection = false
    var length: Int64?
    var modified: Date?
    var quotaAvailable: Int64?
    var quotaUsed: Int64?
}

/// Minimal namespace-aware parser for 207 Multi-Status PROPFIND responses.
final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var current: WebDAVEntry?
    private var text = ""
    private var propstatOK = true
    private var pending = WebDAVEntry(path: "")

    static func parse(_ data: Data) -> [WebDAVEntry] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response": current = WebDAVEntry(path: "")
        case "propstat": pending = WebDAVEntry(path: ""); propstatOK = true
        case "collection": pending.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            // hrefs may be absolute URLs or paths; keep the decoded path.
            let encoded = URL(string: value)?.path(percentEncoded: true) ?? value
            current?.path = encoded.removingPercentEncoding ?? encoded
        case "status": propstatOK = value.contains(" 200 ")
        case "getcontentlength": pending.length = Int64(value)
        case "getlastmodified": pending.modified = Self.dateFormatter.date(from: value)
        case "quota-available-bytes": pending.quotaAvailable = Int64(value)
        case "quota-used-bytes": pending.quotaUsed = Int64(value)
        case "propstat":
            if propstatOK, var entry = current {
                entry.isCollection = entry.isCollection || pending.isCollection
                entry.length = pending.length ?? entry.length
                entry.modified = pending.modified ?? entry.modified
                entry.quotaAvailable = pending.quotaAvailable ?? entry.quotaAvailable
                entry.quotaUsed = pending.quotaUsed ?? entry.quotaUsed
                current = entry
            }
        case "response":
            if let current { entries.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}
