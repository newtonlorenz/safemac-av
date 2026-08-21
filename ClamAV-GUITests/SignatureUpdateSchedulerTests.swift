import XCTest
@testable import ClamAV_GUI

final class SignatureUpdateSchedulerTests: XCTestCase {
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
}
