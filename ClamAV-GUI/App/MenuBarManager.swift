import AppKit
import SwiftUI

@MainActor
final class ScheduledSignatureUpdateLifecycle {
    static let shared = ScheduledSignatureUpdateLifecycle()

    private var operation: (() async -> Void)?

    func install(operation: @escaping () async -> Void) {
        self.operation = operation
    }

    func run() async {
        await operation?()
    }
}

@MainActor
final class MainWindowPresentationLifecycle {
    static let shared = MainWindowPresentationLifecycle()

    private var openWindow: (() -> Void)?
    private var pendingRequests: [CheckedContinuation<Void, Never>] = []
    private var didPresent = false

    func install(openWindow: @escaping () -> Void) {
        guard !didPresent else { return }
        self.openWindow = openWindow
        presentIfReady()
    }

    func requestPresentation() async {
        guard !didPresent else { return }
        await withCheckedContinuation { continuation in
            pendingRequests.append(continuation)
            presentIfReady()
        }
    }

    private func presentIfReady() {
        guard !didPresent, let openWindow, !pendingRequests.isEmpty else { return }
        didPresent = true
        self.openWindow = nil
        let requests = pendingRequests
        pendingRequests.removeAll()
        openWindow()
        requests.forEach { $0.resume() }
    }
}

@MainActor
final class ApplicationLaunchLifecycle {
    static let shared = ApplicationLaunchLifecycle()

    private var runInitialInteractive: () async -> Void = {}
    private var runActiveInteractive: () async -> Void = {}
    private var runScheduledScan: (UUID?, [URL]) async -> Void = { _, _ in }

    func install(
        runInitialInteractive: @escaping () async -> Void,
        runActiveInteractive: @escaping () async -> Void,
        runScheduledScan: @escaping (UUID?, [URL]) async -> Void
    ) {
        self.runInitialInteractive = runInitialInteractive
        self.runActiveInteractive = runActiveInteractive
        self.runScheduledScan = runScheduledScan
    }

    func runInitial(mode: LaunchMode) async {
        switch mode {
        case .interactive:
            await runInitialInteractive()
        case .scheduledScan(let jobID, let paths):
            await runScheduledScan(jobID, paths)
        case .scheduledSignatureUpdate:
            break
        }
    }

    func runActiveMaintenance(mode: LaunchMode) async {
        guard mode.isInteractive else { return }
        await runActiveInteractive()
    }
}

@MainActor
protocol ApplicationActivationPolicyApplying: AnyObject {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps: Bool)
    func closeMainWindows()
    func focusMainWindow() -> Bool
}

extension NSApplication: ApplicationActivationPolicyApplying {
    func closeMainWindows() {
        windows
            .filter(\.canBecomeMain)
            .forEach { $0.close() }
    }

