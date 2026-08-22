import AppKit
import Darwin
import Foundation
import Security
import UserNotifications

@main
final class SafeMacAVBackgroundApp: NSObject, NSApplicationDelegate {
    private let lease = BackgroundWorkLease(name: "background-monitoring")
    private let settingsStore = BackgroundHelperSettingsStore(settingsURL: BackgroundSignatureUpdater.defaultSettingsURL)
    private var statusItem: NSStatusItem?
    private var coordinator: BackgroundHelperCoordinator?
    private let notificationCoordinator = BackgroundHelperNotificationCoordinator()

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
        let notificationCoordinator = notificationCoordinator
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async(execute: completion) }
            let updater = BackgroundSignatureUpdater(settingsStore: settingsStore)
            guard let outcome = updater.runIfAvailable() else { return }
            let notificationsEnabled = settingsStore.reload().showNotifications
            Task {
                await notificationCoordinator.deliverIfAuthorized(
                    outcome: outcome,
                    notificationsEnabled: notificationsEnabled
                )
            }
        }
    }
}

enum BackgroundHelperNotificationAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined
}

protocol BackgroundHelperNotificationDelivering: AnyObject {
    func authorizationStatus() async -> BackgroundHelperNotificationAuthorization
    func deliver(title: String, body: String) async
}

final class BackgroundHelperNotificationCoordinator {
    private let delivery: BackgroundHelperNotificationDelivering

    init(delivery: BackgroundHelperNotificationDelivering = SystemBackgroundHelperNotificationDelivery()) {
        self.delivery = delivery
    }

    /// The helper only reads its own bundle authorization. It never requests
    /// permission, so login and scheduled work cannot cause a prompt.
    func deliverIfAuthorized(outcome: FreshclamUpdateOutcome, notificationsEnabled: Bool) async {
        guard notificationsEnabled,
              await delivery.authorizationStatus() == .authorized else { return }
        let content: (String, String)
        switch outcome {
        case .updated:
            content = ("Signatures updated", "SafeMac AV updated its malware signatures.")
        case .upToDate:
            content = ("Signatures are current", "SafeMac AV malware signatures are already up to date.")
        case .failed:
            content = ("Signature update failed", "SafeMac AV could not update its malware signatures. Open the app for details.")
        }
        await delivery.deliver(title: content.0, body: content.1)
    }
}

final class SystemBackgroundHelperNotificationDelivery: BackgroundHelperNotificationDelivering {
    func authorizationStatus() async -> BackgroundHelperNotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func deliver(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "signature-update"
        let request = UNNotificationRequest(identifier: "background-signature-update", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
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
    private let execute: (FreshclamInvocation, TimeInterval) -> FreshclamUpdateOutcome

    init(
        settingsURL: URL? = nil,
        execute: @escaping (FreshclamInvocation, TimeInterval) -> FreshclamUpdateOutcome = { invocation, timeout in
            BackgroundSignatureUpdater.executeProcess(invocation, timeout: timeout)
        }
    ) {
        settingsStore = BackgroundHelperSettingsStore(settingsURL: settingsURL ?? Self.defaultSettingsURL)
        self.execute = execute
    }

    init(
        settingsStore: BackgroundHelperSettingsStore,
        execute: @escaping (FreshclamInvocation, TimeInterval) -> FreshclamUpdateOutcome = { invocation, timeout in
            BackgroundSignatureUpdater.executeProcess(invocation, timeout: timeout)
        }
    ) {
        self.settingsStore = settingsStore
        self.execute = execute
    }

    @discardableResult
    func runIfAvailable() -> FreshclamUpdateOutcome? {
        let lease = BackgroundWorkLease(name: "signature-update")
        guard lease.acquire() else { return nil }
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
            return nil
        }
        return execute(invocation, 300)
    }

    static func executeProcess(
        _ invocation: FreshclamInvocation,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 2
    ) -> FreshclamUpdateOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let output = BackgroundFreshclamOutputBuffer(limit: 65_536)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(terminationGrace)
                while process.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                return .failed(message: "Signature update timed out")
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            return FreshclamUpdateOutcome.parse(
                output: output.text,
                exitCode: process.terminationStatus
            )
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return .failed(message: "Signature update could not start")
        }
    }

}

private final class BackgroundFreshclamOutputBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) { self.limit = limit }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ more: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(more.prefix(limit - data.count))
    }
}
