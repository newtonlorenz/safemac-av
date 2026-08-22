import AppKit
import Darwin
import Foundation

@main
final class SafeMacAVBackgroundApp: NSObject, NSApplicationDelegate {
    private let lease = BackgroundWorkLease(name: "background-monitoring")

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
            name: route.notificationName,
            object: nil,
            userInfo: nil
        )
    }
}

private extension BackgroundRoute {
    var notificationName: Notification.Name {
        Notification.Name("com.newtonlorenz.ClamAV-GUI.background-route.\(rawValue)")
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

private final class BackgroundWorkLease {
    private let url: URL
    private var descriptor: Int32 = -1

    init(name: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        url = support
            .appendingPathComponent("ClamAV-GUI", isDirectory: true)
            .appendingPathComponent("\(name).lock", isDirectory: false)
    }

    deinit { release() }

    func acquire() -> Bool {
        guard descriptor == -1 else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        } catch {
            return false
        }
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & S_IFMT) == S_IFREG,
              (attributes.st_mode & 0o077) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
