import XCTest
@testable import ClamAV_GUI

final class LaunchModeParserTests: XCTestCase {
    func testParsesInteractiveModeByDefault() {
        let mode = LaunchModeParser.parse(arguments: ["ClamAV-GUI"])
        XCTAssertEqual(mode, .interactive)
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
        }
    }
}
