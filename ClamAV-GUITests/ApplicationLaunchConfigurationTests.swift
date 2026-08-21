import AppKit
import XCTest
@testable import ClamAV_GUI

@MainActor
final class ApplicationLaunchConfigurationTests: XCTestCase {
    func testRegistryCoalescesDuplicateSubscriptionsAndInstallsExactlyOnce() {
        let registry = ApplicationLaunchConfigurationRegistry()
        let owner = LaunchConfigurationOwner()
        let lateOwner = LaunchConfigurationOwner()
        var ownerCalls = 0
        var lateOwnerCalls = 0
        let configuration = makeConfiguration()

        registry.whenAvailable(for: owner) { _, _ in ownerCalls += 1 }
        registry.whenAvailable(for: owner) { _, _ in ownerCalls += 1 }
        registry.install(configuration)
        registry.install(configuration)

        registry.whenAvailable(for: lateOwner) { _, _ in lateOwnerCalls += 1 }
        registry.whenAvailable(for: lateOwner) { _, _ in lateOwnerCalls += 1 }

        XCTAssertEqual(ownerCalls, 1)
        XCTAssertEqual(lateOwnerCalls, 1)
    }

    func testRegistryDoesNotRetainReleasedSubscriber() {
        let registry = ApplicationLaunchConfigurationRegistry()
        weak var releasedOwner: LaunchConfigurationOwner?
        var calls = 0

        autoreleasepool {
            let owner = LaunchConfigurationOwner()
            releasedOwner = owner
            registry.whenAvailable(for: owner) { _, _ in calls += 1 }
        }

        XCTAssertNil(releasedOwner)
        registry.install(makeConfiguration())
        XCTAssertEqual(calls, 0)
    }

    func testRegistryResetClearsConfigurationAndSubscriptions() {
        let registry = ApplicationLaunchConfigurationRegistry()
        let firstOwner = LaunchConfigurationOwner()
        let secondOwner = LaunchConfigurationOwner()
        var firstCalls = 0
        var secondCalls = 0

        registry.whenAvailable(for: firstOwner) { _, _ in firstCalls += 1 }
        registry.install(makeConfiguration())
        registry.resetForTesting()
        registry.whenAvailable(for: secondOwner) { _, _ in secondCalls += 1 }

        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 0)

