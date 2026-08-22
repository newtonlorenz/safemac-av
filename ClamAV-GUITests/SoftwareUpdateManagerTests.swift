import XCTest
@testable import ClamAV_GUI

@MainActor
final class SoftwareUpdateManagerTests: XCTestCase {
    func testSafeMacSoftwareUpdateNotificationIdentity() {
        XCTAssertEqual(
            Notification.Name.checkForAppUpdates,
            Notification.Name("com.newtonlorenz.SafeMacAV.checkForAppUpdates")
        )
    }

    private let validPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    func testRejectsMissingSparkleConfiguration() {
        XCTAssertFalse(SoftwareUpdateManager.hasRequiredSparkleConfiguration(feedURLString: nil, publicKey: nil))
        XCTAssertFalse(SoftwareUpdateManager.hasRequiredSparkleConfiguration(feedURLString: "https://example.com/appcast.xml", publicKey: ""))
    }

    func testRejectsUnexpandedBuildSettingPlaceholders() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "$(SPARKLE_FEED_URL)",
                publicKey: "$(SPARKLE_PUBLIC_ED_KEY)"
            )
        )
    }

    func testRequiresHTTPSFeedURL() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "http://example.com/appcast.xml",
                publicKey: validPublicKey
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "not a url",
                publicKey: validPublicKey
            )
        )
    }

    func testRequiresValidPublicEdDSAKey() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "public-key"
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "c2hvcnQ="
            )
        )
    }

    func testRequiresSignedFeedAndPreExtractionVerification() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: validPublicKey,
                requiresSignedFeed: false,
                verifiesUpdateBeforeExtraction: true
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: validPublicKey,
                requiresSignedFeed: true,
                verifiesUpdateBeforeExtraction: false
            )
        )
    }

    func testAcceptsHTTPSFeedURLAndPublicKey() {
        XCTAssertTrue(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: validPublicKey
            )
        )
    }

    func testAutomatedTestInitializationDoesNotStartUpdater() {
        let manager = SoftwareUpdateManager(bundle: .main, isAutomatedTest: true)

        XCTAssertFalse(manager.hasStartedUpdater)
    }

    func testDefaultInitializationDefersUpdaterStart() {
        var starts = 0
        let manager = SoftwareUpdateManager(
            isAutomatedTest: false,
            isConfiguredOverride: true,
            updaterStartHandler: { starts += 1 }
        )

        XCTAssertFalse(manager.hasStartedUpdater)
        XCTAssertEqual(starts, 0)
    }

    func testStoppedSparkleControllerObservesItsInitialReadinessWithoutStarting() async {
        let manager = SoftwareUpdateManager(
            isAutomatedTest: false,
            isConfiguredOverride: true
        )

        await Task.yield()

        XCTAssertFalse(manager.hasStartedUpdater)
    }

    func testExplicitAutomaticStartStartsTheDeferredControllerOnce() {
        var starts = 0
        let manager = SoftwareUpdateManager(
            startsUpdater: true,
            isAutomatedTest: false,
            isConfiguredOverride: true,
            updaterStartHandler: { starts += 1 }
        )

        XCTAssertTrue(manager.hasStartedUpdater)
        XCTAssertEqual(starts, 1)
    }

    func testUnconfiguredManagerNeverStartsOrChecks() {
        var starts = 0
        var checks = 0
        let manager = SoftwareUpdateManager(
            isAutomatedTest: false,
            isConfiguredOverride: false,
            updaterStartHandler: { starts += 1 },
            updateCheckHandler: { checks += 1 }
        )

        manager.checkForUpdates()

        XCTAssertFalse(manager.hasStartedUpdater)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(checks, 0)
    }

    func testInitialMaintenanceCompletesBeforeVisibleInteractiveUpdaterStart() async {
        var events: [String] = []
        let coordinator = SoftwareUpdateStartupCoordinator()
        let settings = AppSettings.default

        await coordinator.runInitialMaintenance(
            launchMode: .interactive,
            settingsProvider: { settings },
            isUITesting: false,
            maintenance: {
                events.append("maintenance-start")
                await Task.yield()
                events.append("maintenance-finish")
            },
            startUpdater: {
                events.append("updater-start")
            }
        )

        XCTAssertEqual(events, ["maintenance-start", "maintenance-finish", "updater-start"])

        await coordinator.runInitialMaintenance(
            launchMode: .interactive,
            settingsProvider: { settings },
            isUITesting: false,
            maintenance: { events.append("unexpected-maintenance") },
            startUpdater: { events.append("unexpected-updater") }
        )
        XCTAssertEqual(events, ["maintenance-start", "maintenance-finish", "updater-start"])
    }

    func testHiddenAndScheduledLaunchesNeverAutoStartUpdater() async {
        var hiddenSettings = AppSettings.default
        hiddenSettings.hideFromDock = true
        var starts = 0

        for (mode, settings) in [
            (LaunchMode.interactive, hiddenSettings),
            (.scheduledScan(jobID: nil, paths: []), AppSettings.default),
            (.scheduledSignatureUpdate, AppSettings.default)
        ] {
            let coordinator = SoftwareUpdateStartupCoordinator()
            await coordinator.runInitialMaintenance(
                launchMode: mode,
                settingsProvider: { settings },
                isUITesting: false,
                maintenance: {},
                startUpdater: { starts += 1 }
            )
        }

        XCTAssertEqual(starts, 0)
    }

    func testExplicitUpdateStartAndCheckAreIdempotent() {
        var starts = 0
        var checks = 0
        let manager = SoftwareUpdateManager(
            startsUpdater: false,
            isAutomatedTest: false,
            isConfiguredOverride: true,
            updaterStartHandler: { starts += 1 },
            updateCheckHandler: { checks += 1 }
        )

        manager.startUpdaterIfPossible()
        manager.startUpdaterIfPossible()
        manager.checkForUpdates()
        manager.checkForUpdates()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(checks, 2)
    }

    func testExplicitCheckWaitsForSparkleReadinessThenRunsOnce() {
        var starts = 0
        var checks = 0
        var isReady = false
        let manager = SoftwareUpdateManager(
            startsUpdater: false,
            isAutomatedTest: false,
            isConfiguredOverride: true,
            updaterStartHandler: { starts += 1 },
            updateCheckHandler: { checks += 1 },
            updateCheckReadinessHandler: { isReady }
        )

        manager.checkForUpdates()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(checks, 0)

        isReady = true
        manager.updaterReadinessDidChange()
        manager.updaterReadinessDidChange()

        XCTAssertEqual(checks, 1)
    }

    func testExplicitCheckUpdatesRouteStartsUpdaterExactlyOnce() async {
        var starts = 0
        var checks = 0
        let started = expectation(description: "updater started from explicit route")
        let manager = SoftwareUpdateManager(
            startsUpdater: false,
            isAutomatedTest: false,
            isConfiguredOverride: true,
            updaterStartHandler: {
                starts += 1
                started.fulfill()
            },
            updateCheckHandler: { checks += 1 }
        )

        NotificationCenter.default.post(name: .checkForAppUpdates, object: nil)
        await fulfillment(of: [started], timeout: 1)
        NotificationCenter.default.post(name: .checkForAppUpdates, object: nil)
        await Task.yield()

        XCTAssertTrue(manager.hasStartedUpdater)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(checks, 2)
    }

    func testAutomatedTestManagerDoesNotStartUpdaterEvenWhenExplicitlyRequested() {
        var starts = 0
        let manager = SoftwareUpdateManager(
            startsUpdater: false,
            isAutomatedTest: true,
            isConfiguredOverride: true,
            updaterStartHandler: { starts += 1 }
        )

        manager.startUpdaterIfPossible()
        manager.checkForUpdates()

        XCTAssertEqual(starts, 0)
    }
}
