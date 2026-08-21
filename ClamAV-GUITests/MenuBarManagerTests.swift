import AppKit
import XCTest
@testable import ClamAV_GUI

@MainActor
final class MenuBarManagerTests: XCTestCase {
    func testApplicationBundleStartsAsUIElement() {
        XCTAssertEqual(
            Bundle(for: MenuBarApplicationDelegate.self)
                .object(forInfoDictionaryKey: "LSUIElement") as? Bool,
            true
        )
    }

    func testInitialLaunchHandlerDrainsInteractiveRequestsOnce() async {
        let handler = InitialLaunchHandler()
        var presentMainWindowCalls = 0
        var drainCalls = 0
        var scheduledCalls = 0
        var presentationCompleted = false
        var drainedBeforePresentationCompleted = false

        await handler.handle(
            launchMode: .interactive,
            shouldPresentInteractiveMainWindow: true,
            presentInteractiveMainWindow: {
                presentMainWindowCalls += 1
                DispatchQueue.main.async {
                    presentationCompleted = true
                }
            },
            drainExternalScanRequests: {
                drainCalls += 1
                drainedBeforePresentationCompleted = !presentationCompleted
            },
            runScheduledScan: { _, _ in scheduledCalls += 1 }
        )
        await handler.handle(
            launchMode: .interactive,
            shouldPresentInteractiveMainWindow: true,
            presentInteractiveMainWindow: { presentMainWindowCalls += 1 },
            drainExternalScanRequests: { drainCalls += 1 },
            runScheduledScan: { _, _ in scheduledCalls += 1 }
        )

        XCTAssertEqual(presentMainWindowCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertEqual(scheduledCalls, 0)
        XCTAssertFalse(drainedBeforePresentationCompleted)
    }

    func testInitialLaunchHandlerPreservesHiddenDockInteractiveLaunch() async {
        let handler = InitialLaunchHandler()
        var presentMainWindowCalls = 0
        var drainCalls = 0

        await handler.handle(
            launchMode: .interactive,
            shouldPresentInteractiveMainWindow: false,
            presentInteractiveMainWindow: { presentMainWindowCalls += 1 },
            drainExternalScanRequests: { drainCalls += 1 },
            runScheduledScan: { _, _ in }
        )

        XCTAssertEqual(presentMainWindowCalls, 0)
        XCTAssertEqual(drainCalls, 1)
    }

    func testInitialLaunchHandlerRoutesScheduledScanOnce() async {
        let handler = InitialLaunchHandler()
        let jobID = UUID()
        let scheduledPath = URL(fileURLWithPath: "/tmp/scheduled")
        var presentMainWindowCalls = 0
        var drainCalls = 0
        var scheduledCalls: [(UUID?, [URL])] = []

        await handler.handle(
            launchMode: .scheduledScan(jobID: jobID, paths: [scheduledPath]),
            shouldPresentInteractiveMainWindow: true,
            presentInteractiveMainWindow: { presentMainWindowCalls += 1 },
            drainExternalScanRequests: { drainCalls += 1 },
            runScheduledScan: { jobID, paths in scheduledCalls.append((jobID, paths)) }
        )
        await handler.handle(
            launchMode: .scheduledScan(jobID: jobID, paths: [scheduledPath]),
            shouldPresentInteractiveMainWindow: true,
            presentInteractiveMainWindow: { presentMainWindowCalls += 1 },
            drainExternalScanRequests: { drainCalls += 1 },
            runScheduledScan: { jobID, paths in scheduledCalls.append((jobID, paths)) }
        )

        XCTAssertEqual(presentMainWindowCalls, 0)
        XCTAssertEqual(drainCalls, 0)
        XCTAssertEqual(scheduledCalls.count, 1)
        XCTAssertEqual(scheduledCalls.first?.0, jobID)
        XCTAssertEqual(scheduledCalls.first?.1, [scheduledPath])
    }

    func testInitialLaunchHandlerLeavesScheduledSignatureUpdateToApplicationLifecycle() async {
        let handler = InitialLaunchHandler()
        var presentMainWindowCalls = 0
        var drainCalls = 0
        var scheduledScanCalls = 0

        await handler.handle(
            launchMode: .scheduledSignatureUpdate,
            shouldPresentInteractiveMainWindow: true,
            presentInteractiveMainWindow: { presentMainWindowCalls += 1 },
            drainExternalScanRequests: { drainCalls += 1 },
            runScheduledScan: { _, _ in scheduledScanCalls += 1 }
        )
        await handler.handle(
            launchMode: .scheduledSignatureUpdate,
            shouldPresentInteractiveMainWindow: true,
            presentInteractiveMainWindow: { presentMainWindowCalls += 1 },
            drainExternalScanRequests: { drainCalls += 1 },
            runScheduledScan: { _, _ in scheduledScanCalls += 1 }
        )

        XCTAssertEqual(presentMainWindowCalls, 0)
        XCTAssertEqual(drainCalls, 0)
        XCTAssertEqual(scheduledScanCalls, 0)
    }

    func testApplicationDelegateSupportsRuntimeDefaultInitialization() {
        let delegateType: NSObject.Type = MenuBarApplicationDelegate.self

        XCTAssertTrue(delegateType.init() is MenuBarApplicationDelegate)
    }

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
        XCTAssertEqual(application.events, [.activateApplication, .focusMainWindow, .openWindow])
    }

