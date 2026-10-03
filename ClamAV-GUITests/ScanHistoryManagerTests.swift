import XCTest
@testable import ClamAV_GUI

final class ScanHistoryManagerTests: XCTestCase {
    func testEntryRetainsCompleteCancelledReportForReview() {
        let report = makeReport(index: 1, completionState: .cancelled)
        let entry = ScanHistoryEntry(from: report, scanType: .custom)

        XCTAssertEqual(entry.report.scanPaths, report.scanPaths)
        XCTAssertEqual(entry.report.errors, report.errors)
        XCTAssertEqual(entry.report.infectedFiles, report.infectedFiles)
        XCTAssertEqual(entry.report.completionState, .cancelled)
        XCTAssertEqual(entry.report.exitCode, report.exitCode)
        XCTAssertFalse(entry.completedWithoutErrors)
    }

    func testHistoryRetainsOnlyNewestTwoHundredCompleteReports() {
        let manager = ScanHistoryManager()
        for index in 0...200 {
            manager.addEntry(ScanHistoryEntry(from: makeReport(index: index), scanType: .custom))
        }
        XCTAssertEqual(manager.entries.count, 200)
        XCTAssertEqual(manager.entries.first?.report.scanPaths.first?.lastPathComponent, "fixture-200")
        XCTAssertEqual(manager.entries.last?.report.scanPaths.first?.lastPathComponent, "fixture-1")
        XCTAssertTrue(ScanHistoryManager().entries.isEmpty, "A new session must not restore sensitive report paths.")
    }

    func testRemediationUpdatesOnlyMatchingReportWithoutChangingHistoryIdentityOrOrder() {
        let manager = ScanHistoryManager()
        let original = makeReport(index: 1, completionState: .infectedFound)
        let other = makeReport(index: 2, completionState: .infectedFound)
        let originalEntry = ScanHistoryEntry(from: original, scanType: .custom)
        let otherEntry = ScanHistoryEntry(from: other, scanType: .quick)
        manager.addEntry(originalEntry)
        manager.addEntry(otherEntry)
        var detections = original.infectedFiles
        detections[0].actionTaken = .quarantined
        let updated = ScanReport(startTime: original.startTime, endTime: original.endTime, filesScanned: original.filesScanned, infectedFiles: detections, errors: original.errors, scanPaths: original.scanPaths, exitCode: original.exitCode, completionState: original.completionState)
        manager.updateReport(updated, matching: original)
        XCTAssertEqual(manager.entries.map(\.id), [otherEntry.id, originalEntry.id])
        XCTAssertEqual(manager.entries[0].report, other)
        XCTAssertEqual(manager.entries[1].report.infectedFiles[0].actionTaken, .quarantined)
        XCTAssertEqual(manager.entries[1].scanType, .custom)
    }

    func testReportEqualityIncludesWarningsAndScanScope() {
        let original = makeReport(index: 1)
        let differentWarnings = ScanReport(startTime: original.startTime, endTime: original.endTime, filesScanned: original.filesScanned, infectedFiles: original.infectedFiles, errors: ["Different warning"], scanPaths: original.scanPaths, exitCode: original.exitCode, completionState: original.completionState)
        let differentScope = ScanReport(startTime: original.startTime, endTime: original.endTime, filesScanned: original.filesScanned, infectedFiles: original.infectedFiles, errors: original.errors, scanPaths: [URL(fileURLWithPath: "/tmp/different-scope")], exitCode: original.exitCode, completionState: original.completionState)
        XCTAssertNotEqual(original, differentWarnings)
        XCTAssertNotEqual(original, differentScope)
    }

    private func makeReport(index: Int, completionState: ScanCompletionState = .scanError) -> ScanReport {
        ScanReport(
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 110),
            filesScanned: 3,
            infectedFiles: [ScanResult(path: "/tmp/fixture-\(index)/sample", threatName: "Test.Signature")],
            errors: ["A fixture location could not be read"],
            scanPaths: [URL(fileURLWithPath: "/tmp/fixture-\(index)")],
            exitCode: 2,
            completionState: completionState
        )
    }
}
