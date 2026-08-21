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
}

extension NSApplication: ApplicationActivationPolicyApplying {}

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
        isDockHidden = hidden
        return true
    }

    func activateApplication() {
        application.activate(ignoringOtherApps: true)
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
    private var mainWindowController: MainWindowControlling?
    private var isWaitingForMainWindowControllerFactory = false
    private var hasPendingMainWindowPresentation = false
    private var pendingMainWindowSelection: NavigationTab?
    private var shouldStartInitialLaunchAfterPresentation = false
    private var didStartInitialApplicationLaunch = false
    private var isConfiguredForLaunch: Bool
    private var hasPendingLaunchUntilConfigured = false
    private var launchMode: LaunchMode = .interactive
    private var canRunScheduledSignatureUpdate = false
    private var shouldPresentMainWindowAtLaunch = false
    private var didHandleApplicationLaunch = false
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
        isConfiguredForLaunch = false
        super.init()
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
        startsConfigured: Bool = true
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
        isConfiguredForLaunch = startsConfigured
        super.init()
    }

    func configure(
        manager: MenuBarManager,
        settingsProvider: @escaping () -> AppSettings,
        argumentsProvider: @escaping () -> [String],
        runInitialApplicationLaunch: @escaping (LaunchMode) async -> Void,
        runActiveInteractiveMaintenance: @escaping (LaunchMode) async -> Void,
        runScheduledSignatureUpdate: @escaping () async -> Void
    ) {
        providedManager = manager
        self.settingsProvider = settingsProvider
        self.argumentsProvider = argumentsProvider
        mainWindowControllerFactory = {
            MainWindowControllerRegistry.shared.makeController()
        }
        self.runInitialApplicationLaunch = runInitialApplicationLaunch
        self.runActiveInteractiveMaintenance = runActiveInteractiveMaintenance
        self.runScheduledSignatureUpdate = runScheduledSignatureUpdate
        isConfiguredForLaunch = true
        if hasPendingLaunchUntilConfigured {
            hasPendingLaunchUntilConfigured = false
            continueApplicationLaunch()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didHandleApplicationLaunch else { return }
        didHandleApplicationLaunch = true
        if launchMode == .scheduledSignatureUpdate, !canRunScheduledSignatureUpdate {
            finishScheduledLaunch()
            return
        }
        guard isConfiguredForLaunch else {
            hasPendingLaunchUntilConfigured = true
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
        showMainWindow(selecting: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
