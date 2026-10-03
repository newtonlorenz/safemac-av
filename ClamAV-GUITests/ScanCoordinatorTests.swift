import XCTest
@testable import ClamAV_GUI

@MainActor
final class ScanCoordinatorTests: XCTestCase {
    func testNextScheduledDateKeepsSelectedWeekdayAndExactMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        let schedule = ScanSchedule(frequency: .weekly, time: DateComponents(hour: 9, minute: 7), dayOfWeek: 2)
        let next = try XCTUnwrap(schedule.nextRunDate(after: now, calendar: calendar))
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: next)
        XCTAssertEqual(parts.weekday, 2)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 7)
        XCTAssertGreaterThan(next, now)
    }

    func testCleanScanExportRetainsScopeAndSummary() throws {
        let report = ScanReport(startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 60), filesScanned: 12, infectedFiles: [], errors: [], scanPaths: [URL(fileURLWithPath: "/tmp/checked-folder")])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ScanReport.self, from: report.exportJSONData()), report)
        let csv = String(decoding: report.exportCSVData(), as: UTF8.self)
        XCTAssertTrue(csv.contains("checked-folder"))
        XCTAssertTrue(csv.contains("success"))
        XCTAssertTrue(csv.contains("12"))
    }

    func testIncompleteScanExportRetainsWarningsAndNeutralisesSpreadsheetFormulas() throws {
        let report = ScanReport(startTime: Date(), endTime: Date(), filesScanned: 1, infectedFiles: [ScanResult(path: "/tmp/file", threatName: "=untrusted")], errors: ["permission denied"], scanPaths: [URL(fileURLWithPath: "/tmp")], completionState: .scanError)
        let json = try JSONSerialization.jsonObject(with: report.exportJSONData()) as? [String: Any]
        XCTAssertEqual(json?["errors"] as? [String], ["permission denied"])
        let csv = String(decoding: report.exportCSVData(), as: UTF8.self)
        XCTAssertTrue(csv.contains("permission denied"))
        XCTAssertTrue(csv.contains("'=untrusted"))
    }

    func testCancellationDuringAdmissionPreventsLaunchAndDoesNotCancelNextScan() async {
        let runner = MockCoordinatorRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let request = ScanRequest(source: .scheduled, paths: [URL(fileURLWithPath: "/tmp/fixture")], options: .default)
        runner.nextReport = Self.report(paths: request.paths)
        let admissionStarted = expectation(description: "Admission is awaiting completion")
        var admissionContinuation: CheckedContinuation<Void, Never>?
        let scan = Task { @MainActor in
            await coordinator.run(request, onAdmitted: {
                await withCheckedContinuation { continuation in
                    admissionContinuation = continuation
                    admissionStarted.fulfill()
                }
            }) { _ in }
        }
        await fulfillment(of: [admissionStarted], timeout: 2)

        coordinator.cancelCurrentScan()
        admissionContinuation?.resume()
        let outcome = await scan.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(runner.scanCallCount, 0)
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertNil(coordinator.activeScanSource)

        let nextOutcome = await coordinator.run(request) { _ in }
        XCTAssertNotNil(nextOutcome.report)
        XCTAssertEqual(runner.scanCallCount, 1)
    }

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

    func testRunnerCancellationBecomesCancelledOutcome() async {
        let runner = MockCoordinatorRunner()
        runner.nextError = ClamAVError.cancelled
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let request = ScanRequest(source: .manual, paths: [URL(fileURLWithPath: "/tmp/a")], options: .default)

        let outcome = await coordinator.run(request) { _ in }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(coordinator.isScanning)
    }

    func testProcessAndPlaybackControlsDelegateToRunner() {
        let runner = MockCoordinatorRunner()
        runner.currentProcessPID = 42
        let coordinator = ScanCoordinator(clamAVRunner: runner)

        XCTAssertEqual(coordinator.currentProcessPID, 42)
        XCTAssertFalse(coordinator.scanIsPaused)

        coordinator.pauseScan()
        XCTAssertTrue(coordinator.scanIsPaused)

        coordinator.resumeScan()
        XCTAssertFalse(coordinator.scanIsPaused)

        coordinator.cancelCurrentScan()
        XCTAssertEqual(runner.cancelCallCount, 1)
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
    var cancelCallCount = 0
    var nextError: Error?
    var nextReport: ScanReport?
    var pendingContinuation: CheckedContinuation<ScanReport, Error>?
    var currentProcessPID: Int32?
    var scanIsPaused = false

    func scan(paths: [URL], options: ScanOptions, progressHandler: @escaping (ScanProgress) -> Void) async throws -> ScanReport {
        scanCallCount += 1

        if let nextError {
            throw nextError
        }

        if let nextReport { return nextReport }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func cancelCurrentScan() {
        cancelCallCount += 1
    }

    func pauseScan() {
        scanIsPaused = true
    }

    func resumeScan() {
        scanIsPaused = false
    }
}
