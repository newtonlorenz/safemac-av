import AppKit
import Combine
import XCTest
@testable import ClamAV_GUI

@MainActor
final class MenuBarManagerTests: XCTestCase {
    func testApplicationBundleStartsAsForegroundApplication() {
        XCTAssertNotEqual(
            Bundle(for: MenuBarApplicationDelegate.self)
                .object(forInfoDictionaryKey: "LSUIElement") as? Bool,
            true
        )
    }

    func testAppLifetimeOwnershipObservationRecoversFallbackMenuAfterHelperExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date()
        let ownership = BackgroundMenuBarOwnershipCoordinator(
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: root) },
            now: { now },
            startupGrace: 1,
            startsRecoveryTimer: false
        )
        let helperEnabled = CurrentValueSubject<Bool, Never>(true)
        ownership.observe(helperEnabled: helperEnabled.eraseToAnyPublisher())

        XCTAssertFalse(ownership.mainShouldPresentMenuBar)
        now = now.addingTimeInterval(2)
        ownership.recoverIfHelperIsAbsent()

        XCTAssertTrue(ownership.mainShouldPresentMenuBar)
    }

    func testHiddenInteractiveLaunchAnchorKeepsMainMenuWhileHelperOwnsLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helperLease = BackgroundWorkLease(name: "background-monitoring", baseURL: root)
        XCTAssertTrue(helperLease.acquire())
        defer { helperLease.release() }
        let ownership = BackgroundMenuBarOwnershipCoordinator(
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: root) },
            keepsMenuDuringInteractiveLaunch: true,
            startsRecoveryTimer: false
        )

        ownership.reconcile(helperEnabled: true)
        ownership.prepareForHelperOwnership()

        XCTAssertTrue(ownership.mainShouldPresentMenuBar)
    }

    func testCompletingHiddenInteractiveLaunchAnchorReturnsOwnershipToHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helperLease = BackgroundWorkLease(name: "background-monitoring", baseURL: root)
        XCTAssertTrue(helperLease.acquire())
        defer { helperLease.release() }
        let ownership = BackgroundMenuBarOwnershipCoordinator(
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: root) },
            keepsMenuDuringInteractiveLaunch: true,
            startsRecoveryTimer: false
        )
        ownership.reconcile(helperEnabled: true)

        ownership.completeInteractiveLaunchAnchor()

        XCTAssertFalse(ownership.mainShouldPresentMenuBar)
    }

    func testCompletingHiddenInteractiveLaunchAnchorClaimsFallbackWhenHelperIsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownership = BackgroundMenuBarOwnershipCoordinator(
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: root) },
            keepsMenuDuringInteractiveLaunch: true,
            startsRecoveryTimer: false
        )
        ownership.reconcile(helperEnabled: true)

        ownership.completeInteractiveLaunchAnchor()

        XCTAssertTrue(ownership.mainShouldPresentMenuBar)
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

    func testMainWindowRegistryResumesFactoryWaitersExactlyOnce() {
        let registry = MainWindowControllerRegistry()
        var waiterCalls = 0

        registry.whenFactoryAvailable { waiterCalls += 1 }
        XCTAssertEqual(waiterCalls, 0)

        registry.installFactory { MainWindowControllerMock() }
        XCTAssertEqual(waiterCalls, 1)

        registry.installFactory { MainWindowControllerMock() }
        XCTAssertEqual(waiterCalls, 1)

        registry.whenFactoryAvailable { waiterCalls += 1 }
        XCTAssertEqual(waiterCalls, 2)
    }

    func testMainWindowRegistryDefersColdRouteUntilRouterIsInstalled() {
        let registry = MainWindowControllerRegistry()
        var readyCalls = 0
        registry.whenRouterAvailable { readyCalls += 1 }

        XCTAssertFalse(registry.isRouterAvailable)
        XCTAssertFalse(registry.showMainWindow(selecting: .settings))
        XCTAssertEqual(readyCalls, 0)

        registry.installRouter { _ in }

        XCTAssertTrue(registry.isRouterAvailable)
        XCTAssertEqual(readyCalls, 1)
        XCTAssertTrue(registry.showMainWindow(selecting: .settings))
    }

    func testConcreteMainWindowControllerRetainsOneWindowAndExactSharedState() throws {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        let appState = AppState(startsInteractiveBackgroundServices: false)
        let controller = MainWindowController(
            appState: appState,
            menuBarManager: manager,
            preferredColorScheme: nil,
            scheduleActivation: { _ in }
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
        XCTAssertTrue(application.activationCalls.isEmpty)
        window.close()

        controller.showMainWindow(selecting: .dashboard)
        XCTAssertTrue(controller.windowController.window === window)
        XCTAssertEqual(appState.selectedTab, .dashboard)
        XCTAssertTrue(application.activationCalls.isEmpty)
        window.close()
    }

    func testMainWindowOrdersBeforeDeferredActivationAndCoalescesPendingFocus() {
        let presentationEvents = MainWindowPresentationRecorder()
        let application = MenuBarApplicationMock()
        application.presentationEvents = presentationEvents
        let manager = MenuBarManager(application: application)
        let appState = AppState(startsInteractiveBackgroundServices: false)
        let window = MainWindowOrderingWindow(
            selectedTab: { appState.selectedTab },
            presentationEvents: presentationEvents
        )
        let windowController = NSWindowController(window: window)
        var scheduledActivations: [MainWindowActivationOperation] = []
        let controller = MainWindowController(
            appState: appState,
            menuBarManager: manager,
            windowController: windowController,
            scheduleActivation: { scheduledActivations.append($0) }
        )

        controller.showMainWindow(selecting: .settings)
        controller.showMainWindow(selecting: .dashboard)

        XCTAssertEqual(appState.selectedTab, .dashboard)
        XCTAssertEqual(window.selectionsWhenOrdered, [.settings, .dashboard])
        XCTAssertEqual(
            presentationEvents.events,
            [.focus, .order, .focus, .order]
        )
        XCTAssertTrue(application.activationCalls.isEmpty)
        XCTAssertEqual(scheduledActivations.count, 1)

        scheduledActivations.removeFirst()()

        XCTAssertEqual(application.activationCalls, [true])
        XCTAssertEqual(presentationEvents.events.suffix(2), [.activate, .focus])

        window.close()
        controller.showMainWindow(selecting: .settings)

        XCTAssertTrue(controller.windowController.window === window)
        XCTAssertEqual(window.selectionsWhenOrdered.last, .settings)
        XCTAssertEqual(scheduledActivations.count, 1)
        XCTAssertEqual(application.activationCalls, [true])

        scheduledActivations.removeFirst()()

        XCTAssertEqual(application.activationCalls, [true, true])
        XCTAssertEqual(presentationEvents.events.suffix(2), [.activate, .focus])
        window.close()
    }

    func testMainWindowActivationRetriesOnlyOnceWhenApplicationRemainsInactive() {
        let presentationEvents = MainWindowPresentationRecorder()
        let application = MenuBarApplicationMock()
        application.presentationEvents = presentationEvents
        application.activationResults = [false, false]
        let manager = MenuBarManager(application: application)
        let appState = AppState(startsInteractiveBackgroundServices: false)
        let window = MainWindowOrderingWindow(
            selectedTab: { appState.selectedTab },
            presentationEvents: presentationEvents,
            allowsKeyStatus: false
        )
        var scheduledActivations: [MainWindowActivationOperation] = []
        let controller = MainWindowController(
            appState: appState,
            menuBarManager: manager,
            windowController: NSWindowController(window: window),
            scheduleActivation: { scheduledActivations.append($0) }
        )

        controller.showMainWindow(selecting: nil)
        XCTAssertEqual(scheduledActivations.count, 1)

        scheduledActivations.removeFirst()()
        XCTAssertEqual(scheduledActivations.count, 1)

        scheduledActivations.removeFirst()()
        XCTAssertTrue(scheduledActivations.isEmpty)
        XCTAssertEqual(application.activationCalls, [true, true])
        XCTAssertEqual(
            presentationEvents.events.suffix(4),
            [.activate, .focus, .activate, .focus]
        )
        window.close()
    }

    func testApplyingUnchangedDockVisibilityDoesNotPublishDuringViewUpdates() {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var publicationCount = 0
        let observation = manager.objectWillChange.sink {
            publicationCount += 1
        }

        XCTAssertTrue(manager.applyDockVisibility(hidden: false))

        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
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
        XCTAssertFalse(source.contains("applicationDelegate.configure"))
        XCTAssertTrue(source.contains("SoftwareUpdateManager(startsUpdater: false)"))
        XCTAssertTrue(source.contains("softwareUpdateManager.startUpdaterIfPossible()"))
        let installConfiguration = try XCTUnwrap(
            source.range(of: "ApplicationLaunchConfigurationRegistry.shared.install")
        )
        let installFactory = try XCTUnwrap(source.range(of: "MainWindowControllerRegistry.shared.installFactory"))
        XCTAssertLessThan(installConfiguration.lowerBound, installFactory.lowerBound)
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
            var waiterCalls = 0
            let delegate = MenuBarApplicationDelegate(
                manager: MenuBarManager(application: application),
                settingsProvider: { settings },
                argumentsProvider: { arguments },
                mainWindowControllerFactory: {
                    factoryCalls += 1
                    return MainWindowControllerMock()
                },
                waitForMainWindowControllerFactory: { _ in waiterCalls += 1 },
                runInitialApplicationLaunch: { _ in },
                runScheduledSignatureUpdate: {}
            )

            delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
            delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
            await Task.yield()

            XCTAssertEqual(factoryCalls, 0, arguments.description)
            XCTAssertEqual(waiterCalls, 0, arguments.description)
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

    func testVisibleLaunchDefersPresentationUntilControllerFactoryIsInstalled() async {
        let registry = MainWindowControllerRegistry()
        let controller = MainWindowControllerMock()
        let application = MenuBarApplicationMock()
        controller.onShow = { application.events.append(.showMainWindow) }
        let maintenanceRan = expectation(description: "maintenance ran after presentation")
        var factoryCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: MenuBarManager(application: application),
            settingsProvider: { .default },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            mainWindowControllerFactory: {
                factoryCalls += 1
                return registry.makeController()
            },
            waitForMainWindowControllerFactory: { continuation in
                registry.whenFactoryAvailable(continuation)
            },
            runInitialApplicationLaunch: { _ in
                application.events.append(.runInitialMaintenance)
                maintenanceRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()

        XCTAssertEqual(controller.selections.count, 0)
        XCTAssertEqual(application.events, [])

        registry.installFactory { controller }
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(controller.selections.count, 1)
        XCTAssertNil(controller.selections[0])
        XCTAssertEqual(
            application.events,
            [.showMainWindow, .nextMainRunLoopTurn, .runInitialMaintenance]
        )
    }

    func testScheduledScanDefersWorkUntilControllerFactoryIsInstalled() async {
        let registry = MainWindowControllerRegistry()
        let controller = MainWindowControllerMock()
        let application = MenuBarApplicationMock()
        controller.onShow = { application.events.append(.showMainWindow) }
        let scanRan = expectation(description: "scheduled scan ran after presentation")
        var receivedMode: LaunchMode?
        let delegate = MenuBarApplicationDelegate(
            manager: MenuBarManager(application: application),
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-scan", "--path", "/tmp/scheduled"] },
            nextMainRunLoopTurn: { application.events.append(.nextMainRunLoopTurn) },
            mainWindowControllerFactory: { registry.makeController() },
            waitForMainWindowControllerFactory: { registry.whenFactoryAvailable($0) },
            runInitialApplicationLaunch: { mode in
                receivedMode = mode
                application.events.append(.runInitialMaintenance)
                scanRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()
        XCTAssertNil(receivedMode)

        registry.installFactory { controller }
        await fulfillment(of: [scanRan], timeout: 1)

        XCTAssertEqual(receivedMode, .scheduledScan(
            jobID: nil,
            paths: [URL(fileURLWithPath: "/tmp/scheduled")]
        ))
        XCTAssertEqual(controller.selections.count, 1)
        XCTAssertEqual(
            application.events,
            [.showMainWindow, .nextMainRunLoopTurn, .runInitialMaintenance]
        )
    }

    func testHiddenInteractiveLaunchDefersMaintenanceUntilDelegateIsConfigured() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = true
        var placeholderCalls = 0
        var configuredCalls = 0
        var waiterCalls = 0
        let maintenanceRan = expectation(description: "configured maintenance ran")
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] },
            mainWindowControllerFactory: { MainWindowControllerMock() },
            waitForMainWindowControllerFactory: { _ in waiterCalls += 1 },
            runInitialApplicationLaunch: { _ in placeholderCalls += 1 },
            launchConfigurationRegistry: configurationRegistry
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()

        XCTAssertEqual(placeholderCalls, 0)
        XCTAssertEqual(configuredCalls, 0)
        XCTAssertEqual(waiterCalls, 0)

        let configuration = ApplicationLaunchConfiguration(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { [] },
            runInitialApplicationLaunch: { _ in
                configuredCalls += 1
                maintenanceRan.fulfill()
            },
            runActiveInteractiveMaintenance: { _ in },
            runScheduledSignatureUpdate: {}
        )
        configurationRegistry.install(configuration)
        configurationRegistry.install(configuration)
        await fulfillment(of: [maintenanceRan], timeout: 1)
        await Task.yield()

        XCTAssertEqual(placeholderCalls, 0)
        XCTAssertEqual(configuredCalls, 1)
        XCTAssertEqual(waiterCalls, 0)
    }

    func testScheduledSignatureUpdateDefersUntilDelegateIsConfigured() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var placeholderCalls = 0
        var configuredCalls = 0
        var finishCalls = 0
        var waiterCalls = 0
        let updateRan = expectation(description: "configured signature update ran")
        let launchFinished = expectation(description: "scheduled launch finished")
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-signature-update"] },
            mainWindowControllerFactory: { MainWindowControllerMock() },
            waitForMainWindowControllerFactory: { _ in waiterCalls += 1 },
            runScheduledSignatureUpdate: { placeholderCalls += 1 },
            finishScheduledLaunch: {
                finishCalls += 1
                launchFinished.fulfill()
            },
            launchConfigurationRegistry: configurationRegistry
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()

        XCTAssertEqual(placeholderCalls, 0)
        XCTAssertEqual(configuredCalls, 0)
        XCTAssertEqual(finishCalls, 0)
        XCTAssertEqual(waiterCalls, 0)

        let configuration = ApplicationLaunchConfiguration(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-signature-update"] },
            runInitialApplicationLaunch: { _ in },
            runActiveInteractiveMaintenance: { _ in },
            runScheduledSignatureUpdate: {
                configuredCalls += 1
                updateRan.fulfill()
            }
        )
        configurationRegistry.install(configuration)
        configurationRegistry.install(configuration)
        await fulfillment(of: [updateRan, launchFinished], timeout: 1)
        await Task.yield()

        XCTAssertEqual(placeholderCalls, 0)
        XCTAssertEqual(configuredCalls, 1)
        XCTAssertEqual(finishCalls, 1)
        XCTAssertEqual(waiterCalls, 0)
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

    func testReopenRunsActiveMaintenanceWhenFinderWakeNotificationIsUnavailable() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        let initialRan = expectation(description: "initial launch ran")
        let activeRan = expectation(description: "active maintenance ran")
        var activeCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { [] },
            nextMainRunLoopTurn: {},
            mainWindowControllerFactory: { MainWindowControllerMock() },
            runInitialApplicationLaunch: { _ in initialRan.fulfill() },
            runActiveInteractiveMaintenance: { _ in
                activeCalls += 1
                activeRan.fulfill()
            }
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [initialRan], timeout: 1)

        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        await fulfillment(of: [activeRan], timeout: 1)

        XCTAssertEqual(activeCalls, 1)
    }

    func testScheduledScanDelegatePresentsWindowThenRunsAppLifetimeScan() async {
        let application = MenuBarApplicationMock()
        let manager = MenuBarManager(application: application)
        var settings = AppSettings.default
        settings.hideFromDock = true
        let controller = MainWindowControllerMock()
        controller.onShow = { application.events.append(.showMainWindow) }
        let launchRan = expectation(description: "scheduled scan launch ran")
        var receivedMode: LaunchMode?
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { settings },
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
        XCTAssertEqual(application.requestedPolicies, [.regular])
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

    func testInteractiveModeRespectsDockPreferenceWhileScheduledScanStaysVisible() {
        var settings = AppSettings.default
        settings.hideFromDock = true

        XCTAssertTrue(LaunchMode.interactive.hidesDock(settings: settings, isUITesting: false))
        XCTAssertFalse(LaunchMode.scheduledScan(jobID: nil, paths: []).hidesDock(settings: settings, isUITesting: false))
        XCTAssertFalse(LaunchMode.interactive.hidesDock(settings: settings, isUITesting: true))
        XCTAssertFalse(LaunchMode.scheduledScan(jobID: nil, paths: []).hidesDock(settings: settings, isUITesting: true))
    }

    func testOnlyCanonicalInstalledAppMayAutomaticallyReconcileSignatureSchedule() {
        XCTAssertTrue(SignatureScheduleReconciliationPolicy.shouldReconcile(
            bundleURL: URL(fileURLWithPath: "/Applications/SafeMac AV.app"),
            isAutomatedTest: false
        ))
        // Bundle.main may carry a different `isDirectory` hint even when it
        // names the same installed bundle. That hint must not suppress the
        // security policy's canonical-path match.
        XCTAssertTrue(SignatureScheduleReconciliationPolicy.shouldReconcile(
            bundleURL: URL(fileURLWithPath: "/Applications/SafeMac AV.app", isDirectory: false),
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

    func testNonDirectoryURLHintStillQualifiesForLegacyLoginMigration() {
        let installedURL = URL(fileURLWithPath: "/Applications/SafeMac AV.app", isDirectory: false)

        XCTAssertEqual(installedURL.path, "/Applications/SafeMac AV.app")
        XCTAssertTrue(LaunchAtLoginManager.isCanonicalInstalledBundle(at: installedURL))
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

@MainActor
private final class MainWindowOrderingWindow: NSWindow {
    private let selectedTab: () -> NavigationTab
    private let presentationEvents: MainWindowPresentationRecorder
    private let allowsKeyStatus: Bool
    private(set) var selectionsWhenOrdered: [NavigationTab] = []
    private var reportsKeyWindow = false

    init(
        selectedTab: @escaping () -> NavigationTab,
        presentationEvents: MainWindowPresentationRecorder,
        allowsKeyStatus: Bool = true
    ) {
        self.selectedTab = selectedTab
        self.presentationEvents = presentationEvents
        self.allowsKeyStatus = allowsKeyStatus
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
    }

    override var isKeyWindow: Bool {
        reportsKeyWindow
    }

    override func orderFront(_ sender: Any?) {
        selectionsWhenOrdered.append(selectedTab())
        presentationEvents.events.append(.order)
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        presentationEvents.events.append(.focus)
        reportsKeyWindow = allowsKeyStatus
        super.makeKeyAndOrderFront(sender)
    }

    override func close() {
        reportsKeyWindow = false
        super.close()
    }
}

private enum MainWindowPresentationEvent: Equatable {
    case order
    case activate
    case focus
}

@MainActor
private final class MainWindowPresentationRecorder {
    var events: [MainWindowPresentationEvent] = []
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
    var activationResults: [Bool] = [true]
    var presentationEvents: MainWindowPresentationRecorder?
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCalls: [Bool] = []
    var events: [MenuBarApplicationEvent] = []
    private(set) var isActive = false

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        requestedPolicies.append(activationPolicy)
        return shouldAcceptPolicy
    }

    func activate(ignoringOtherApps: Bool) {
        activationCalls.append(ignoringOtherApps)
        events.append(.activateApplication)
    }

    func activateApplication() -> Bool {
        activationCalls.append(true)
        events.append(.activateApplication)
        presentationEvents?.events.append(.activate)
        let result = activationResults.isEmpty ? true : activationResults.removeFirst()
        isActive = result
        return result
    }

}
