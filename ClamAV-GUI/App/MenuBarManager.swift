import AppKit
import Combine

@MainActor
final class DockVisibilityLifecycle {
    static let shared = DockVisibilityLifecycle()

    private var observation: AnyCancellable?

    func install(
        settings: AnyPublisher<AppSettings, Never>,
        launchMode: LaunchMode,
        isUITesting: Bool,
        manager: MenuBarManager
    ) {
        observation?.cancel()
        observation = settings
            .dropFirst()
            .map { launchMode.hidesDock(settings: $0, isUITesting: isUITesting) }
            .removeDuplicates()
            .sink { hidden in
                manager.applyDockVisibility(hidden: hidden)
            }
    }
}

@MainActor
protocol ApplicationActivationPolicyApplying: AnyObject {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps: Bool)
    var isActive: Bool { get }
    @discardableResult
    func activateApplication() -> Bool
}

extension ApplicationActivationPolicyApplying {
    var isActive: Bool { true }

    @discardableResult
    func activateApplication() -> Bool {
        activate(ignoringOtherApps: true)
        return true
    }
}

extension NSApplication: ApplicationActivationPolicyApplying {
    @discardableResult
    func activateApplication() -> Bool {
        activate(ignoringOtherApps: true)
        let didActivateRunningApplication = NSRunningApplication.current.activate(
            options: [.activateAllWindows, .activateIgnoringOtherApps]
        )
        return isActive || didActivateRunningApplication
    }
}

@MainActor
final class MenuBarManager: ObservableObject {
    @Published private(set) var isDockHidden = false

    private let application: ApplicationActivationPolicyApplying

    init(application: ApplicationActivationPolicyApplying? = nil) {
        self.application = application ?? NSApplication.shared
    }

    @discardableResult
    func applyDockVisibility(hidden: Bool) -> Bool {
        let activationPolicy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard application.setActivationPolicy(activationPolicy) else { return false }
        if isDockHidden != hidden {
            isDockHidden = hidden
        }
        return true
    }

    @discardableResult
    func activateApplication() -> Bool {
        application.activateApplication()
    }

    var isApplicationActive: Bool {
        application.isActive
    }
}

