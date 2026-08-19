import AppKit

enum FinderExtensionManager {
    static var isEnabled: Bool { false }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }
}
