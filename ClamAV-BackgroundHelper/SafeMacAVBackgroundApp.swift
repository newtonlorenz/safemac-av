import AppKit
import Foundation
import Security

@main
final class SafeMacAVBackgroundApp: NSObject, NSApplicationDelegate {
    private let lease = BackgroundWorkLease(name: "background-monitoring")
    private let settingsStore = BackgroundHelperSettingsStore(settingsURL: BackgroundSignatureUpdater.defaultSettingsURL)
    private var statusItem: NSStatusItem?
    private var coordinator: BackgroundHelperCoordinator?

    static func main() {
        let application = NSApplication.shared
        let delegate = SafeMacAVBackgroundApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        start(arguments: CommandLine.arguments)
    }

    @MainActor
    func start(arguments: [String]) {
        _ = settingsStore.reload()
        settingsStore.startWatching()
        coordinator = BackgroundHelperCoordinator(
            installStatusItem: { [weak self] in self?.installStatusItem() },
            acquireMonitoringLease: { [weak self] in self?.lease.acquire() ?? false },
            runScheduledSignatureUpdate: { [weak self] completion in self?.runScheduledSignatureUpdate(completion: completion) },
            terminate: { NSApplication.shared.terminate(nil) }
        )
        coordinator?.start(arguments: arguments)
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

    var hasStatusItem: Bool { statusItem != nil }

    @objc func openMain() { MainAppHandoff.send(.open) }
    @objc func openSettings() { MainAppHandoff.send(.settings) }
    @objc func checkForUpdates() { MainAppHandoff.send(.checkForUpdates) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func runScheduledSignatureUpdate(completion: @escaping () -> Void) {
        let settingsStore = settingsStore
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async(execute: completion) }
            let updater = BackgroundSignatureUpdater(settingsStore: settingsStore)
            updater.runIfAvailable()
        }
    }
}

private enum MainAppHandoff {
    private static let bundleURL = URL(fileURLWithPath: "/Applications/SafeMac AV.app", isDirectory: true)
    private static let mainBundleIdentifier = "com.newtonlorenz.ClamAV-GUI"
    private static let teamIdentifier = "CQPH8YR62A"

    static func send(_ route: BackgroundRoute) {
        BackgroundRouteHandoff(
            requestStore: BackgroundRouteRequestStore(),
            validateMainApplication: {
                canonicalMainApplicationIsTrusted()
            },
            openMainApplication: { completion in
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: .init()) { _, error in
                    completion(error == nil)
                }
            },
            postWakeHint: { route in
                DistributedNotificationCenter.default().post(
                    name: route.distributedNotificationName,
                    object: nil,
                    userInfo: nil
                )
            }
        ).send(route)
    }

    private static func canonicalMainApplicationIsTrusted() -> Bool {
        var attributes = stat()
        guard lstat(bundleURL.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFDIR,
              Bundle(url: bundleURL)?.bundleIdentifier == mainBundleIdentifier else {
            return false
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        let requirementString = "identifier \(mainBundleIdentifier) and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

final class BackgroundSignatureUpdater {
    static let defaultSettingsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (support ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("ClamAV-GUI", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }()

    private let settingsStore: BackgroundHelperSettingsStore
    private let execute: (FreshclamInvocation, TimeInterval) -> Void

    init(
        settingsURL: URL? = nil,
        execute: @escaping (FreshclamInvocation, TimeInterval) -> Void = BackgroundSignatureUpdater.execute
    ) {
        settingsStore = BackgroundHelperSettingsStore(settingsURL: settingsURL ?? Self.defaultSettingsURL)
        self.execute = execute
    }

    init(
        settingsStore: BackgroundHelperSettingsStore,
        execute: @escaping (FreshclamInvocation, TimeInterval) -> Void = BackgroundSignatureUpdater.execute
    ) {
        self.settingsStore = settingsStore
        self.execute = execute
    }

    func runIfAvailable() {
        let lease = BackgroundWorkLease(name: "signature-update")
        guard lease.acquire() else { return }
        defer { lease.release() }

        let settings = settingsStore.reload()
        guard settings.autoUpdateSignatures,
              let executablePath = settings.freshclamPath,
              let configDirectory = settings.configDirectory,
              let signatureDirectory = settings.signatureDirectory,
              let invocation = try? FreshclamInvocation.make(
                executablePath: executablePath,
                configDirectory: configDirectory,
                signatureDirectory: signatureDirectory
              ) else {
            return
        }
        execute(invocation, 300)
    }

    private static func execute(_ invocation: FreshclamInvocation, timeout: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        } catch {
            return
        }
    }

}
