import AppKit
import Foundation

@main
final class SafeMacAVBackgroundApp: NSObject, NSApplicationDelegate {
    private let lease = BackgroundWorkLease(name: "background-monitoring")
    private var statusItem: NSStatusItem?

    static func main() {
        let application = NSApplication.shared
        let delegate = SafeMacAVBackgroundApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch BackgroundHelperLaunchModeParser.parse(arguments: CommandLine.arguments) {
        case .backgroundSession:
            installStatusItem()
            _ = lease.acquire()
        case .scheduledSignatureUpdate:
            runScheduledSignatureUpdateAndTerminate()
        case .invalid:
            NSApplication.shared.terminate(nil)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "SafeMac AV")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open SafeMac AV", action: #selector(openMain), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    @objc private func openMain() { MainAppHandoff.send(.open) }
    @objc private func openSettings() { MainAppHandoff.send(.settings) }
    @objc private func checkForUpdates() { MainAppHandoff.send(.checkForUpdates) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func runScheduledSignatureUpdateAndTerminate() {
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
            let updater = BackgroundSignatureUpdater()
            updater.runIfAvailable()
        }
    }
}

private enum MainAppHandoff {
    private static let bundleURL = URL(fileURLWithPath: "/Applications/SafeMac AV.app", isDirectory: true)
    private static let mainBundleIdentifier = "com.newtonlorenz.ClamAV-GUI"

    static func send(_ route: BackgroundRoute) {
        guard let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier == mainBundleIdentifier else { return }
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: .init()) { _, _ in }
        DistributedNotificationCenter.default().post(
            name: route.distributedNotificationName,
            object: nil,
            userInfo: nil
        )
    }
}

private final class BackgroundSignatureUpdater {
    func runIfAvailable() {
        let lease = BackgroundWorkLease(name: "signature-update")
        guard lease.acquire() else { return }
        defer { lease.release() }

        guard let executablePath = configuredFreshclamPath(), FileManager.default.isExecutableFile(atPath: executablePath) else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func configuredFreshclamPath() -> String? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let settingsURL = support?
            .appendingPathComponent("ClamAV-GUI", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        guard let settingsURL, let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["freshclamPath"] as? String,
              path.hasPrefix("/") else { return nil }
        return path
    }
}
