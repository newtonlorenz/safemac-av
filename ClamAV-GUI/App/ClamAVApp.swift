import AppKit
import Combine
import SwiftUI
#if DEBUG
import Darwin
import UserNotifications
#endif

@MainActor
struct ApplicationLaunchConfiguration {
    let manager: MenuBarManager
    let settingsProvider: () -> AppSettings
    let argumentsProvider: () -> [String]
    let runInitialApplicationLaunch: (LaunchMode) async -> Void
    let runActiveInteractiveMaintenance: (LaunchMode) async -> Void
    let runScheduledSignatureUpdate: () async -> Void
}

@MainActor
final class ApplicationLaunchConfigurationRegistry {
    static let shared = ApplicationLaunchConfigurationRegistry()

    private final class Subscription {
        weak var owner: AnyObject?
        let deliver: (AnyObject, ApplicationLaunchConfiguration) -> Void
        var didReceiveConfiguration = false

        init<Owner: AnyObject>(
            owner: Owner,
            operation: @escaping (Owner, ApplicationLaunchConfiguration) -> Void
        ) {
            self.owner = owner
            deliver = { owner, configuration in
                guard let owner = owner as? Owner else { return }
                operation(owner, configuration)
            }
        }
    }

    private var configuration: ApplicationLaunchConfiguration?
    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    private var launchContinuationOwner: ObjectIdentifier?

    func install(_ configuration: ApplicationLaunchConfiguration) {
        self.configuration = configuration
        removeReleasedSubscriptions()
        let deliveries = subscriptions.values.filter { !$0.didReceiveConfiguration }
        deliveries.forEach { $0.didReceiveConfiguration = true }
        deliveries.forEach { subscription in
            guard let owner = subscription.owner else { return }
            subscription.deliver(owner, configuration)
        }
    }

    func whenAvailable<Owner: AnyObject>(
        for owner: Owner,
        _ operation: @escaping (Owner, ApplicationLaunchConfiguration) -> Void
    ) {
        removeReleasedSubscriptions()
        let identifier = ObjectIdentifier(owner)
        guard subscriptions[identifier] == nil else { return }
        let subscription = Subscription(owner: owner, operation: operation)
        subscriptions[identifier] = subscription
        guard let configuration else { return }
        subscription.didReceiveConfiguration = true
        subscription.deliver(owner, configuration)
    }

    func resetForTesting() {
        configuration = nil
        subscriptions.removeAll()
        launchContinuationOwner = nil
    }

    func claimLaunchContinuation<Owner: AnyObject>(for owner: Owner) -> Bool {
        let identifier = ObjectIdentifier(owner)
        if let launchContinuationOwner {
            return launchContinuationOwner == identifier
        }
        launchContinuationOwner = identifier
        return true
    }

    private func removeReleasedSubscriptions() {
        subscriptions = subscriptions.filter { $0.value.owner != nil }
    }
}

@main
struct ClamAVApp: App {
    static let mainWindowID = "main-window"
    static let mainWindowTitle = "SafeMac AV"

    @NSApplicationDelegateAdaptor(MenuBarApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState: AppState
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var softwareUpdateManager: SoftwareUpdateManager
    @StateObject private var menuBarOwnership: BackgroundMenuBarOwnershipCoordinator

    init() {
        let arguments = CommandLine.arguments
        let launchMode = LaunchModeParser.parse(arguments: arguments)
        let isAutomatedTestLaunch = arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#if DEBUG
        let startsMenuOwnershipRecovery = false
#else
        let startsMenuOwnershipRecovery = !isAutomatedTestLaunch
#endif
        let appState: AppState
#if DEBUG
        if arguments.contains("--ui-testing") {
            do {
                appState = try DebugUITestEnvironment.makeAppState(
                    rootPath: ProcessInfo.processInfo.environment["SAFEMAC_UI_TEST_ROOT"]
                )
            } catch {
                fatalError("UI testing requires an empty, owned temporary SAFEMAC_UI_TEST_ROOT: \(error)")
            }
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            do {
                appState = try DebugUITestEnvironment.makeUnitTestAppState()
            } catch {
                fatalError("Could not prepare isolated unit-test storage: \(error)")
            }
        } else {
            appState = AppState(startsInteractiveBackgroundServices: launchMode.startsInteractiveBackgroundServices)
        }
#else
        appState = AppState(startsInteractiveBackgroundServices: launchMode.startsInteractiveBackgroundServices)
#endif
#if DEBUG
        let ownershipLeaseDirectory = isAutomatedTestLaunch
            ? URL(fileURLWithPath: appState.settings.configDirectory).deletingLastPathComponent() : nil
#else
        let ownershipLeaseDirectory: URL? = nil
#endif
        let menuBarOwnership = BackgroundMenuBarOwnershipCoordinator(
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: ownershipLeaseDirectory) },
            keepsMenuDuringInteractiveLaunch: launchMode.isInteractive && appState.settings.hideFromDock,
            startsRecoveryTimer: startsMenuOwnershipRecovery,
            observesOwnershipHints: !isAutomatedTestLaunch
        )
        menuBarOwnership.reconcile(helperEnabled: appState.launchAtLoginStatus == .enabled)
        menuBarOwnership.observe(
            helperEnabled: appState.$launchAtLoginStatus
                .map { $0 == .enabled }
                .eraseToAnyPublisher()
        )
        let menuBarManager = MenuBarManager()
        let softwareUpdateManager = SoftwareUpdateManager(startsUpdater: false, isAutomatedTest: isAutomatedTestLaunch)
        let softwareUpdateStartupCoordinator = SoftwareUpdateStartupCoordinator()
        _appState = StateObject(wrappedValue: appState)
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        _softwareUpdateManager = StateObject(wrappedValue: softwareUpdateManager)
        _menuBarOwnership = StateObject(wrappedValue: menuBarOwnership)
        let bundleURL = Bundle.main.bundleURL
        let preferredColorScheme = Self.uiTestColorScheme(arguments: arguments)

