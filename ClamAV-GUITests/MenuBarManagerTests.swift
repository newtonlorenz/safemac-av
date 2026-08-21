import AppKit
import Combine
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

    func testConcreteMainWindowControllerRetainsOneWindowAndExactSharedState() throws {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        let appState = AppState(startsInteractiveBackgroundServices: false)
        let controller = MainWindowController(
            appState: appState,
            menuBarManager: manager,
            preferredColorScheme: nil
        )
        let window = try XCTUnwrap(controller.windowController.window)

        XCTAssertTrue(controller.appState === appState)
        XCTAssertTrue(controller.menuBarManager === manager)
        XCTAssertEqual(window.identifier?.rawValue, ClamAVApp.mainWindowID)
        XCTAssertEqual(window.title, ClamAVApp.mainWindowTitle)
        XCTAssertEqual(window.frame.size, NSSize(width: 1_060, height: 720))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 800, height: 600))
        XCTAssertEqual(window.isReleasedWhenClosed, false)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))

        controller.showMainWindow(selecting: .settings)
        XCTAssertEqual(appState.selectedTab, .settings)
        XCTAssertEqual(application.activationCalls, [true])
        window.close()

        controller.showMainWindow(selecting: .dashboard)
        XCTAssertTrue(controller.windowController.window === window)
        XCTAssertEqual(appState.selectedTab, .dashboard)
        XCTAssertEqual(application.activationCalls, [true, true])
        window.close()
    }

    func testDockVisibilityObservationRunsWindowlessAndReinstallCancelsOldPublisher() {
        let firstApplication = MenuBarApplicationMock()
        let secondApplication = MenuBarApplicationMock()
        let firstSettings = CurrentValueSubject<AppSettings, Never>(.default)
        let secondSettings = CurrentValueSubject<AppSettings, Never>(.default)
        let lifecycle = DockVisibilityLifecycle()

        lifecycle.install(
            settings: firstSettings.eraseToAnyPublisher(),
            launchMode: .interactive,
            isUITesting: false,
            manager: MenuBarManager(application: firstApplication)
        )
        var hiddenSettings = AppSettings.default
        hiddenSettings.hideFromDock = true
        firstSettings.send(hiddenSettings)
        XCTAssertEqual(firstApplication.requestedPolicies, [.accessory])

        lifecycle.install(
            settings: secondSettings.eraseToAnyPublisher(),
            launchMode: .interactive,
            isUITesting: false,
            manager: MenuBarManager(application: secondApplication)
        )
        firstSettings.send(.default)
        secondSettings.send(hiddenSettings)

        XCTAssertEqual(firstApplication.requestedPolicies, [.accessory])
        XCTAssertEqual(secondApplication.requestedPolicies, [.accessory])
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

    func testHiddenInteractiveMenuRequestLazilyCreatesControllerAfterLaunch() async {
        let application = MenuBarApplicationMock()
        var settings = AppSettings.default
        settings.hideFromDock = true
        let controller = MainWindowControllerMock()
        var factoryCalls = 0
        let maintenanceRan = expectation(description: "hidden maintenance ran")
        let delegate = MenuBarApplicationDelegate(
            manager: MenuBarManager(application: application),
            settingsProvider: { settings },
            argumentsProvider: { [] },
            mainWindowControllerFactory: {
                factoryCalls += 1
                return controller
            },
            runInitialApplicationLaunch: { _ in maintenanceRan.fulfill() }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)
        XCTAssertEqual(factoryCalls, 0)

        XCTAssertTrue(delegate.showMainWindow(selecting: .settings))
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(controller.selections, [.settings])
    }

    func testVisibleLaunchWithMissingControllerFactoryFailsClosedWithoutMaintenance() async {
        var maintenanceCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: MenuBarManager(application: MenuBarApplicationMock()),
            settingsProvider: { .default },
            argumentsProvider: { [] },
            mainWindowControllerFactory: { nil },
            runInitialApplicationLaunch: { _ in maintenanceCalls += 1 }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()

        XCTAssertEqual(maintenanceCalls, 0)
        XCTAssertFalse(delegate.showMainWindow(selecting: nil))
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

    func testVisibleInteractiveDelegatePresentsBeforeMaintenance() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        let controller = MainWindowControllerMock()
        controller.onShow = { application.events.append(.showMainWindow) }
        let maintenanceRan = expectation(description: "initial maintenance ran")
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            mainWindowControllerFactory: { controller },
            runInitialApplicationLaunch: { _ in
                application.events.append(.runInitialMaintenance)
                maintenanceRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(
            application.events,
            [.showMainWindow, .nextMainRunLoopTurn, .runInitialMaintenance]
        )
    }

    func testVisibleInteractiveDelegateHandlesDuplicateDidFinishOnlyOnce() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        let controller = MainWindowControllerMock()
        let maintenanceRan = expectation(description: "initial maintenance ran")
        var factoryCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: {},
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

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(controller.selections.count, 1)
    }

    func testHiddenInteractiveDelegateRunsMaintenanceWithoutPresentingWindow() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = true
        let maintenanceRan = expectation(description: "hidden maintenance ran")
        var factoryCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            mainWindowControllerFactory: {
                factoryCalls += 1
                return MainWindowControllerMock()
            },
            runInitialApplicationLaunch: { _ in maintenanceRan.fulfill() }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(application.activationCalls, [])
        XCTAssertEqual(application.events, [])
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
        let manager = MenuBarManager(application: application)
        let controller = MainWindowControllerMock()
        controller.onShow = { application.events.append(.showMainWindow) }
        let launchRan = expectation(description: "scheduled scan launch ran")
        var receivedMode: LaunchMode?
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-scan", "--path", "/tmp/scheduled"] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            mainWindowControllerFactory: { controller },
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
        XCTAssertEqual(
            application.events,
            [.showMainWindow, .nextMainRunLoopTurn, .runInitialMaintenance]
        )
    }

    func testScheduledSignatureUpdateLaunchUsesAccessoryModeWithoutCreatingMainWindow() async {
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
        XCTAssertEqual(application.activationCalls, [])
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

@MainActor
private final class MainWindowControllerMock: MainWindowControlling {
    private(set) var selections: [NavigationTab?] = []
    var onShow: (() -> Void)?

    func showMainWindow(selecting selection: NavigationTab?) {
        selections.append(selection)
        onShow?()
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
    case nextMainRunLoopTurn
    case showMainWindow
    case runInitialMaintenance
}

@MainActor
private final class MenuBarApplicationMock: ApplicationActivationPolicyApplying {
    var shouldAcceptPolicy = true
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCalls: [Bool] = []
    var events: [MenuBarApplicationEvent] = []

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        requestedPolicies.append(activationPolicy)
        return shouldAcceptPolicy
    }

    func activate(ignoringOtherApps: Bool) {
        activationCalls.append(ignoringOtherApps)
        events.append(.activateApplication)
    }

}
