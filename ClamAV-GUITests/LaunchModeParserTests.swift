import XCTest
@testable import ClamAV_GUI

final class LaunchModeParserTests: XCTestCase {
    func testParsesInteractiveModeByDefault() {
        let mode = LaunchModeParser.parse(arguments: ["ClamAV-GUI"])
        XCTAssertEqual(mode, .interactive)
    }

    func testParsesScheduledSignatureUpdateMode() {
        let mode = LaunchModeParser.parse(arguments: [
            "ClamAV-GUI",
            "--scheduled-signature-update"
        ])

        XCTAssertEqual(mode, .scheduledSignatureUpdate)
        XCTAssertFalse(mode.isInteractive)
        XCTAssertFalse(mode.presentsUserInterface)
    }

    func testOnlyInteractiveModeRunsActiveSceneMaintenance() {
        XCTAssertTrue(LaunchMode.interactive.runsActiveSceneMaintenance)
        XCTAssertFalse(LaunchMode.scheduledSignatureUpdate.runsActiveSceneMaintenance)
        XCTAssertFalse(
            LaunchMode.scheduledScan(jobID: UUID(), paths: []).runsActiveSceneMaintenance
        )
    }

    func testScheduledSignatureUpdateDoesNotStartSoftwareUpdateSubsystem() {
        XCTAssertTrue(LaunchMode.interactive.startsSoftwareUpdateSubsystem)
        XCTAssertTrue(
            LaunchMode.scheduledScan(jobID: UUID(), paths: []).startsSoftwareUpdateSubsystem
        )
        XCTAssertFalse(LaunchMode.scheduledSignatureUpdate.startsSoftwareUpdateSubsystem)
    }

    func testParsesScheduledScanWithRepeatedPaths() {
        let jobID = UUID()
        let mode = LaunchModeParser.parse(arguments: [
            "ClamAV-GUI",
            "--scheduled-scan",
            "--job-id", jobID.uuidString,
            "--path", "/tmp/with space",
            "--path", "/tmp/with,comma"
        ])

        switch mode {
        case .scheduledScan(let parsedJobID, let paths):
            XCTAssertEqual(parsedJobID, jobID)
            XCTAssertEqual(paths.map(\.path).sorted(), ["/tmp/with space", "/tmp/with,comma"].sorted())
        case .interactive:
            XCTFail("Expected scheduled scan mode")
        case .scheduledSignatureUpdate:
            XCTFail("Expected scheduled scan mode, not signature update mode")
        }
    }

    func testScheduledModeFallsBackToInteractiveWhenNoPathsProvided() {
        let mode = LaunchModeParser.parse(arguments: ["ClamAV-GUI", "--scheduled-scan"])
        XCTAssertEqual(mode, .interactive)
    }

    func testParsesScheduledScanWithJobIDOnly() {
        let jobID = UUID()
        let mode = LaunchModeParser.parse(arguments: [
            "ClamAV-GUI",
            "--scheduled-scan",
            "--job-id", jobID.uuidString
        ])

        switch mode {
        case .scheduledScan(let parsedJobID, let paths):
            XCTAssertEqual(parsedJobID, jobID)
            XCTAssertTrue(paths.isEmpty)
        case .interactive:
            XCTFail("Expected scheduled scan mode")
        case .scheduledSignatureUpdate:
            XCTFail("Expected scheduled scan mode, not signature update mode")
        }
    }

    func testBackgroundHelperParsesOnlyItsFixedScheduledSignatureFlag() {
        XCTAssertEqual(
            BackgroundHelperLaunchModeParser.parse(arguments: [
                "SafeMacAVBackground",
                "--scheduled-signature-update"
            ]),
            .scheduledSignatureUpdate
        )
        XCTAssertEqual(
            BackgroundHelperLaunchModeParser.parse(arguments: ["SafeMacAVBackground"]),
            .backgroundSession
        )
    }

    func testBackgroundHelperRejectsMainApplicationFlags() {
        XCTAssertEqual(
            BackgroundHelperLaunchModeParser.parse(arguments: [
                "SafeMacAVBackground",
                "--scheduled-scan",
                "--path", "/tmp/unsafe"
            ]),
            .invalid
        )
    }

    func testBackgroundHelperNeverStartsUserInterfaceOrSparkle() {
        for mode in [
            BackgroundHelperLaunchMode.backgroundSession,
            .scheduledSignatureUpdate,
            .invalid
        ] {
            XCTAssertFalse(mode.presentsUserInterface)
            XCTAssertFalse(mode.startsSoftwareUpdateSubsystem)
            XCTAssertFalse(mode.consumesFinderRequests)
        }
    }
}
