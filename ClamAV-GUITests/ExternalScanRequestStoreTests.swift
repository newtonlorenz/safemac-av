import XCTest
@testable import ClamAV_GUI

final class ExternalScanRequestStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func testEnqueueAndDrainRequests() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)

        try store.enqueue(paths: ["/tmp/b", "/tmp/a/../a", "/tmp/a", ""], source: ExternalScanRequestStore.finderSource)
        let requests = try store.drainRequests()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].paths, ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(requests[0].source, ExternalScanRequestStore.finderSource)
        XCTAssertTrue(try store.drainRequests().isEmpty)
    }

    func testRejectsRequestsWithoutAbsolutePaths() {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)

        XCTAssertThrowsError(
            try store.enqueue(paths: ["relative/path", "", "   "], source: ExternalScanRequestStore.finderSource)
        ) { error in
            XCTAssertEqual(error as? ExternalScanRequestStoreError, .noValidPaths)
        }
    }

    func testRejectsUnknownSources() {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)

        XCTAssertThrowsError(
            try store.enqueue(paths: ["/tmp/a"], source: "notification")
        ) { error in
            XCTAssertEqual(error as? ExternalScanRequestStoreError, .invalidSource)
        }
    }

    func testDrainRequestOnlyConsumesMatchingRequestID() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let first = try store.enqueue(paths: ["/tmp/a"], source: ExternalScanRequestStore.finderSource)
        let second = try store.enqueue(paths: ["/tmp/b"], source: ExternalScanRequestStore.finderSource)

        let requests = try store.drainRequest(id: second.id)

        XCTAssertEqual(requests.map(\.id), [second.id])
        XCTAssertEqual(requests.first?.paths, ["/tmp/b"])
        XCTAssertEqual(try store.drainRequests().map(\.id), [first.id])
    }
}
