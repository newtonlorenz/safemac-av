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
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: queueURL.path)
        let targetURL = tempDirectory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: targetURL)
        let linkURL = queueURL.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertTrue(try store.drainRequests().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testEnqueueRejectsSymlinkedQueueWithoutChangingTargetPermissions() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let targetURL = tempDirectory.appendingPathComponent("queue-target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: queueURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(
            try store.enqueue(paths: ["/tmp/a"], source: ExternalScanRequestStore.finderSource)
        ) { error in
            XCTAssertEqual(error as? ExternalScanRequestStoreError, .invalidQueueDirectory)
        }
        XCTAssertEqual(try permissions(at: targetURL), 0o755)
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

    func testLoadDropsRequestFileWithOverlyBroadPermissions() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let request = try store.enqueue(
            paths: ["/tmp/a"],
            source: ExternalScanRequestStore.finderSource
        )
        let requestURL = requestFileURL(id: request.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: requestURL.path)

        XCTAssertTrue(try store.loadRequest(id: request.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
    }

    func testLoadDropsRequestWhoseFilenameDoesNotMatchPayloadID() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let request = ExternalScanRequest(
            id: UUID(),
            createdAt: Date(),
            paths: ["/tmp/a"],
            source: ExternalScanRequestStore.finderSource
        )
        try writeRequest(request, filenameID: UUID())

        XCTAssertTrue(try store.loadRequests().isEmpty)
        XCTAssertTrue(try queueFiles().isEmpty)
    }

    func testEnqueueRejectsPathLongerThanFilesystemBoundary() {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let oversizedPath = "/" + String(repeating: "a", count: 4_096)

        XCTAssertThrowsError(
            try store.enqueue(paths: [oversizedPath], source: ExternalScanRequestStore.finderSource)
        ) { error in
            XCTAssertEqual(error as? ExternalScanRequestStoreError, .invalidPaths)
        }
    }

    private func writeRequest(_ request: ExternalScanRequest, filenameID: UUID? = nil) throws {
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: queueURL.path)
        let data = try JSONEncoder().encode(request)
        let requestURL = queueURL.appendingPathComponent("\((filenameID ?? request.id).uuidString).json")
        try data.write(to: requestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
    }

    private func queueFiles() throws -> [URL] {
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil)
    }

    private func requestFileURL(id: UUID) -> URL {
        tempDirectory
            .appendingPathComponent("external-scan-requests", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
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

    func testLoadingRequestKeepsItQueuedUntilAcknowledged() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let request = try store.enqueue(
            paths: ["/tmp/a"],
            source: ExternalScanRequestStore.finderSource
        )

        XCTAssertEqual(try store.loadRequest(id: request.id).map(\.id), [request.id])
        XCTAssertEqual(try store.loadRequest(id: request.id).map(\.id), [request.id])

        try store.acknowledgeRequest(id: request.id)

        XCTAssertTrue(try store.loadRequest(id: request.id).isEmpty)
    }

    func testMalformedRecordDoesNotPreventValidRequestFromLoading() throws {
        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let valid = try store.enqueue(
            paths: ["/tmp/valid"],
            source: ExternalScanRequestStore.finderSource
        )
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        let malformedURL = queueURL.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: malformedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: malformedURL.path)

        XCTAssertEqual(try store.loadRequests().map(\.id), [valid.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedURL.path))
        XCTAssertEqual(try store.loadRequest(id: valid.id).map(\.id), [valid.id])
    }

    func testHandoffFailurePresentsFixedGenericMessageWithoutPostingWake() {
        var presentedMessage: String?
        var postedRequestIDs: [UUID] = []
        let handoff = FinderScanRequestHandoff(
            enqueue: { _, _ in throw ExternalScanRequestStoreError.appGroupUnavailable },
            postWake: { postedRequestIDs.append($0) },
            presentFailure: { presentedMessage = $0 }
        )

        XCTAssertFalse(handoff.submit(paths: ["/Users/alice/private.txt"]))
        XCTAssertTrue(postedRequestIDs.isEmpty)
        XCTAssertEqual(presentedMessage, FinderScanRequestHandoff.genericFailureMessage)
        XCTAssertFalse(try XCTUnwrap(presentedMessage).contains("alice"))
        XCTAssertFalse(try XCTUnwrap(presentedMessage).contains("private.txt"))
    }
}
