import FileCore
import Foundation
import XCTest

/// Isolated temp directory removed after each test.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FileCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relative: String, _ data: Data) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func directory(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}

func randomData(_ count: Int, seed: UInt8 = 1) -> Data {
    var generator = SeededGenerator(seed: UInt64(seed))
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A disposable nested folder with Unicode names and an empty subfolder,
/// mirroring the device acceptance fixture.
func makeNestedFixture(in temp: TempDirectory, name: String = "Trip") throws -> (URL, [String: Data]) {
    let files: [String: Data] = [
        "\(name)/notes.txt": Data("hello\n".utf8),
        "\(name)/Day 1/photo-01.bin": randomData(300_000, seed: 2),
        "\(name)/Day 1/Café ☕️/menu.txt": Data("crème brûlée\n".utf8),
        "\(name)/Day 2/video.bin": randomData(1_100_000, seed: 3),
        "\(name)/Day 2/empty.dat": Data(),
    ]
    for (path, data) in files { _ = try temp.file("source/\(path)", data) }
    _ = try temp.directory("source/\(name)/Empty Folder")
    return (temp.url.appendingPathComponent("source/\(name)", isDirectory: true), files)
}

/// Builds a queue over one provider with fast retries and small chunks.
final class QueueHarness {
    let temp: TempDirectory
    let staging: StagingArea
    let storeURL: URL
    let connectionID = UUID()
    let provider: any StorageProvider

    init(provider: any StorageProvider, temp: TempDirectory? = nil) throws {
        self.temp = try temp ?? TempDirectory()
        self.provider = provider
        staging = StagingArea(root: self.temp.url.appendingPathComponent("staging"), quotaBytes: 1 << 30, volumeReserveBytes: 0)
        storeURL = self.temp.url.appendingPathComponent("state/transfers.json")
    }

    func makeQueue() async -> TransferQueue {
        let provider = self.provider
        let id = connectionID
        let queue = TransferQueue(store: TransferStore(url: storeURL), staging: staging) { requested in
            guard requested == id else { throw FileCoreError.invalidConfiguration("unknown connection") }
            return provider
        }
        await queue.setChunkSize(64 * 1024)
        await queue.setRetryDelays([.milliseconds(10), .milliseconds(10), .milliseconds(10)])
        return queue
    }

    func folderJob(_ folder: URL, destination: RemotePath = .root, verify: Bool = true) throws -> TransferJob {
        let jobID = UUID()
        let staged = try staging.stage(folder: folder, jobID: jobID)
        return TransferJob(
            id: jobID, connectionID: connectionID, connectionName: "Test", destination: destination,
            rootFolderName: staged.rootFolderName, directories: staged.directories, items: staged.items, verifyContents: verify
        )
    }

    func filesJob(_ files: [URL], destination: RemotePath = .root, verify: Bool = true) throws -> TransferJob {
        let jobID = UUID()
        let staged = try staging.stage(files: files, jobID: jobID)
        return TransferJob(
            id: jobID, connectionID: connectionID, connectionName: "Test", destination: destination,
            rootFolderName: nil, directories: [], items: staged.items, verifyContents: verify
        )
    }
}

extension TransferQueue {
    func job(_ id: UUID) -> TransferJob? { jobs.first { $0.id == id } }
}
