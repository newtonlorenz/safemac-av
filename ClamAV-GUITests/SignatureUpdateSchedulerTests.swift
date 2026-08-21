import XCTest
@testable import ClamAV_GUI

final class SignatureUpdateSchedulerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testLaunchArgumentsUseDedicatedSignatureUpdateMode() {
        let scheduler = SignatureUpdateScheduler(
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            appBundleURL: URL(fileURLWithPath: "/Applications/ClamAV-GUI.app")
        )

        XCTAssertEqual(
            scheduler.launchArguments(executablePath: "/Applications/ClamAV-GUI.app/Contents/MacOS/ClamAV-GUI"),
            [
                "/Applications/ClamAV-GUI.app/Contents/MacOS/ClamAV-GUI",
                "--update-signatures"
            ]
        )
    }

    func testDailyLaunchAgentPlistContainsExpectedScheduleAndArguments() throws {
        let scheduler = SignatureUpdateScheduler(
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            appBundleURL: URL(fileURLWithPath: "/Applications/ClamAV-GUI.app")
        )

        let plist = scheduler.buildLaunchAgentPlist(schedule: .daily9am)
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(dictionary["Label"] as? String, "com.newtonlorenz.ClamAV-GUI.signature-update")
        XCTAssertNil(dictionary["StandardOutPath"])
        XCTAssertNil(dictionary["StandardErrorPath"])
        XCTAssertEqual(
            dictionary["ProgramArguments"] as? [String],
            [
                "/Applications/ClamAV-GUI.app/Contents/MacOS/ClamAV-GUI",
                "--update-signatures"
            ]
        )

        let interval = try XCTUnwrap(dictionary["StartCalendarInterval"] as? [String: Int])
        XCTAssertEqual(interval["Hour"], 9)
        XCTAssertEqual(interval["Minute"], 0)
    }

    func testWeeklyLaunchAgentPlistContainsWeekday() throws {
        let scheduler = SignatureUpdateScheduler(
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            appBundleURL: URL(fileURLWithPath: "/Applications/ClamAV-GUI.app")
        )
        let schedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 7, minute: 30),
            dayOfWeek: 2
        )

        let plist = scheduler.buildLaunchAgentPlist(schedule: schedule)
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let interval = try XCTUnwrap(dictionary["StartCalendarInterval"] as? [String: Int])

        XCTAssertEqual(interval["Weekday"], 2)
        XCTAssertEqual(interval["Hour"], 7)
        XCTAssertEqual(interval["Minute"], 30)
    }

    func testInstallWritesPlistAtomicallyAndBootstrapsUserGuiDomain() throws {
        let fixture = try makeFixture()
        var commands: [[String]] = []
        var writeOptions: [Data.WritingOptions] = []
        let scheduler = SignatureUpdateScheduler(
            homeDirectory: fixture.homeDirectory,
            appBundleURL: URL(fileURLWithPath: "/Applications/ClamAV-GUI.app"),
            dataWriter: { data, url, options in
                writeOptions.append(options)
                try data.write(to: url, options: options)
            },
            launchctlRunner: { commands.append($0) }
        )

        try scheduler.install(schedule: .daily9am)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        XCTAssertTrue(writeOptions.allSatisfy { $0.contains(.atomic) })
        XCTAssertEqual(commands, [["bootstrap", "gui/\(getuid())", fixture.plistURL.path]])
    }

    func testFailedBootstrapRestoresPreviousPlist() throws {
        let fixture = try makeFixture()
        let previous = Data("previous plist".utf8)
        try previous.write(to: fixture.plistURL)
        var commands: [[String]] = []
        let scheduler = SignatureUpdateScheduler(
            homeDirectory: fixture.homeDirectory,
            launchctlRunner: { arguments in
                commands.append(arguments)
                if arguments.first == "bootstrap" {
                    throw SignatureUpdateSchedulerError.launchctlFailed(status: 5)
                }
            }
        )

        XCTAssertThrowsError(try scheduler.install(schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), previous)
        XCTAssertEqual(commands.map(\.first), ["bootout", "bootstrap", "bootout", "bootstrap"])
    }

    private func makeFixture() throws -> SignatureUpdateSchedulerFixture {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureUpdateSchedulerTests-\(UUID().uuidString)", isDirectory: true)
        let launchAgentsDirectory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        temporaryDirectories.append(homeDirectory)
        return SignatureUpdateSchedulerFixture(homeDirectory: homeDirectory)
    }
}

private struct SignatureUpdateSchedulerFixture {
    let homeDirectory: URL

    var plistURL: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.newtonlorenz.ClamAV-GUI.signature-update.plist")
    }
}