@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private var providedManager: MenuBarManager?
    private var settingsProvider: () -> AppSettings
    private var argumentsProvider: () -> [String]
    private var nextMainRunLoopTurn: () async -> Void
    private var mainWindowControllerFactory: () -> MainWindowControlling?
    private var waitForMainWindowControllerFactory: (@escaping () -> Void) -> Void
    private var runInitialApplicationLaunch: (LaunchMode) async -> Void
    private var runActiveInteractiveMaintenance: (LaunchMode) async -> Void
    private var runScheduledSignatureUpdate: () async -> Void
    private var finishScheduledLaunch: () -> Void
    private var launchConfigurationRegistry: ApplicationLaunchConfigurationRegistry?
    private var mainWindowController: MainWindowControlling?
    private var isWaitingForMainWindowControllerFactory = false
    private var hasPendingMainWindowPresentation = false
    private var pendingMainWindowSelection: NavigationTab?
    private var shouldStartInitialLaunchAfterPresentation = false
    private var didStartInitialApplicationLaunch = false
    private var isConfiguredForLaunch: Bool
    private var didReceiveWillFinishLaunching = false
    private var didPrepareApplicationLaunch = false
    private var launchMode: LaunchMode = .interactive
    private var canRunScheduledSignatureUpdate = false
    private var shouldPresentMainWindowAtLaunch = false
    private var didHandleApplicationLaunch = false
    private var didContinueApplicationLaunch = false
    private var didScheduleApplicationSceneReadinessFallback = false
    private var didCompleteInitialInteractiveLaunch = false
    private var pendingActiveMaintenance = false
    private var applicationLaunchTask: Task<Void, Never>?
    private var activeMaintenanceTask: Task<Void, Never>?
    private var scheduledLaunchTask: Task<Void, Never>?

    override init() {
        providedManager = nil
        settingsProvider = { ConfigManager().loadSettings() }
        argumentsProvider = { CommandLine.arguments }
        nextMainRunLoopTurn = { await Self.waitForNextMainRunLoopTurn() }
        mainWindowControllerFactory = {
            MainWindowControllerRegistry.shared.makeController()
        }
        waitForMainWindowControllerFactory = {
            MainWindowControllerRegistry.shared.whenFactoryAvailable($0)
        }
        runInitialApplicationLaunch = { _ in }
        runActiveInteractiveMaintenance = { _ in }
        runScheduledSignatureUpdate = {}
        finishScheduledLaunch = {
            NSApplication.shared.terminate(nil)
        }
        launchConfigurationRegistry = ApplicationLaunchConfigurationRegistry.shared
        isConfiguredForLaunch = false
        super.init()
        subscribeToLaunchConfiguration(ApplicationLaunchConfigurationRegistry.shared)
    }

    init(
        manager: MenuBarManager,
        settingsProvider: @escaping () -> AppSettings,
        argumentsProvider: @escaping () -> [String],
        nextMainRunLoopTurn: @escaping () async -> Void = {
            await MenuBarApplicationDelegate.waitForNextMainRunLoopTurn()
        },
        mainWindowControllerFactory: @escaping () -> MainWindowControlling? = { nil },
        waitForMainWindowControllerFactory: @escaping (@escaping () -> Void) -> Void = { _ in },
        runInitialApplicationLaunch: @escaping (LaunchMode) async -> Void = { _ in },
        runActiveInteractiveMaintenance: @escaping (LaunchMode) async -> Void = { _ in },
        runScheduledSignatureUpdate: @escaping () async -> Void = {},
        finishScheduledLaunch: @escaping () -> Void = {},
        startsConfigured: Bool = true,
        launchConfigurationRegistry: ApplicationLaunchConfigurationRegistry? = nil
    ) {
        providedManager = manager
        self.settingsProvider = settingsProvider
        self.argumentsProvider = argumentsProvider
        self.nextMainRunLoopTurn = nextMainRunLoopTurn
        self.mainWindowControllerFactory = mainWindowControllerFactory
        self.waitForMainWindowControllerFactory = waitForMainWindowControllerFactory
        self.runInitialApplicationLaunch = runInitialApplicationLaunch
        self.runActiveInteractiveMaintenance = runActiveInteractiveMaintenance
        self.runScheduledSignatureUpdate = runScheduledSignatureUpdate
        self.finishScheduledLaunch = finishScheduledLaunch
        self.launchConfigurationRegistry = launchConfigurationRegistry
        isConfiguredForLaunch = startsConfigured && launchConfigurationRegistry == nil
        super.init()
        if let launchConfigurationRegistry {
            subscribeToLaunchConfiguration(launchConfigurationRegistry)
        }
    }

    private func subscribeToLaunchConfiguration(
        _ registry: ApplicationLaunchConfigurationRegistry
    ) {
        registry.whenAvailable(for: self) { delegate, configuration in
            delegate.applyLaunchConfiguration(configuration)
        }
    }

    private func applyLaunchConfiguration(_ configuration: ApplicationLaunchConfiguration) {
        providedManager = configuration.manager
        settingsProvider = configuration.settingsProvider
        argumentsProvider = configuration.argumentsProvider
        runInitialApplicationLaunch = configuration.runInitialApplicationLaunch
        runActiveInteractiveMaintenance = configuration.runActiveInteractiveMaintenance
        runScheduledSignatureUpdate = configuration.runScheduledSignatureUpdate
        isConfiguredForLaunch = true
        scheduleApplicationSceneReadinessFallback()
        prepareApplicationLaunchIfReady()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        didReceiveWillFinishLaunching = true
        prepareApplicationLaunchIfReady()
    }

    private func prepareApplicationLaunchIfReady() {
        guard isConfiguredForLaunch, didReceiveWillFinishLaunching else { return }
        guard !didPrepareApplicationLaunch else { return }
        didPrepareApplicationLaunch = true
        let manager = providedManager ?? MenuBarManager()
        let settings = settingsProvider()
        let arguments = argumentsProvider()
        let mode = LaunchModeParser.parse(arguments: arguments)
        launchMode = mode
        let hidesDock = mode.hidesDock(
            settings: settings,
            isUITesting: arguments.contains("--ui-testing")
        )
        switch mode {
        case .interactive:
            shouldPresentMainWindowAtLaunch = !hidesDock
        case .scheduledScan:
            shouldPresentMainWindowAtLaunch = true
        case .scheduledSignatureUpdate:
            shouldPresentMainWindowAtLaunch = false
        }
        let didApplyDockPolicy = manager.applyDockVisibility(hidden: hidesDock)
        canRunScheduledSignatureUpdate = mode != .scheduledSignatureUpdate
            || (hidesDock && didApplyDockPolicy)
        MainWindowControllerRegistry.shared.installRouter { [weak self] selection in
            self?.showMainWindow(selecting: selection)
        }
        MainWindowControllerRegistry.shared.installCloseRouter { [weak self] in
            self?.closeMainWindow()
        }
        continueApplicationLaunchIfReady()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didHandleApplicationLaunch else { return }
        didHandleApplicationLaunch = true
        continueApplicationLaunchIfReady()
    }

    func applicationSceneDidBecomeReady() {
        if !didReceiveWillFinishLaunching {
            didReceiveWillFinishLaunching = true
            prepareApplicationLaunchIfReady()
        }
        if !didHandleApplicationLaunch {
            didHandleApplicationLaunch = true
        }
        continueApplicationLaunchIfReady()
    }

    func scheduleApplicationSceneReadinessFallback() {
        guard !didScheduleApplicationSceneReadinessFallback else { return }
        didScheduleApplicationSceneReadinessFallback = true
        Task { [weak self] in
            await Self.waitForNextMainRunLoopTurn()
            self?.applicationSceneDidBecomeReady()
        }
    }

    private func continueApplicationLaunchIfReady() {
        guard didHandleApplicationLaunch, didPrepareApplicationLaunch else { return }
        guard !didContinueApplicationLaunch else { return }
        if let launchConfigurationRegistry {
            guard launchConfigurationRegistry.claimLaunchContinuation(for: self) else { return }
        }
        didContinueApplicationLaunch = true
        if launchMode == .scheduledSignatureUpdate, !canRunScheduledSignatureUpdate {
            finishScheduledLaunch()
            return
        }
        continueApplicationLaunch()
    }

    private func continueApplicationLaunch() {
        if launchMode == .scheduledSignatureUpdate {
            scheduledLaunchTask = Task { [runScheduledSignatureUpdate, finishScheduledLaunch] in
                await runScheduledSignatureUpdate()
                finishScheduledLaunch()
            }
            return
        }

        if shouldPresentMainWindowAtLaunch {
            shouldStartInitialLaunchAfterPresentation = true
            if showMainWindow(selecting: nil) {
                shouldStartInitialLaunchAfterPresentation = false
                startInitialApplicationLaunch()
            }
            return
        }

        startInitialApplicationLaunch()
    }

    private func startInitialApplicationLaunch() {
        guard !didStartInitialApplicationLaunch else { return }
        didStartInitialApplicationLaunch = true
        applicationLaunchTask = Task { [weak self] in
            guard let self else { return }
            await self.runInitialLaunch()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        requestActiveInteractiveMaintenance()
    }

    private func requestActiveInteractiveMaintenance() {
        guard launchMode.isInteractive else { return }
        guard didCompleteInitialInteractiveLaunch else {
            pendingActiveMaintenance = true
            return
        }
        startActiveMaintenance()
    }

    private func runInitialLaunch() async {
        switch launchMode {
        case .interactive:
            if shouldPresentMainWindowAtLaunch {
                await nextMainRunLoopTurn()
            }
            await runInitialApplicationLaunch(launchMode)
            didCompleteInitialInteractiveLaunch = true
            if pendingActiveMaintenance {
                pendingActiveMaintenance = false
                startActiveMaintenance()
            }
        case .scheduledScan:
            await nextMainRunLoopTurn()
            await runInitialApplicationLaunch(launchMode)
        case .scheduledSignatureUpdate:
            break
        }
    }

    @discardableResult
    func showMainWindow(selecting selection: NavigationTab?) -> Bool {
        guard didPrepareApplicationLaunch else { return false }
        guard launchMode.presentsUserInterface else { return false }
        if mainWindowController == nil {
            mainWindowController = mainWindowControllerFactory()
        }
        guard let mainWindowController else {
            hasPendingMainWindowPresentation = true
            if let selection {
                pendingMainWindowSelection = selection
            }
            waitForControllerFactoryIfNeeded()
            return false
        }
        mainWindowController.showMainWindow(selecting: selection)
        return true
    }

    private func waitForControllerFactoryIfNeeded() {
        guard !isWaitingForMainWindowControllerFactory else { return }
        isWaitingForMainWindowControllerFactory = true
        waitForMainWindowControllerFactory { [weak self] in
            self?.controllerFactoryBecameAvailable()
        }
    }

    private func controllerFactoryBecameAvailable() {
        isWaitingForMainWindowControllerFactory = false
        guard hasPendingMainWindowPresentation else { return }
        guard let controller = mainWindowControllerFactory() else { return }
        mainWindowController = controller
        let selection = pendingMainWindowSelection
        hasPendingMainWindowPresentation = false
        pendingMainWindowSelection = nil
        controller.showMainWindow(selecting: selection)
        if shouldStartInitialLaunchAfterPresentation {
            shouldStartInitialLaunchAfterPresentation = false
            startInitialApplicationLaunch()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        let didShowMainWindow = showMainWindow(selecting: nil)
        requestActiveInteractiveMaintenance()
        return didShowMainWindow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func closeMainWindow() {
        mainWindowController?.closeMainWindow()
    }

    private func startActiveMaintenance() {
        guard activeMaintenanceTask == nil else { return }
        activeMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            await self.runActiveInteractiveMaintenance(self.launchMode)
            self.activeMaintenanceTask = nil
        }
    }

    private static func waitForNextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
