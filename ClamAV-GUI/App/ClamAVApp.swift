import AppKit
import Combine
import SwiftUI

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
    @State private var presentsMenuBarExtra: Bool

    init() {
        let arguments = CommandLine.arguments
        let launchMode = LaunchModeParser.parse(arguments: arguments)
        _presentsMenuBarExtra = State(initialValue: launchMode.presentsUserInterface)

        let appState = AppState(
            startsInteractiveBackgroundServices: launchMode.startsInteractiveBackgroundServices
        )
        let menuBarManager = MenuBarManager()
        _appState = StateObject(wrappedValue: appState)
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        let isAutomatedTestLaunch = arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
                        if SignatureScheduleReconciliationPolicy.shouldReconcile(
                            bundleURL: bundleURL,
                            isAutomatedTest: isAutomatedTestLaunch
                        ) {
                            appState.reconcileSignatureUpdateSchedule()
                        }
                        await appState.drainExternalScanRequests()
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
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $presentsMenuBarExtra) {
            MenuBarPopoverView()
                .environmentObject(appState)
                .preferredColorScheme(Self.uiTestColorScheme(arguments: CommandLine.arguments))
        } label: {
            Image(systemName: menuBarIcon)
                .accessibilityLabel("SafeMac AV")
                .accessibilityIdentifier("safe-mac-menu-bar-item")
        }
        .menuBarExtraStyle(.window)
        .commands {
            ScanCommands()
        }
    }

    private var menuBarIcon: String {
        if appState.isScanning || appState.isUpdatingSignatures {
            return "shield.lefthalf.filled"
        }
        return appState.protectionScore.score >= 80 ? "checkmark.shield.fill" : "shield.fill"
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

extension Notification.Name {
    static let startQuickScan = Notification.Name("startQuickScan")
    static let startCustomScan = Notification.Name("startCustomScan")
    static let updateSignatures = Notification.Name("updateSignatures")
}
