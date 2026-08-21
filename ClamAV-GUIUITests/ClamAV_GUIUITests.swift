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

        openMainWindow(in: app)

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
            XCTAssertTrue(button.isSelected, "Expected \(tab.button) to expose its selected state")

            let title = app.descendants(matching: .any)[tab.title]
            XCTAssertTrue(title.waitForExistence(timeout: 2), "Detail did not switch to \(tab.title)")
        }
    }

    func testModernShellExposesItsPrimarySurfaces() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-ApplePersistenceIgnoreState", "YES",
            "-hasCompletedOnboarding", "YES",
            "--force-light-appearance"
        ]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        openMainWindow(in: app)

        let appShell = app.descendants(matching: .any)["app-shell"]
        XCTAssertTrue(appShell.waitForExistence(timeout: 5))
        XCTAssertEqual(appShell.label, "light")
        XCTAssertTrue(app.descendants(matching: .any)["primary-sidebar"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["detail-header"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard-content"].exists)

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Modern dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testModernShellSupportsDarkAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-ApplePersistenceIgnoreState", "YES",
            "-hasCompletedOnboarding", "YES",
            "--force-dark-appearance"
        ]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        openMainWindow(in: app)

        let appShell = app.descendants(matching: .any)["app-shell"]
        XCTAssertTrue(appShell.waitForExistence(timeout: 5))
        XCTAssertEqual(appShell.label, "dark")
        XCTAssertTrue(app.descendants(matching: .any)["dashboard-content"].exists)

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Modern dashboard dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testMenuBarExtraExposesStandaloneActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES", "-hasCompletedOnboarding", "YES"]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        let menuBarItem = app.menuBars.statusItems["SafeMac AV"]
        XCTAssertTrue(menuBarItem.waitForExistence(timeout: 5), "Expected the SafeMac AV menu-bar item")
        menuBarItem.click()

        XCTAssertTrue(app.descendants(matching: .any)["menu-bar-popover"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["menu-bar-quick-scan"].exists)
        XCTAssertTrue(app.buttons["menu-bar-update-signatures"].exists)
        XCTAssertTrue(app.buttons["menu-bar-open-main-window"].exists)
        XCTAssertTrue(app.buttons["menu-bar-open-settings"].exists)
        XCTAssertTrue(app.buttons["menu-bar-quit"].exists)
    }

    func testRepeatedMenuBarOpenReusesTheIdentifiedMainWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES", "-hasCompletedOnboarding", "YES"]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        openMainWindow(in: app)
        let menuBarItem = app.menuBars.statusItems["SafeMac AV"]
        XCTAssertTrue(menuBarItem.waitForExistence(timeout: 5))
        menuBarItem.click()
        let openButton = app.buttons["menu-bar-open-main-window"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 3))
        openButton.click()

        XCTAssertEqual(app.windows.matching(identifier: "main-window").count, 1)
    }

    func testLaunchAtLoginSettingShowsCurrentStatus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES", "-hasCompletedOnboarding", "YES"]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        openMainWindow(in: app)

        let settingsButton = app.buttons["sidebar-settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Expected the Settings sidebar button")
        settingsButton.click()

        XCTAssertTrue(app.descendants(matching: .any)["launch-at-login-toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["launch-at-login-status"].waitForExistence(timeout: 5))
    }

    func testAutomaticSignatureScheduleExposesSemanticControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES", "-hasCompletedOnboarding", "YES"]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launch()

        openMainWindow(in: app)

        let updatesButton = app.buttons["sidebar-updates"]
        XCTAssertTrue(updatesButton.waitForExistence(timeout: 5), "Expected the Updates sidebar button")
        updatesButton.click()

        XCTAssertTrue(app.descendants(matching: .any)["automatic-signature-updates-toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["signature-update-frequency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["signature-update-time"].waitForExistence(timeout: 5))
    }

    private func openMainWindow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()
        let mainWindow = app.windows["main-window"]

        if mainWindow.waitForExistence(timeout: 2) {
            return
        }

        let menuBarItem = app.menuBars.statusItems["SafeMac AV"]
        XCTAssertTrue(
            menuBarItem.waitForExistence(timeout: 5),
            "Expected the SafeMac AV menu-bar item while opening the main window",
            file: file,
            line: line
        )
        menuBarItem.click()

        let openMainWindowButton = app.buttons["menu-bar-open-main-window"]
        XCTAssertTrue(
            openMainWindowButton.waitForExistence(timeout: 3),
            "Expected the menu-bar Open SafeMac AV action",
            file: file,
            line: line
        )
        openMainWindowButton.click()

        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: 5),
            "Expected the identified main window to be visible",
            file: file,
            line: line
        )
    }
}