        DockVisibilityLifecycle.shared.install(
            settings: appState.$settings.eraseToAnyPublisher(),
            launchMode: launchMode,
            isUITesting: arguments.contains("--ui-testing"),
            manager: menuBarManager
        )
        ApplicationLaunchConfigurationRegistry.shared.install(
            ApplicationLaunchConfiguration(
                manager: menuBarManager,
                settingsProvider: { appState.settings },
                argumentsProvider: { arguments },
                runInitialApplicationLaunch: { mode in
                    switch mode {
                    case .interactive:
                        await softwareUpdateStartupCoordinator.runInitialMaintenance(
                            launchMode: mode,
                            settingsProvider: { appState.settings },
                            isUITesting: arguments.contains("--ui-testing"),
                            maintenance: {
                                if SignatureScheduleReconciliationPolicy.shouldReconcile(
                                    bundleURL: bundleURL,
                                    isAutomatedTest: isAutomatedTestLaunch
                                ) {
                                    appState.reconcileScheduledScanStorage()
                                    appState.reconcileSignatureUpdateSchedule()
                                }
                                await appState.drainExternalScanRequests()
                            },
                            afterMaintenance: {
                                menuBarOwnership.completeInteractiveLaunchAnchor()
                            },
                            startUpdater: {
                                softwareUpdateManager.startUpdaterIfPossible()
                            }
                        )
                    case .scheduledScan(let jobID, let paths):
                        await appState.runScheduledScan(jobID: jobID, paths: paths)
                    case .scheduledSignatureUpdate:
                        break
                    }
                },
                runActiveInteractiveMaintenance: { mode in
                    guard mode.isInteractive else { return }
                    appState.refreshProtectionScore()
                    appState.refreshLaunchAtLoginStatus()
                    appState.drainBackgroundRouteRequests()
                    await appState.drainExternalScanRequests()
                },
                runScheduledSignatureUpdate: {
                    await appState.runScheduledSignatureUpdate()
                }
            )
        )
        MainWindowControllerRegistry.shared.installFactory {
            MainWindowController(
                appState: appState,
                menuBarManager: menuBarManager,
                preferredColorScheme: preferredColorScheme
            )
        }
        MainWindowControllerRegistry.shared.whenRouterAvailable {
            appState.drainBackgroundRouteRequests()
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { menuBarOwnership.mainShouldPresentMenuBar },
            set: { _ in }
        )) {
            MenuBarPopoverView()
                .environmentObject(appState)
                .environmentObject(softwareUpdateManager)
                .preferredColorScheme(Self.uiTestColorScheme(arguments: CommandLine.arguments))
        } label: {
            Image(systemName: menuBarIcon)
                .accessibilityLabel("SafeMac AV")
                .accessibilityIdentifier("safe-mac-menu-bar-item")
        }
        .menuBarExtraStyle(.window)
        .commands {
            ForegroundAppCommands()
            AppUpdateCommands(updater: softwareUpdateManager)
            ScanCommands()
        }
    }

    private var menuBarIcon: String {
        if appState.isScanning || appState.isUpdatingSignatures {
            return "shield.lefthalf.filled"
        }
        return appState.scanOverviewStatus.kind == .detections || appState.scanOverviewStatus.kind == .incomplete ? "exclamationmark.shield.fill" : "shield"
    }

    private static func uiTestColorScheme(arguments: [String]) -> ColorScheme? {
#if DEBUG
        if arguments.contains("--force-light-appearance") {
            return .light
        }
        if arguments.contains("--force-dark-appearance") {
            return .dark
        }
#endif
        return nil
    }

}

struct ForegroundAppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Close SafeMac AV") {
                MainWindowControllerRegistry.shared.closeMainWindow()
            }
            .keyboardShortcut("q")
        }
    }
}

struct ScanCommands: Commands {
    var body: some Commands {
        CommandMenu("Scan") {
            Button("Quick Scan") {
                NotificationCenter.default.post(name: .startQuickScan, object: nil)
            }
            .keyboardShortcut("Q", modifiers: [.command, .shift])

            Button("Custom Scan...") {
                NotificationCenter.default.post(name: .startCustomScan, object: nil)
            }
            .keyboardShortcut("S", modifiers: [.command, .shift])

            Divider()

            Button("Update Signatures") {
                NotificationCenter.default.post(name: .updateSignatures, object: nil)
            }
            .keyboardShortcut("U", modifiers: [.command, .shift])
        }
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var updater: SoftwareUpdateManager

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                updater.checkForUpdates()
            }
            .disabled(!updater.isConfigured)

