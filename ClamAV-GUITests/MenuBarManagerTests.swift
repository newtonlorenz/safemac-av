import AppKit
import XCTest
@testable import ClamAV_GUI

@MainActor
final class MenuBarManagerTests: XCTestCase {
    func testHidingDockRequestsAccessoryActivationPolicy() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)

        manager.applyDockVisibility(hidden: true)

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertTrue(manager.isDockHidden)
    }

    func testShowingDockRequestsRegularActivationPolicy() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        manager.applyDockVisibility(hidden: true)

        manager.applyDockVisibility(hidden: false)

        XCTAssertEqual(application.requestedPolicies, [.accessory, .regular])
        XCTAssertFalse(manager.isDockHidden)
    }

    func testRejectedActivationPolicyDoesNotPublishUnappliedState() {
        let application = MenuBarApplicationMock()
        application.shouldAcceptPolicy = false
        let manager = MenuBarManager(application: application)

        manager.applyDockVisibility(hidden: true)

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertFalse(manager.isDockHidden)
    }

    func testActivatingMainWindowOpensWindowAndRaisesApplication() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)

        manager.activateMainWindow {
            application.events.append(.openWindow)
        }

        XCTAssertEqual(application.activationCalls, [true])
        XCTAssertEqual(application.events, [.activateApplication, .openWindow])
    }

    func testHiddenDockLaunchSuppressesInitialMainWindowAfterAccessoryPolicyIsAccepted() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)

        let shouldSuppress = manager.prepareForLaunch(hidden: true)
        manager.suppressInitialMainWindow(if: shouldSuppress)

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.closeMainWindowCalls, 1)
    }

    func testRegularLaunchKeepsInitialMainWindowVisible() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)

        let shouldSuppress = manager.prepareForLaunch(hidden: false)
        manager.suppressInitialMainWindow(if: shouldSuppress)

        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(application.closeMainWindowCalls, 0)
    }
}

private enum MenuBarApplicationEvent: Equatable {
    case activateApplication
    case openWindow
}

@MainActor
private final class MenuBarApplicationMock: ApplicationActivationPolicyApplying {
    var shouldAcceptPolicy = true
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCalls: [Bool] = []
    private(set) var closeMainWindowCalls = 0
    var events: [MenuBarApplicationEvent] = []

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        requestedPolicies.append(activationPolicy)
        return shouldAcceptPolicy
    }

    func activate(ignoringOtherApps: Bool) {
        activationCalls.append(ignoringOtherApps)
        events.append(.activateApplication)
    }

    func closeMainWindows() {
        closeMainWindowCalls += 1
    }
}
