import AppKit
import SwiftUI

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

    func applyDockVisibility(hidden: Bool) {
        let activationPolicy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard application.setActivationPolicy(activationPolicy) else { return }
        isDockHidden = hidden
    }

    func activateMainWindow(openWindow: () -> Void) {
        openWindow()
        application.activate(ignoringOtherApps: true)
    }
}
