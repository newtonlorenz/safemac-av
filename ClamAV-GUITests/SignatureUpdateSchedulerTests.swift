import XCTest
@testable import ClamAV_GUI

final class SignatureUpdateSchedulerTests: XCTestCase {
    private enum TestError: Error {
        case intentionalWriteFailure
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testDailyScheduleInstallsPrivacySafeLaunchAgentAtomically() throws {
        let fixture = try makeFixture()
        var commands: [(String, URL)] = []
        var writeOptions: [Data.WritingOptions] = []
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            dataWriter: { data, url, options in
                writeOptions.append(options)
                try data.write(to: url, options: options)
            },
            launchctlRunner: { command, url in commands.append((command, url)) }
        )
        let schedule = ScanSchedule(
            frequency: .daily,
            time: DateComponents(hour: 6, minute: 45)
        )

        try scheduler.reconcile(enabled: true, schedule: schedule)

        let data = try Data(contentsOf: fixture.plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, "com.newtonlorenz.ClamAV-GUI.signature-update")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            "/Applications/SafeMac AV.app/Contents/MacOS/ClamAV-GUI",
            "--scheduled-signature-update"
        ])
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], [
            "Hour": 6,
            "Minute": 45
        ])
        XCTAssertNil(plist["StandardOutPath"])
        XCTAssertNil(plist["StandardErrorPath"])
        XCTAssertEqual(commands.map(\.0), ["load"])
        XCTAssertEqual(commands.map(\.1), [fixture.plistURL])
        XCTAssertEqual(writeOptions.count, 1)
        XCTAssertTrue(writeOptions.allSatisfy { $0.contains(.atomic) })
    }

    func testWeeklyScheduleIncludesSelectedWeekday() throws {
        let fixture = try makeFixture()
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            launchctlRunner: { _, _ in }
        )
        let schedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 12, minute: 5),
            dayOfWeek: 4
        )

        try scheduler.reconcile(enabled: true, schedule: schedule)

        let data = try Data(contentsOf: fixture.plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], [
            "Weekday": 4,
            "Hour": 12,
            "Minute": 5
        ])
    }

    func testReplacementUnloadsOldAgentBeforeLoadingAtomicReplacement() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var commands: [String] = []
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            launchctlRunner: { command, _ in commands.append(command) }
        )

        try scheduler.reconcile(enabled: true, schedule: .daily9am)

        XCTAssertEqual(commands, ["unload", "load"])
        XCTAssertNotEqual(try Data(contentsOf: fixture.plistURL), oldData)
    }

    func testFailedReplacementLoadRestoresPreviousAgent() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var commands: [String] = []
        var loadCount = 0
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            launchctlRunner: { command, _ in
                commands.append(command)
                if command == "load" {
                    loadCount += 1
                    if loadCount == 1 {
                        throw SignatureUpdateSchedulerError.launchctlFailed(command: command, status: 5)
                    }
                }
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
        XCTAssertEqual(commands, ["unload", "load", "unload", "load"])
    }

    func testFailedAtomicWriteRestoresPreviousAgent() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var commands: [String] = []
        var writes = 0
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            dataWriter: { data, url, options in
                writes += 1
                if writes == 1 { throw TestError.intentionalWriteFailure }
                try data.write(to: url, options: options)
            },
            launchctlRunner: { command, _ in commands.append(command) }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
        XCTAssertEqual(commands, ["unload", "load"])
    }

    func testDisablingUnloadsAndRemovesExistingAgent() throws {
        let fixture = try makeFixture()
        try Data("existing".utf8).write(to: fixture.plistURL)
        var commands: [String] = []
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            launchctlRunner: { command, _ in commands.append(command) }
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertEqual(commands, ["unload"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testDisablingWithoutInstalledAgentIsNoOp() throws {
        let fixture = try makeFixture()
        var commands: [String] = []
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            launchctlRunner: { command, _ in commands.append(command) }
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertTrue(commands.isEmpty)
    }

    func testMonthlyScheduleUsesDayOfMonthForExistingModelCompatibility() throws {
        let fixture = try makeFixture()
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            launchctlRunner: { _, _ in }
        )
        let schedule = ScanSchedule(
            frequency: .monthly,
            time: DateComponents(hour: 3, minute: 20),
            dayOfMonth: 14
        )

        try scheduler.reconcile(enabled: true, schedule: schedule)

        let data = try Data(contentsOf: fixture.plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], [
            "Day": 14,
            "Hour": 3,
            "Minute": 20
        ])
    }

    func testInvalidWeeklyScheduleFailsBeforeWritingOrLoading() throws {
        let fixture = try makeFixture()
        var commands: [String] = []
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            launchctlRunner: { command, _ in commands.append(command) }
        )
        let invalidSchedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 25, minute: 0),
            dayOfWeek: 9
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: invalidSchedule)) { error in
            guard case SignatureUpdateSchedulerError.invalidSchedule = error else {
                return XCTFail("Expected invalid schedule, got \(error)")
            }
        }
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testFailedFirstLoadRemovesIncompleteNewAgent() throws {
        let fixture = try makeFixture()
        var commands: [String] = []
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            launchctlRunner: { command, _ in
                commands.append(command)
                if command == "load" {
                    throw SignatureUpdateSchedulerError.launchctlFailed(command: command, status: 5)
                }
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(commands, ["load", "unload"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testFailedDisableUnloadPreservesExistingAgent() throws {
        let fixture = try makeFixture()
        let oldData = Data("existing".utf8)
        try oldData.write(to: fixture.plistURL)
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            launchctlRunner: { command, _ in
                throw SignatureUpdateSchedulerError.launchctlFailed(command: command, status: 5)
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: false, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
    }

    private func makeFixture() throws -> SignatureSchedulerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureUpdateSchedulerTests-\(UUID().uuidString)", isDirectory: true)
        let launchAgentsDirectory = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        return SignatureSchedulerFixture(launchAgentsDirectory: launchAgentsDirectory)
    }
}

private struct SignatureSchedulerFixture {
    let launchAgentsDirectory: URL

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent(
            "com.newtonlorenz.ClamAV-GUI.signature-update.plist"
        )
    }
}
