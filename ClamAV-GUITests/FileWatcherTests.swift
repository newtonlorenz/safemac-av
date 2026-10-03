import CoreServices
import XCTest
@testable import ClamAV_GUI

final class FileWatcherTests: XCTestCase {
    func testReconfiguringSameDirectoriesPreservesPendingBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = FileWatcher(batchIntervalMinutes: 5, batchThreshold: 2)
        defer { watcher.stopWatching() }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let delivered = expectation(description: "both pending files delivered")
        watcher.startWatching(directories: [directory]) { _ in XCTFail("old callback used") }
        XCTAssertTrue(watcher.isWatching)
        let flags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
        watcher.processEvents(paths: [first.path], flags: [flags])

        // Saving an unrelated preference reconfigures these same folders.
        watcher.startWatching(directories: [directory, directory]) { urls in
            XCTAssertEqual(Set(urls), Set([first, second]))
            delivered.fulfill()
        }
        watcher.processEvents(paths: [second.path], flags: [flags])
        wait(for: [delivered], timeout: 1)
    }
}
