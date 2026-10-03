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

    func testUnquarantinedDetectionsStayVisibleDuringUpdatesAndSetupFailures() {
        let detection = report(threats: [ScanResult(path: "/fixture", threatName: "Fixture")])
        let installations: [ClamAVInstallationStatus] = [.missingSignatures, .notInstalled, .outdatedSignatures(daysSinceUpdate: 8)]
        for installation in installations {
            let status = ScanOverviewStatus.resolve(installation: installation, isScanning: false, isPaused: false, isUpdating: false, report: detection)
            XCTAssertEqual(status.kind, .detections)
            XCTAssertEqual(status.action, .reviewScan)
        }
        let updating = ScanOverviewStatus.resolve(installation: .missingSignatures, isScanning: false, isPaused: false, isUpdating: true, report: detection)
        XCTAssertEqual(updating.kind, .detections)
        let failedRetry = ScanOverviewStatus.resolve(installation: .ready(clamscanPath: "/fixture"), isScanning: false, isPaused: false, isUpdating: false, report: detection, scanError: "Retry could not start")
        XCTAssertEqual(failedRetry.kind, .detections)
    }

    func testDetectionsWithoutFileDetailsRemainVisibleAndExplainRecovery() {
        let partial = ScanReport(startTime: Date(), endTime: Date(), filesScanned: 3, infectedFiles: [], errors: ["Stopped"], scanPaths: [URL(fileURLWithPath: "/fixture")], exitCode: -1, completionState: .cancelled, observedThreatCount: 2)
        let status = ScanOverviewStatus.resolve(installation: .missingSignatures, isScanning: false, isPaused: false, isUpdating: true, report: partial)
        XCTAssertEqual(status.kind, .detections)
        XCTAssertTrue(status.detail.contains("unavailable"))
        XCTAssertTrue(status.detail.contains("Scan these locations again"))
    }

    func testHandledDetectionsYieldToCurrentSetupAndUpdates() {
        let handled = report(threats: [ScanResult(path: "/fixture", threatName: "Fixture", actionTaken: .quarantined)])
        XCTAssertEqual(resolve(.notInstalled, report: handled).kind, .setupNeeded)
        let updating = ScanOverviewStatus.resolve(installation: .missingSignatures, isScanning: false, isPaused: false, isUpdating: true, report: handled)
        XCTAssertEqual(updating.kind, .updating)
    }

    func testMenuScanStatusRoutesExistingOutcomesToResultsEvenWhenEngineNeedsSetup() {
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: false, hasReport: true, hasScanError: false, overviewKind: .setupNeeded), .scan)
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: false, hasReport: false, hasScanError: true, overviewKind: .setupNeeded), .scan)
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: true, hasReport: false, hasScanError: false, overviewKind: .scanning), .scan)
    }

    func testMenuScanStatusRoutesFirstRunRecoveryToMatchingScreen() {
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: false, hasReport: false, hasScanError: false, overviewKind: .setupNeeded), .dashboard)
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: false, hasReport: false, hasScanError: false, overviewKind: .definitionsNeeded), .updates)
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: false, hasReport: false, hasScanError: false, overviewKind: .updating), .updates)
        XCTAssertEqual(MenuBarScanStatusRoute.resolve(isScanning: false, hasReport: false, hasScanError: false, overviewKind: .ready), .scan)
    }

    private func resolve(_ installation: ClamAVInstallationStatus, report: ScanReport? = nil) -> ScanOverviewStatus {
        ScanOverviewStatus.resolve(installation: installation, isScanning: false, isPaused: false, isUpdating: false, report: report)
    }

    private func report(threats: [ScanResult] = [], errors: [String] = []) -> ScanReport {
        ScanReport(startTime: Date(), endTime: Date(), filesScanned: 2, infectedFiles: threats, errors: errors, scanPaths: [URL(fileURLWithPath: "/fixture")], exitCode: threats.isEmpty ? 0 : 1)
    }
}
