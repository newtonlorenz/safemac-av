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
            .filter { $0.canBecomeMain && $0.isVisible }
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

    func prepareForLaunch(hidden: Bool) -> Bool {
        applyDockVisibility(hidden: hidden) && hidden
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
    private var launchManager: MenuBarManager?
    private var shouldSuppressInitialMainWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let manager = MenuBarManager()
        let settings = ConfigManager().loadSettings()
        let shouldHideDock = settings.hideFromDock && !CommandLine.arguments.contains("--ui-testing")

        shouldSuppressInitialMainWindow = manager.prepareForLaunch(hidden: shouldHideDock)
        launchManager = manager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldSuppressInitialMainWindow, let launchManager else { return }
        DispatchQueue.main.async {
            launchManager.suppressInitialMainWindow(if: true)
        }
    }
}
