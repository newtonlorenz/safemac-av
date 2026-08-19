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

        try store.enqueue(paths: ["/tmp/b", "/tmp/a", "/tmp/a", ""], source: "finder")
        let requests = try store.drainRequests()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].paths, ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(requests[0].source, "finder")
        XCTAssertTrue(try store.drainRequests().isEmpty)
    }
}
