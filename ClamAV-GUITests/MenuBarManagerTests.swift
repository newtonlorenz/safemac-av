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

    func testMainWindowRegistryFactoryIsLazyAndResettable() {
        let registry = MainWindowControllerRegistry()
        let first = MainWindowControllerMock()
        let second = MainWindowControllerMock()
        var firstFactoryCalls = 0
        var secondFactoryCalls = 0

        registry.installFactory {
            firstFactoryCalls += 1
            return first
        }
        XCTAssertEqual(firstFactoryCalls, 0)

        XCTAssertTrue(registry.makeController() === first)
        XCTAssertEqual(firstFactoryCalls, 1)

        registry.installFactory {
            secondFactoryCalls += 1
            return second
        }
        XCTAssertTrue(registry.makeController() === second)
        XCTAssertEqual(secondFactoryCalls, 1)
    }

    func testMainWindowRegistryRoutesMenuRequestsWithoutOwningController() {
        let registry = MainWindowControllerRegistry()
        var selections: [NavigationTab?] = []
        registry.installRouter { selections.append($0) }

        registry.showMainWindow(selecting: nil)
        registry.showMainWindow(selecting: .settings)

        XCTAssertEqual(selections.count, 2)
        XCTAssertNil(selections[0])
        XCTAssertEqual(selections[1], .settings)
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

    func testApplicationUsesMenuBarAsItsOnlySceneWithoutOpenWindowBridge() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("ClamAV-GUI/App/ClamAVApp.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Window(Self.mainWindowTitle, id: Self.mainWindowID)"))
        XCTAssertFalse(source.contains("WindowGroup(Self.mainWindowTitle, id: Self.mainWindowID)"))
        XCTAssertFalse(source.contains("MainWindowPresentationBridge"))
        XCTAssertFalse(source.contains("OpenWindowAction"))
        XCTAssertTrue(source.contains("MenuBarExtra"))
        XCTAssertFalse(source.contains("@StateObject private var initialLaunchHandler"))
    }

    func testVisibleInteractiveDelegateLazilyCreatesAndRetainsOneMainWindowController() async {
        let application = MenuBarApplicationMock()
        let controller = MainWindowControllerMock()
        var factoryCalls = 0
        let maintenanceRan = expectation(description: "maintenance ran")
        let delegate = MenuBarApplicationDelegate(
            manager: MenuBarManager(application: application),
            settingsProvider: { .default },
            argumentsProvider: { [] },
            mainWindowControllerFactory: {
                factoryCalls += 1
                return controller
            },
            runInitialApplicationLaunch: { _ in maintenanceRan.fulfill() }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)
        delegate.showMainWindow(selecting: .settings)

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(controller.selections.count, 2)
        XCTAssertNil(controller.selections[0])
        XCTAssertEqual(controller.selections[1], .settings)
    }

    func testHiddenInteractiveAndScheduledSignatureLaunchesDoNotCreateMainWindowController() async {
        for arguments in [[], ["--scheduled-signature-update"]] {
            let application = MenuBarApplicationMock()
            var settings = AppSettings.default
            settings.hideFromDock = true
            var factoryCalls = 0
            let delegate = MenuBarApplicationDelegate(
                manager: MenuBarManager(application: application),
                settingsProvider: { settings },
                argumentsProvider: { arguments },
                mainWindowControllerFactory: {
                    factoryCalls += 1
                    return MainWindowControllerMock()
                },
                runInitialApplicationLaunch: { _ in },
                runScheduledSignatureUpdate: {}
            )

            delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
            delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
            await Task.yield()

            XCTAssertEqual(factoryCalls, 0, arguments.description)
        }
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

    func testVisibleInteractiveDelegateFocusesExistingMainBeforeMaintenance() async {
        let application = MenuBarApplicationMock()
        application.focusMainWindowResults = [true]
        let manager = MenuBarManager(application: application)
        let maintenanceRan = expectation(description: "initial maintenance ran")
        var presentationRequests = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            requestMainWindowPresentation: {
                presentationRequests += 1
                application.events.append(.requestMainWindow)
            },
            runInitialApplicationLaunch: { _ in
                application.events.append(.runInitialMaintenance)
                maintenanceRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(presentationRequests, 0)
        XCTAssertEqual(
            application.events,
            [.nextMainRunLoopTurn, .activateApplication, .focusMainWindow,
             .nextMainRunLoopTurn, .runInitialMaintenance]
        )
    }

    func testVisibleInteractiveDelegateRequestsWindowThenFocusesBeforeMaintenance() async {
        let application = MenuBarApplicationMock()
        application.focusMainWindowResults = [false, false, true]
        let manager = MenuBarManager(application: application)
        let maintenanceRan = expectation(description: "initial maintenance ran")
        var presentationRequests = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            requestMainWindowPresentation: {
                presentationRequests += 1
                application.events.append(.requestMainWindow)
            },
            runInitialApplicationLaunch: { _ in
                application.events.append(.runInitialMaintenance)
                maintenanceRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(presentationRequests, 1)
        XCTAssertEqual(
            application.events,
            [.nextMainRunLoopTurn, .activateApplication, .focusMainWindow,
             .requestMainWindow, .nextMainRunLoopTurn, .activateApplication,
             .focusMainWindow, .nextMainRunLoopTurn, .activateApplication,
             .focusMainWindow, .runInitialMaintenance]
        )
    }

    func testHiddenInteractiveDelegateRunsMaintenanceWithoutPresentingWindow() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = true
        let maintenanceRan = expectation(description: "hidden maintenance ran")
        var presentationRequests = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            requestMainWindowPresentation: { presentationRequests += 1 },
            runInitialApplicationLaunch: { _ in maintenanceRan.fulfill() }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(presentationRequests, 0)
        XCTAssertEqual(application.activationCalls, [])
        XCTAssertEqual(application.events, [])
        XCTAssertEqual(application.closeMainWindowCalls, 1)
    }

    func testActiveMaintenanceWaitsForInitialInteractiveLaunchToFinish() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = true
        let initialStarted = expectation(description: "initial launch started")
        let activeRan = expectation(description: "active maintenance ran")
        let initialGate = MenuBarAsyncGate()
        var activeCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] },
            runInitialApplicationLaunch: { _ in
                initialStarted.fulfill()
                await initialGate.wait()
            },
            runActiveInteractiveMaintenance: { _ in
                activeCalls += 1
                activeRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [initialStarted], timeout: 1)
        delegate.applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))

        XCTAssertEqual(activeCalls, 0)
        await initialGate.open()
        await fulfillment(of: [activeRan], timeout: 1)
        XCTAssertEqual(activeCalls, 1)
    }

    func testScheduledScanDelegatePresentsWindowThenRunsAppLifetimeScan() async {
        let application = MenuBarApplicationMock()
        application.focusMainWindowResults = [false, true]
        let manager = MenuBarManager(application: application)
        let launchRan = expectation(description: "scheduled scan launch ran")
        var receivedMode: LaunchMode?
        var presentationRequests = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-scan", "--path", "/tmp/scheduled"] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            requestMainWindowPresentation: {
                presentationRequests += 1
                application.events.append(.requestMainWindow)
            },
            runInitialApplicationLaunch: { mode in
                receivedMode = mode
                application.events.append(.runInitialMaintenance)
                launchRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [launchRan], timeout: 1)

        XCTAssertEqual(receivedMode, .scheduledScan(jobID: nil, paths: [URL(fileURLWithPath: "/tmp/scheduled")]))
        XCTAssertEqual(presentationRequests, 1)
        XCTAssertEqual(application.activationCalls, [true, true])
        XCTAssertEqual(application.focusMainWindowResults.count, 0)
        XCTAssertEqual(
            application.events,
            [.nextMainRunLoopTurn, .activateApplication, .focusMainWindow,
             .requestMainWindow, .nextMainRunLoopTurn, .activateApplication,
             .focusMainWindow, .runInitialMaintenance]
        )
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
        XCTAssertEqual(application.activationCalls, [])
        XCTAssertFalse(application.events.contains(.focusMainWindow))
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

@MainActor
private final class MainWindowControllerMock: MainWindowControlling {
    private(set) var selections: [NavigationTab?] = []

    func showMainWindow(selecting selection: NavigationTab?) {
        selections.append(selection)
    }
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
    case nextMainRunLoopTurn
    case requestMainWindow
    case runInitialMaintenance
}

@MainActor
private final class MenuBarApplicationMock: ApplicationActivationPolicyApplying {
    var shouldAcceptPolicy = true
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCalls: [Bool] = []
    private(set) var closeMainWindowCalls = 0
    var focusMainWindowResult = false
    var focusMainWindowResults: [Bool] = []
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
        if !focusMainWindowResults.isEmpty {
            return focusMainWindowResults.removeFirst()
        }
        return focusMainWindowResult
    }
}
