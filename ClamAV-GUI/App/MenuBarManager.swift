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
            ?? windows.first { $0.identifier == nil && $0.canBecomeMain }
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
}

@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private let providedManager: MenuBarManager?
    private let settingsProvider: () -> AppSettings
    private let argumentsProvider: () -> [String]
    private let runScheduledSignatureUpdate: () async -> Void
    private let finishScheduledLaunch: () -> Void
    private var launchManager: MenuBarManager?
    private var shouldSuppressInitialMainWindow = false
    private var launchMode: LaunchMode = .interactive
    private var canRunScheduledSignatureUpdate = false
    private var scheduledLaunchTask: Task<Void, Never>?

    override init() {
        providedManager = nil
        settingsProvider = { ConfigManager().loadSettings() }
        argumentsProvider = { CommandLine.arguments }
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
        runScheduledSignatureUpdate: @escaping () async -> Void = {},
        finishScheduledLaunch: @escaping () -> Void = {}
    ) {
        providedManager = manager
        self.settingsProvider = settingsProvider
        self.argumentsProvider = argumentsProvider
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
            hidden: mode.hidesDock(settings: settings, isUITesting: arguments.contains("--ui-testing")),
            suppressInitialMainWindow: shouldSuppressWindow
        )
        canRunScheduledSignatureUpdate = mode != .scheduledSignatureUpdate
            || shouldSuppressInitialMainWindow
        launchManager = manager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldSuppressInitialMainWindow, let launchManager {
            launchManager.suppressInitialMainWindow(if: true)
        }
        guard launchMode == .scheduledSignatureUpdate else { return }
        guard canRunScheduledSignatureUpdate else {
            finishScheduledLaunch()
            return
        }
        scheduledLaunchTask = Task { [runScheduledSignatureUpdate, finishScheduledLaunch] in
            await runScheduledSignatureUpdate()
            finishScheduledLaunch()
        }
    }
}