    func testActivatingMainWindowFocusesExistingWindowWithoutOpeningAnother() {
        let application = MenuBarApplicationMock()
        application.focusMainWindowResult = true
        let manager = MenuBarManager(application: application)

        manager.activateMainWindow {
            application.events.append(.openWindow)
        }

        XCTAssertEqual(application.activationCalls, [true])
        XCTAssertEqual(application.events, [.activateApplication, .focusMainWindow])
    }

    func testUnidentifiedTitledWindowDoesNotMasqueradeAsMainWindow() {
        let pendingMainWindow = MainCapableTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        pendingMainWindow.title = "SafeMac AV"

        XCTAssertNil(pendingMainWindow.identifier)
        XCTAssertTrue(pendingMainWindow.canBecomeMain)
        XCTAssertNil(MenuBarManager.mainWindowCandidate(in: [pendingMainWindow]))
    }

    func testPendingMainWindowRequiresPositiveIdentityWhenUnrelatedWindowComesFirst() {
        let unrelatedWindow = MainCapableTestWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        unrelatedWindow.title = "Import"
        let pendingMainWindow = MainCapableTestWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        pendingMainWindow.title = "SafeMac AV"
        pendingMainWindow.identifier = NSUserInterfaceItemIdentifier(ClamAVApp.mainWindowID)

        XCTAssertTrue(
            MenuBarManager.mainWindowCandidate(
                in: [unrelatedWindow, pendingMainWindow]
            ) === pendingMainWindow
        )
    }

    func testMainWindowCandidateIgnoresUnidentifiedUtilityWindowBeforePendingMain() {
        let utilityWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        utilityWindow.title = "SafeMac AV"
        let pendingMainWindow = MainCapableTestWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        pendingMainWindow.title = "SafeMac AV"
        pendingMainWindow.identifier = NSUserInterfaceItemIdentifier(ClamAVApp.mainWindowID)

        XCTAssertTrue(
            MenuBarManager.mainWindowCandidate(
                in: [utilityWindow, pendingMainWindow]
            ) === pendingMainWindow
        )
    }