            if !updater.isConfigured {
                Text("App update feed not configured")
            }
        }
    }
}

extension Notification.Name {
    static let startQuickScan = Notification.Name("startQuickScan")
    static let startCustomScan = Notification.Name("startCustomScan")
    static let updateSignatures = Notification.Name("updateSignatures")
}

#if DEBUG
/// Debug test hosts use private storage; Release builds keep normal composition.
@MainActor
enum DebugUITestEnvironment {
    static func makeUnitTestAppState() throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeMacAV-UITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        DebugTestRootCleanup.register(root)
        return try makeAppState(rootPath: root.path)
    }

    static func makeAppState(rootPath: String?) throws -> AppState {
        guard let rootPath, rootPath.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let suppliedRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        let root = suppliedRoot.resolvingSymlinksInPath()
        let prefix = "SafeMacAV-UITests-"
        let attributes = try FileManager.default.attributesOfItem(atPath: suppliedRoot.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              root.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw CocoaError(.fileReadNoPermission)
        }
        let config = ConfigManager(appSupportURL: root)
        var settings = AppSettings.default
        settings.clamScanPath = "/usr/bin/true"
        settings.freshclamPath = "/usr/bin/true"
        settings.clamdSettings = ClamdSettings(clamdScanPath: "/usr/bin/true", socketPath: root.appendingPathComponent("clamd.sock").path, isEnabled: false)
        settings.configDirectory = root.appendingPathComponent("config").path
        settings.signatureDirectory = root.appendingPathComponent("signatures").path
        settings.quarantineDirectory = root.appendingPathComponent("quarantine").path
        settings.monitoredDirectories = []
        settings.monitoringEnabled = false
        settings.autoScanDownloads = false
        settings.autoUpdateSignatures = false
        settings.scanWhenIdle = false
        settings.showNotifications = false
        settings.launchAtLogin = false
        try config.saveSettings(settings)
        return AppState(
            configManager: config,
            scanScheduler: ScanScheduler(
                launchAgentsDirectory: root.appendingPathComponent("LaunchAgents"),
                jobsStorageURL: root.appendingPathComponent("scheduled_jobs.json"),
                launchAgentLoadedStatusProvider: { _ in false }, launchctlRunner: { _, _ in }
            ),
            fileWatcher: DebugUITestFileWatcher(),
            notificationManager: NotificationManager(center: DebugUITestNotificationCenter()),
            externalScanRequestStore: ExternalScanRequestStore(baseURL: root),
            backgroundRouteRequestStore: BackgroundRouteRequestStore(baseURL: root),
            launchAtLoginManager: DebugUITestLoginManager(),
            signatureUpdateScheduler: DebugUITestSignatureScheduler(),
            backgroundHelperNotificationAuthorizationRequester: DebugUITestHelperAuthorization(),
            startsInteractiveBackgroundServices: true
        )
    }
}

/// Unit hosts own these generated roots. UI roots belong to XCTest's teardown.
private enum DebugTestRootCleanup {
    private static let lock = NSLock()
    private static var roots: [URL] = []
    private static var registered = false
    private static var terminationObserver: NSObjectProtocol?

    static func register(_ root: URL) {
        lock.lock()
        defer { lock.unlock() }
        roots.append(root)
        guard !registered else { return }
        registered = true
        atexit { DebugTestRootCleanup.removeOwnedRoots() }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in DebugTestRootCleanup.removeOwnedRoots() }
    }

    private static func removeOwnedRoots() {
        lock.lock()
        let ownedRoots = roots
        roots.removeAll()
        lock.unlock()
        for root in ownedRoots { try? FileManager.default.removeItem(at: root) }
    }
}

private struct DebugUITestLoginManager: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus { .disabled }
    func setEnabled(_ enabled: Bool) throws {}
}
private final class DebugUITestSignatureScheduler: SignatureUpdateScheduling {
    func reconcile(enabled: Bool, schedule: ScanSchedule) throws {}
}
private final class DebugUITestFileWatcher: FileWatcherProtocol {
    var isWatching: Bool { false }
    var onNewFileDetected: ((URL) -> Void)?
    func startWatching(directories: [URL], handler: @escaping ([URL]) -> Void) {}
    func stopWatching() {}
    func updateConfiguration(batchIntervalMinutes: Int, batchThreshold: Int) {}
    func configureImmediateScanDirectories(_ directories: [URL]) {}
}
private final class DebugUITestNotificationCenter: UserNotificationCenterProtocol {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func add(_ request: UNNotificationRequest) async throws {}
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {}
}
@MainActor
private final class DebugUITestHelperAuthorization: BackgroundHelperNotificationAuthorizationRequesting {
    func requestAuthorization() async -> Bool { false }
}
#endif
