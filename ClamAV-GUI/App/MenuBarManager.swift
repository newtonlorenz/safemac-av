import AppKit
import SwiftUI

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
        guard let window = windows.first(where: { $0.identifier?.rawValue == ClamAVApp.mainWindowID }) else {
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
        let mode = LaunchModeParser.parse(arguments: arguments)
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
        launchManager = manager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldSuppressInitialMainWindow, let launchManager else { return }
        DispatchQueue.main.async {
            launchManager.suppressInitialMainWindow(if: true)
        }
    }
}