    func focusMainWindow() -> Bool {
        guard let window = MenuBarManager.mainWindowCandidate(in: windows) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

@MainActor
final class MenuBarManager: ObservableObject {
    @Published private(set) var isDockHidden = false

    private let application: ApplicationActivationPolicyApplying

    init(application: ApplicationActivationPolicyApplying? = nil) {
        self.application = application ?? NSApplication.shared
    }

    static func mainWindowCandidate(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == ClamAVApp.mainWindowID }
    }

    @discardableResult
    func applyDockVisibility(hidden: Bool) -> Bool {
        let activationPolicy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard application.setActivationPolicy(activationPolicy) else { return false }
        isDockHidden = hidden
        return true
    }

    func prepareForLaunch(
        hidden: Bool,
        suppressInitialMainWindow: Bool = true
    ) -> Bool {
        applyDockVisibility(hidden: hidden) && hidden && suppressInitialMainWindow
    }

    func suppressInitialMainWindow(if shouldSuppress: Bool) {
        guard shouldSuppress else { return }
        application.closeMainWindows()
    }

    func activateMainWindow(openWindow: () -> Void) {
        application.activate(ignoringOtherApps: true)
        if !application.focusMainWindow() {
            openWindow()
        }
    }

    @discardableResult
    func focusMainWindow() -> Bool {
        application.activate(ignoringOtherApps: true)
        return application.focusMainWindow()
    }
}

@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private let providedManager: MenuBarManager?
    private let settingsProvider: () -> AppSettings
    private let argumentsProvider: () -> [String]
    private let nextMainRunLoopTurn: () async -> Void
    private let requestMainWindowPresentation: () async -> Void
    private let runInitialApplicationLaunch: (LaunchMode) async -> Void
    private let runActiveInteractiveMaintenance: (LaunchMode) async -> Void
    private let runScheduledSignatureUpdate: () async -> Void
    private let finishScheduledLaunch: () -> Void
    private var launchManager: MenuBarManager?
    private var shouldSuppressInitialMainWindow = false
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
        requestMainWindowPresentation = {
            await MainWindowPresentationLifecycle.shared.requestPresentation()
        }
        runInitialApplicationLaunch = { mode in
            await ApplicationLaunchLifecycle.shared.runInitial(mode: mode)
        }
        runActiveInteractiveMaintenance = { mode in
            await ApplicationLaunchLifecycle.shared.runActiveMaintenance(mode: mode)
        }
        runScheduledSignatureUpdate = {
            await ScheduledSignatureUpdateLifecycle.shared.run()
        }
        finishScheduledLaunch = {
            NSApplication.shared.terminate(nil)
        }
        super.init()
    }

    init(
        manager: MenuBarManager,
        settingsProvider: @escaping () -> AppSettings,
        argumentsProvider: @escaping () -> [String],
        nextMainRunLoopTurn: @escaping () async -> Void = {
            await MenuBarApplicationDelegate.waitForNextMainRunLoopTurn()
        },
        requestMainWindowPresentation: @escaping () async -> Void = {},
        runInitialApplicationLaunch: @escaping (LaunchMode) async -> Void = { _ in },
        runActiveInteractiveMaintenance: @escaping (LaunchMode) async -> Void = { _ in },
        runScheduledSignatureUpdate: @escaping () async -> Void = {},
        finishScheduledLaunch: @escaping () -> Void = {}
    ) {
        providedManager = manager
        self.settingsProvider = settingsProvider
        self.argumentsProvider = argumentsProvider
        self.nextMainRunLoopTurn = nextMainRunLoopTurn
        self.requestMainWindowPresentation = requestMainWindowPresentation
        self.runInitialApplicationLaunch = runInitialApplicationLaunch
        self.runActiveInteractiveMaintenance = runActiveInteractiveMaintenance
        self.runScheduledSignatureUpdate = runScheduledSignatureUpdate
        self.finishScheduledLaunch = finishScheduledLaunch
        super.init()
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
        let shouldSuppressWindow: Bool
        switch mode {
        case .interactive:
            shouldSuppressWindow = true
        case .scheduledScan:
            shouldSuppressWindow = false
        case .scheduledSignatureUpdate:
            shouldSuppressWindow = true
        }

        shouldSuppressInitialMainWindow = manager.prepareForLaunch(
            hidden: hidesDock,
            suppressInitialMainWindow: shouldSuppressWindow
        )
        canRunScheduledSignatureUpdate = mode != .scheduledSignatureUpdate
            || shouldSuppressInitialMainWindow
        launchManager = manager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didHandleApplicationLaunch else { return }
        didHandleApplicationLaunch = true
        if shouldSuppressInitialMainWindow, let launchManager {
            launchManager.suppressInitialMainWindow(if: true)
        }

        if launchMode == .scheduledSignatureUpdate {
            guard canRunScheduledSignatureUpdate else {
                finishScheduledLaunch()
                return
            }
            scheduledLaunchTask = Task { [runScheduledSignatureUpdate, finishScheduledLaunch] in
                await runScheduledSignatureUpdate()
                finishScheduledLaunch()
            }
            return
        }

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
            await presentMainWindowIfNeeded()
            await runInitialApplicationLaunch(launchMode)
            didCompleteInitialInteractiveLaunch = true
            if pendingActiveMaintenance {
                pendingActiveMaintenance = false
                startActiveMaintenance()
            }
        case .scheduledScan:
            await presentMainWindowIfNeeded()
            await runInitialApplicationLaunch(launchMode)
        case .scheduledSignatureUpdate:
            break
        }
    }

    private func presentMainWindowIfNeeded() async {
        guard shouldPresentMainWindowAtLaunch, let launchManager else { return }
        await nextMainRunLoopTurn()
        if launchManager.focusMainWindow() {
            await nextMainRunLoopTurn()
            return
        }

        await requestMainWindowPresentation()
        for _ in 0..<3 {
            await nextMainRunLoopTurn()
            if launchManager.focusMainWindow() {
                return
            }
        }
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
