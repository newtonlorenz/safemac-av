import XCTest
@testable import ClamAV_GUI

@MainActor
final class ScanCoordinatorTests: XCTestCase {
    func testConcurrentRequestIsSkippedWhileScanIsActive() async {
        let runner = MockCoordinatorRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let firstRequest = ScanRequest(source: .manual, paths: [URL(fileURLWithPath: "/tmp/a")], options: .default)
        let secondRequest = ScanRequest(source: .download, paths: [URL(fileURLWithPath: "/tmp/b")], options: .default)

        let runningTask = Task { @MainActor in
            await coordinator.run(firstRequest) { _ in }
        }

        while runner.pendingContinuation == nil {
            await Task.yield()
        }

        let skipped = await coordinator.run(secondRequest) { _ in }
        XCTAssertEqual(skipped, .skippedAlreadyRunning(active: .manual))
        XCTAssertEqual(runner.scanCallCount, 1)

        runner.pendingContinuation?.resume(returning: Self.report(paths: firstRequest.paths))
        let firstOutcome = await runningTask.value

        XCTAssertNotNil(firstOutcome.report)
        XCTAssertFalse(coordinator.isScanning)
    }

    func testRunnerFailureBecomesFailedOutcome() async {
        let runner = MockCoordinatorRunner()
        runner.nextError = ClamAVError.scanFailed(exitCode: 2, message: "bad database")
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let request = ScanRequest(source: .manual, paths: [URL(fileURLWithPath: "/tmp/a")], options: .default)

        let outcome = await coordinator.run(request) { _ in }

        XCTAssertEqual(outcome.errorMessage, "Scan failed (exit 2): bad database")
        XCTAssertFalse(coordinator.isScanning)
    }

    private static func report(paths: [URL]) -> ScanReport {
        ScanReport(
            startTime: Date(),
            endTime: Date(),
            filesScanned: 1,
            infectedFiles: [],
            errors: [],
            scanPaths: paths,
            exitCode: 0,
            completionState: .success
        )
    }
}

private final class MockCoordinatorRunner: ClamAVRunnerProtocol {
    var scanCallCount = 0
    var nextError: Error?
    var pendingContinuation: CheckedContinuation<ScanReport, Error>?
    var currentProcessPID: Int32?
    var scanIsPaused = false

    func scan(paths: [URL], options: ScanOptions, progressHandler: @escaping (ScanProgress) -> Void) async throws -> ScanReport {
        scanCallCount += 1

        if let nextError {
            throw nextError
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func cancelCurrentScan() {}

    func pauseScan() {
        scanIsPaused = true
    }

    func resumeScan() {
        scanIsPaused = false
    }
}