        registry.install(makeConfiguration())
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 1)
    }

    func testDifferentAdaptorIdentityResumesVisibleCallbackDelegateAfterConfigThenFactory() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let controllerRegistry = MainWindowControllerRegistry()
        let application = LaunchConfigurationApplicationMock()
        let manager = MenuBarManager(application: application)
        let controller = LaunchConfigurationMainWindowControllerMock()
        controller.onShow = { application.events.append("show") }
        let maintenanceRan = expectation(description: "configured maintenance ran")
        var placeholderCalls = 0

        let callbackDelegate = makeUnconfiguredDelegate(
            manager: manager,
            configurationRegistry: configurationRegistry,
            controllerRegistry: controllerRegistry,
            application: application,
            placeholderInitialLaunch: { placeholderCalls += 1 }
        )
        let differentAdaptorDelegate = makeUnconfiguredDelegate(
            manager: manager,
            configurationRegistry: configurationRegistry,
            controllerRegistry: controllerRegistry,
            application: application
        )
        XCTAssertFalse(callbackDelegate === differentAdaptorDelegate)

        callbackDelegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        callbackDelegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        callbackDelegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(application.requestedPolicies, [])
        XCTAssertEqual(application.events, [])
        XCTAssertEqual(placeholderCalls, 0)

        configurationRegistry.install(makeConfiguration(
            manager: manager,
            runInitialApplicationLaunch: { _ in
                application.events.append("maintenance")
                maintenanceRan.fulfill()
            }
        ))

        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(application.events, [])
        controllerRegistry.installFactory { controller }
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(controller.selections.count, 1)
        XCTAssertNil(controller.selections[0])
        XCTAssertEqual(application.events, ["show", "next-main-turn", "maintenance"])
        XCTAssertEqual(placeholderCalls, 0)
    }

    func testConfigurationInstalledBeforeDelegateRunsVisibleLaunch() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let controllerRegistry = MainWindowControllerRegistry()
        let application = LaunchConfigurationApplicationMock()
        let manager = MenuBarManager(application: application)
        let controller = LaunchConfigurationMainWindowControllerMock()
        controller.onShow = { application.events.append("show") }
        controllerRegistry.installFactory { controller }
        let maintenanceRan = expectation(description: "maintenance ran")
        configurationRegistry.install(makeConfiguration(
            manager: manager,
            runInitialApplicationLaunch: { _ in
                application.events.append("maintenance")
                maintenanceRan.fulfill()
            }
        ))

        let delegate = makeUnconfiguredDelegate(
            manager: manager,
            configurationRegistry: configurationRegistry,
            controllerRegistry: controllerRegistry,
            application: application
        )
        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        await fulfillment(of: [maintenanceRan], timeout: 1)

        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(controller.selections.count, 1)
        XCTAssertEqual(application.events, ["show", "next-main-turn", "maintenance"])
    }

    func testHiddenInteractiveWaitsOnlyForConfigurationAndRunsMaintenanceOnce() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let application = LaunchConfigurationApplicationMock()
        let manager = MenuBarManager(application: application)
        var factoryCalls = 0
        var factoryWaitCalls = 0
        var maintenanceCalls = 0
        var placeholderCalls = 0
        var hiddenSettings = AppSettings.default
        hiddenSettings.hideFromDock = true
        let maintenanceRan = expectation(description: "hidden maintenance ran")
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--placeholder"] },
            mainWindowControllerFactory: {
                factoryCalls += 1
                return LaunchConfigurationMainWindowControllerMock()
            },
            waitForMainWindowControllerFactory: { _ in factoryWaitCalls += 1 },
            runInitialApplicationLaunch: { _ in placeholderCalls += 1 },
            launchConfigurationRegistry: configurationRegistry
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(application.requestedPolicies, [])

        let configuration = makeConfiguration(
            manager: manager,
            settings: hiddenSettings,
            runInitialApplicationLaunch: { _ in
                maintenanceCalls += 1
                maintenanceRan.fulfill()
            }
        )
        configurationRegistry.install(configuration)
        configurationRegistry.install(configuration)
        await fulfillment(of: [maintenanceRan], timeout: 1)
        await Task.yield()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(maintenanceCalls, 1)
        XCTAssertEqual(placeholderCalls, 0)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(factoryWaitCalls, 0)
    }

    func testScheduledScanWaitsForConfigurationThenPresentsBeforeScanning() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let controllerRegistry = MainWindowControllerRegistry()
        let application = LaunchConfigurationApplicationMock()
        let manager = MenuBarManager(application: application)
        let controller = LaunchConfigurationMainWindowControllerMock()
        controller.onShow = { application.events.append("show") }
        let scanRan = expectation(description: "scheduled scan ran")
        var receivedMode: LaunchMode?
        let delegate = makeUnconfiguredDelegate(
            manager: manager,
            configurationRegistry: configurationRegistry,
            controllerRegistry: controllerRegistry,
            application: application
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        configurationRegistry.install(makeConfiguration(
            manager: manager,
            arguments: ["--scheduled-scan", "--path", "/tmp/scheduled"],
            runInitialApplicationLaunch: { mode in
                receivedMode = mode
                application.events.append("scan")
                scanRan.fulfill()
            }
        ))
        XCTAssertEqual(application.events, [])

        controllerRegistry.installFactory { controller }
        await fulfillment(of: [scanRan], timeout: 1)

        XCTAssertEqual(receivedMode, .scheduledScan(
            jobID: nil,
            paths: [URL(fileURLWithPath: "/tmp/scheduled")]
        ))
        XCTAssertEqual(controller.selections.count, 1)
        XCTAssertEqual(application.events, ["show", "next-main-turn", "scan"])
    }

    func testScheduledSignatureUpdateUsesConfiguredModeAndStaysHeadless() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let application = LaunchConfigurationApplicationMock()
        let manager = MenuBarManager(application: application)
        var updateCalls = 0
        var finishCalls = 0
        var factoryCalls = 0
        var factoryWaitCalls = 0
        let updateRan = expectation(description: "scheduled update ran")
        let launchFinished = expectation(description: "scheduled launch finished")
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { [] },
            mainWindowControllerFactory: {
                factoryCalls += 1
                return LaunchConfigurationMainWindowControllerMock()
            },
            waitForMainWindowControllerFactory: { _ in factoryWaitCalls += 1 },
            finishScheduledLaunch: {
                finishCalls += 1
                launchFinished.fulfill()
            },
            launchConfigurationRegistry: configurationRegistry
        )

        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(application.requestedPolicies, [])

        let configuration = makeConfiguration(
            manager: manager,
            arguments: ["--scheduled-signature-update"],
            runScheduledSignatureUpdate: {
                updateCalls += 1
                updateRan.fulfill()
            }
        )
        configurationRegistry.install(configuration)
        configurationRegistry.install(configuration)
        await fulfillment(of: [updateRan, launchFinished], timeout: 1)
        await Task.yield()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(updateCalls, 1)
        XCTAssertEqual(finishCalls, 1)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(factoryWaitCalls, 0)
        XCTAssertEqual(application.events, [])
    }

    func testRejectedScheduledSignatureIsolationFinishesOnceAndIgnoresReplacementConfiguration() async {
        let configurationRegistry = ApplicationLaunchConfigurationRegistry()
        let application = LaunchConfigurationApplicationMock()
        application.shouldAcceptPolicy = false
        let manager = MenuBarManager(application: application)
        var finishCalls = 0
        var updateCalls = 0
        let delegate = MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--scheduled-signature-update"] },
            runScheduledSignatureUpdate: { updateCalls += 1 },
            finishScheduledLaunch: { finishCalls += 1 },
            launchConfigurationRegistry: configurationRegistry
        )

        let configuration = makeConfiguration(
            manager: manager,
            arguments: ["--scheduled-signature-update"],
            runScheduledSignatureUpdate: { updateCalls += 1 }
        )
        configurationRegistry.install(configuration)
        delegate.applicationWillFinishLaunching(.init(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        configurationRegistry.install(configuration)
        await Task.yield()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(updateCalls, 0)
        XCTAssertEqual(finishCalls, 1)
    }

    func testAppCompositionUsesRegistryInsteadOfDirectAdaptorConfiguration() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClamAV-GUI/App/ClamAVApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("applicationDelegate.configure"))
        XCTAssertTrue(source.contains("ApplicationLaunchConfigurationRegistry.shared.install"))
    }

    private func makeUnconfiguredDelegate(
        manager: MenuBarManager,
        configurationRegistry: ApplicationLaunchConfigurationRegistry,
        controllerRegistry: MainWindowControllerRegistry,
        application: LaunchConfigurationApplicationMock,
        placeholderInitialLaunch: @escaping () -> Void = {}
    ) -> MenuBarApplicationDelegate {
        MenuBarApplicationDelegate(
            manager: manager,
            settingsProvider: { .default },
            argumentsProvider: { ["--placeholder"] },
            nextMainRunLoopTurn: { application.events.append("next-main-turn") },
            mainWindowControllerFactory: { controllerRegistry.makeController() },
            waitForMainWindowControllerFactory: { controllerRegistry.whenFactoryAvailable($0) },
            runInitialApplicationLaunch: { _ in placeholderInitialLaunch() },
            launchConfigurationRegistry: configurationRegistry
        )
    }

    private func makeConfiguration(
        manager: MenuBarManager? = nil,
        settings: AppSettings = .default,
        arguments: [String] = [],
        runInitialApplicationLaunch: @escaping (LaunchMode) async -> Void = { _ in },
        runActiveInteractiveMaintenance: @escaping (LaunchMode) async -> Void = { _ in },
        runScheduledSignatureUpdate: @escaping () async -> Void = {}
    ) -> ApplicationLaunchConfiguration {
        let manager = manager ?? MenuBarManager(application: LaunchConfigurationApplicationMock())
        return ApplicationLaunchConfiguration(
            manager: manager,
            settingsProvider: { settings },
            argumentsProvider: { arguments },
            runInitialApplicationLaunch: runInitialApplicationLaunch,
            runActiveInteractiveMaintenance: runActiveInteractiveMaintenance,
            runScheduledSignatureUpdate: runScheduledSignatureUpdate
        )
    }
}

private final class LaunchConfigurationOwner {}

@MainActor
private final class LaunchConfigurationApplicationMock: ApplicationActivationPolicyApplying {
    var shouldAcceptPolicy = true
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCalls: [Bool] = []
    var events: [String] = []

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        requestedPolicies.append(activationPolicy)
        return shouldAcceptPolicy
    }

    func activate(ignoringOtherApps: Bool) {
        activationCalls.append(ignoringOtherApps)
    }
}

@MainActor
private final class LaunchConfigurationMainWindowControllerMock: MainWindowControlling {
    private(set) var selections: [NavigationTab?] = []
    var onShow: (() -> Void)?

    func showMainWindow(selecting selection: NavigationTab?) {
        selections.append(selection)
        onShow?()
    }
}