    func testApplicationDeclaresSingleInstanceMainWindowScene() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("ClamAV-GUI/App/ClamAVApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Window(Self.mainWindowTitle, id: Self.mainWindowID)"))
        XCTAssertFalse(source.contains("WindowGroup(Self.mainWindowTitle, id: Self.mainWindowID)"))
    }

    func testMainWindowCandidateIgnoresUnrelatedAndPanelWindows() {
        let unrelatedWindow = MainCapableTestWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        unrelatedWindow.identifier = NSUserInterfaceItemIdentifier("settings-window")
        let panel = MainCapableTestPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertNil(MenuBarManager.mainWindowCandidate(in: [unrelatedWindow]))
        XCTAssertNil(MenuBarManager.mainWindowCandidate(in: [panel]))
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

    func testHiddenDockScheduledLaunchKeepsInitialWindowForScheduledTask() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)

        let shouldSuppress = manager.prepareForLaunch(
            hidden: true,
            suppressInitialMainWindow: false
        )
        manager.suppressInitialMainWindow(if: shouldSuppress)

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.closeMainWindowCalls, 0)
    }

    func testApplicationDelegateUsesPersistedHiddenDockSettingOnInteractiveRestart() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = true
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] }
        )

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.closeMainWindowCalls, 1)
    }

    func testApplicationDelegatePromotesVisibleInteractiveLaunchToRegularPolicy() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = false
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] }
        )

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertFalse(manager.isDockHidden)
    }

    func testScheduledSignatureUpdateLaunchUsesAccessoryModeAndClosesMainWindow() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = false
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { ["--scheduled-signature-update"] }
        )

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.closeMainWindowCalls, 1)
    }

    func testApplicationDelegateRetainsDelayedScheduledUpdateUntilItFinishesThenExits() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        let updateStarted = expectation(description: "scheduled update started")
        let launchFinished = expectation(description: "scheduled launch finished")
        let gate = MenuBarAsyncGate()
        var finishCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-signature-update"] },
            runScheduledSignatureUpdate: {
                updateStarted.fulfill()
                await gate.wait()
            },
            finishScheduledLaunch: {
                finishCalls += 1
                launchFinished.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [updateStarted], timeout: 1)

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.closeMainWindowCalls, 1)
        XCTAssertEqual(finishCalls, 0)

        await gate.open()
        await fulfillment(of: [launchFinished], timeout: 1)
        XCTAssertEqual(finishCalls, 1)
    }

    func testScheduledUpdateAbortsWhenAccessoryIsolationCannotBeEstablished() async {
        let application = MenuBarApplicationMock()
        application.shouldAcceptPolicy = false
        let manager = MenuBarManager(application: application)
        var updateCalls = 0
        var finishCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-signature-update"] },
            runScheduledSignatureUpdate: { updateCalls += 1 },
            finishScheduledLaunch: { finishCalls += 1 }
        )

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.closeMainWindowCalls, 0)
        XCTAssertEqual(updateCalls, 0)
        XCTAssertEqual(finishCalls, 1)
    }

    func testScheduledSignatureUpdateModeAlwaysHidesDockEvenWhenUserPrefersDock() {
        var settings = AppSettings.default
        settings.hideFromDock = false

        XCTAssertTrue(LaunchMode.scheduledSignatureUpdate.hidesDock(settings: settings, isUITesting: false))
    }

    func testInteractiveAndScheduledScanModesRespectDockPreferenceAndUITesting() {
        var settings = AppSettings.default
        settings.hideFromDock = true

        XCTAssertTrue(LaunchMode.interactive.hidesDock(settings: settings, isUITesting: false))
        XCTAssertTrue(LaunchMode.scheduledScan(jobID: nil, paths: []).hidesDock(settings: settings, isUITesting: false))
        XCTAssertFalse(LaunchMode.interactive.hidesDock(settings: settings, isUITesting: true))
        XCTAssertFalse(LaunchMode.scheduledScan(jobID: nil, paths: []).hidesDock(settings: settings, isUITesting: true))
    }

    func testOnlyCanonicalInstalledAppMayAutomaticallyReconcileSignatureSchedule() {
        XCTAssertTrue(SignatureScheduleReconciliationPolicy.shouldReconcile(
            bundleURL: URL(fileURLWithPath: "/Applications/SafeMac AV.app"),
            isAutomatedTest: false
        ))

        let unsafePaths = [
            "/Users/test/Library/Developer/Xcode/DerivedData/SafeMac/Build/Products/Debug/SafeMac AV.app",
            "/private/var/folders/xx/AppTranslocation/123/d/SafeMac AV.app",
            "/Users/test/Downloads/SafeMac AV.app",
            "/Applications/SafeMac AV Backup.app"
        ]
        for path in unsafePaths {
            XCTAssertFalse(SignatureScheduleReconciliationPolicy.shouldReconcile(
                bundleURL: URL(fileURLWithPath: path),
                isAutomatedTest: false
            ), path)
        }
        XCTAssertFalse(SignatureScheduleReconciliationPolicy.shouldReconcile(
            bundleURL: URL(fileURLWithPath: "/Applications/SafeMac AV.app"),
            isAutomatedTest: true
        ))
    }
}

private final class MainCapableTestWindow: NSWindow {
    override var canBecomeMain: Bool { true }
}

private final class MainCapableTestPanel: NSPanel {
    override var canBecomeMain: Bool { true }
}

private actor MenuBarAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private enum MenuBarApplicationEvent: Equatable {
    case activateApplication
    case focusMainWindow
    case openWindow
}

@MainActor
private final class MenuBarApplicationMock: ApplicationActivationPolicyApplying {
    var shouldAcceptPolicy = true
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCalls: [Bool] = []
    private(set) var closeMainWindowCalls = 0
    var focusMainWindowResult = false
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

    func focusMainWindow() -> Bool {
        events.append(.focusMainWindow)
        return focusMainWindowResult
    }
}
