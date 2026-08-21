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

    func testEnqueueRejectsRelativePaths() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)

        XCTAssertThrowsError(try store.enqueue(paths: ["relative/path"], source: "finder")) { error in
            XCTAssertEqual(error as? ExternalScanRequestStoreError, .invalidPaths)
        }
        XCTAssertTrue(try store.drainRequests().isEmpty)
    }

    func testEnqueueUsesRestrictivePermissions() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)

        try store.enqueue(paths: ["/tmp/a"], source: "finder")

        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        let requestURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil).first
        )
        let queuePermissions = try permissions(at: queueURL)
        let requestPermissions = try permissions(at: requestURL)
        XCTAssertEqual(queuePermissions, 0o700)
        XCTAssertEqual(requestPermissions, 0o600)
    }

    func testDrainDropsStaleRequestsWithoutScanning() throws {
        let currentDate = Date()
        let store = ExternalScanRequestStore(baseURL: tempDirectory, now: { currentDate })
        let staleRequest = ExternalScanRequest(
            id: UUID(),
            createdAt: currentDate.addingTimeInterval(-10 * 60),
            paths: ["/tmp/a"],
            source: "finder"
        )

        try writeRequest(staleRequest)

        XCTAssertTrue(try store.drainRequests().isEmpty)
        XCTAssertTrue(try queueFiles().isEmpty)
    }

    func testDrainDropsSymlinkedRequestFilesWithoutFollowingThem() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
        let targetURL = tempDirectory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: targetURL)
        let linkURL = queueURL.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertTrue(try store.drainRequests().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testEnqueueFailsWhenQueueIsFull() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)

        for index in 0..<25 {
            try writeRequest(
                ExternalScanRequest(
                    id: UUID(),
                    createdAt: Date(),
                    paths: ["/tmp/\(index)"],
                    source: "finder"
                )
            )
        }

        XCTAssertThrowsError(try store.enqueue(paths: ["/tmp/overflow"], source: "finder")) { error in
            XCTAssertEqual(error as? ExternalScanRequestStoreError, .queueFull)
        }
    }

    func testDrainRejectsTamperedRequestWithRelativePath() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        try writeRequest(
            ExternalScanRequest(
                id: UUID(),
                createdAt: Date(),
                paths: ["/tmp/a", "relative/path"],
                source: "finder"
            )
        )

        XCTAssertTrue(try store.drainRequests().isEmpty)
        XCTAssertTrue(try queueFiles().isEmpty)
    }

    private func writeRequest(_ request: ExternalScanRequest) throws {
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(request)
        try data.write(to: queueURL.appendingPathComponent("\(request.id.uuidString).json"))
    }

    private func queueFiles() throws -> [URL] {
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
