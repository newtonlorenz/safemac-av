import AppKit
import SwiftUI

@MainActor
protocol ApplicationActivationPolicyApplying: AnyObject {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps: Bool)
    func closeMainWindows()
}

extension NSApplication: ApplicationActivationPolicyApplying {
    func closeMainWindows() {
        windows
            .filter(\.canBecomeMain)
            .forEach { $0.close() }
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
        openWindow()
    }
}

@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private let providedManager: MenuBarManager?
    private let settingsProvider: () -> AppSettings
    private let argumentsProvider: () -> [String]
    private var launchManager: MenuBarManager?
    private var shouldSuppressInitialMainWindow = false

    override init() {
        providedManager = nil
        settingsProvider = { ConfigManager().loadSettings() }
        argumentsProvider = { CommandLine.arguments }
        super.init()
    }

    init(
        manager: MenuBarManager,
        settingsProvider: @escaping () -> AppSettings,
        argumentsProvider: @escaping () -> [String]
    ) {
        providedManager = manager
        self.settingsProvider = settingsProvider
        self.argumentsProvider = argumentsProvider
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let manager = providedManager ?? MenuBarManager()
        let settings = settingsProvider()
        let arguments = argumentsProvider()
        let shouldHideDock = settings.hideFromDock && !arguments.contains("--ui-testing")
        let shouldSuppressWindow: Bool
        switch LaunchModeParser.parse(arguments: arguments) {
        case .interactive:
            shouldSuppressWindow = true
        case .scheduledScan:
            shouldSuppressWindow = false
        }

        shouldSuppressInitialMainWindow = manager.prepareForLaunch(
            hidden: shouldHideDock,
            suppressInitialMainWindow: shouldSuppressWindow
        )
        launchManager = manager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldSuppressInitialMainWindow, let launchManager else { return }
        DispatchQueue.main.async {
            launchManager.suppressInitialMainWindow(if: true)
        }
    }
}
