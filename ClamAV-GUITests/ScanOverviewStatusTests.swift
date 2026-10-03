import XCTest
@testable import ClamAV_GUI

final class ScanOverviewStatusTests: XCTestCase {
    func testActiveScanTakesPriorityOverSetupAndPreviousDetection() {
        let status = ScanOverviewStatus.resolve(installation: .missingSignatures, isScanning: true, isPaused: true, isUpdating: false, report: report(threats: [ScanResult(path: "/fixture", threatName: "Fixture")]))
        XCTAssertEqual(status.kind, .scanning)
        XCTAssertEqual(status.title, "Scan paused")
        XCTAssertEqual(status.action, .reviewScan)
    }

    func testMissingDefinitionsOffersUpdateInsteadOfEngineSetup() {
        let status = resolve(.missingSignatures)
        XCTAssertEqual(status.kind, .definitionsNeeded)
        XCTAssertEqual(status.action, .updateDefinitions)
    }

    func testMissingEngineOffersConfiguration() {
        XCTAssertEqual(resolve(.notInstalled).action, .configureEngine)
        XCTAssertEqual(resolve(.clamdUnavailable).action, .configureEngine)
    }

    func testDetectionsRemainVisibleAfterCompletedScan() {
        let status = resolve(.ready(clamscanPath: "/fixture"), report: report(threats: [ScanResult(path: "/fixture", threatName: "Fixture", actionTaken: .quarantined)]))
        XCTAssertEqual(status.kind, .detections)
        XCTAssertEqual(status.action, .reviewScan)
        XCTAssertTrue(status.detail.contains("quarantined"))
    }

    func testIncompleteResultDoesNotBecomeReady() {
        XCTAssertEqual(resolve(.ready(clamscanPath: "/fixture"), report: report(errors: ["Access denied"])).kind, .incomplete)
    }

    func testNewFailureTakesPriorityOverPreviousCleanReport() {
        let status = ScanOverviewStatus.resolve(installation: .ready(clamscanPath: "/fixture"), isScanning: false, isPaused: false, isUpdating: false, report: report(), scanError: "Could not scan")
        XCTAssertEqual(status.kind, .incomplete)
        XCTAssertEqual(status.detail, "Could not scan")
    }

    func testReadyDescribesScanningCapabilityWithoutSecurityScore() {
        let status = resolve(.ready(clamscanPath: "/fixture"))
        XCTAssertEqual(status.kind, .ready)
        XCTAssertEqual(status.title, "Ready to scan")
        XCTAssertNil(status.action)
    }

    func testUpdateProgressTakesPriorityOverMissingDefinitions() {
        let status = ScanOverviewStatus.resolve(installation: .missingSignatures, isScanning: false, isPaused: false, isUpdating: true, report: nil)
        XCTAssertEqual(status.kind, .updating)
    }

    private func resolve(_ installation: ClamAVInstallationStatus, report: ScanReport? = nil) -> ScanOverviewStatus {
        ScanOverviewStatus.resolve(installation: installation, isScanning: false, isPaused: false, isUpdating: false, report: report)
    }

    private func report(threats: [ScanResult] = [], errors: [String] = []) -> ScanReport {
        ScanReport(startTime: Date(), endTime: Date(), filesScanned: 2, infectedFiles: threats, errors: errors, scanPaths: [URL(fileURLWithPath: "/fixture")], exitCode: threats.isEmpty ? 0 : 1)
    }
}
