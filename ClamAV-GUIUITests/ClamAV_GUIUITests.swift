import XCTest

final class ClamAV_GUIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSidebarNavigationSwitchesDetailViews() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES", "-hasCompletedOnboarding", "YES"]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        app.activate()
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), "Expected the File menu")
        fileMenu.click()

        let newWindow = app.menuItems["New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), "Expected the default New Window command")
        newWindow.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Expected a visible application window")

        let tabs: [(button: String, title: String)] = [
            ("sidebar-dashboard", "screen-title-dashboard"),
            ("sidebar-scan", "screen-title-scan"),
            ("sidebar-quarantine", "screen-title-quarantine"),
            ("sidebar-history", "screen-title-history"),
            ("sidebar-updates", "screen-title-updates"),
            ("sidebar-scheduler", "screen-title-scheduler"),
            ("sidebar-logs", "screen-title-logs"),
            ("sidebar-settings", "screen-title-settings")
        ]

        XCTAssertTrue(app.descendants(matching: .any)["primary-sidebar"].waitForExistence(timeout: 5))

        for tab in tabs {
            let button = app.buttons[tab.button]
            XCTAssertTrue(button.waitForExistence(timeout: 2), "Missing sidebar button \(tab.button)")
            button.click()

            let title = app.descendants(matching: .any)[tab.title]
            XCTAssertTrue(title.waitForExistence(timeout: 2), "Detail did not switch to \(tab.title)")
        }
    }
}
