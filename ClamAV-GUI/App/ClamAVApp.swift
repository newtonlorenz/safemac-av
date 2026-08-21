import AppKit
import SwiftUI

@main
struct ClamAVApp: App {
    static let mainWindowID = "main-window"
    static let mainWindowTitle = "SafeMac AV"

    @NSApplicationDelegateAdaptor(MenuBarApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState: AppState
    @StateObject private var menuBarManager = MenuBarManager()
    private let launchMode: LaunchMode
    @State private var presentsMenuBarExtra: Bool
    @Environment(\.openWindow) private var openWindow

    init() {
        let launchMode = LaunchModeParser.parse(arguments: CommandLine.arguments)
        self.launchMode = launchMode
        _presentsMenuBarExtra = State(initialValue: launchMode.presentsUserInterface)

        let appState = AppState(
            startsInteractiveBackgroundServices: launchMode.startsInteractiveBackgroundServices
        )
        _appState = StateObject(wrappedValue: appState)
        let isAutomatedTestLaunch = CommandLine.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let bundleURL = Bundle.main.bundleURL
        ApplicationLaunchLifecycle.shared.install(
            runInitialInteractive: {
                if SignatureScheduleReconciliationPolicy.shouldReconcile(
                    bundleURL: bundleURL,
                    isAutomatedTest: isAutomatedTestLaunch
                ) {
                    appState.reconcileSignatureUpdateSchedule()
                }
                await appState.drainExternalScanRequests()
            },
            runActiveInteractive: {
                appState.refreshProtectionScore()
                appState.refreshLaunchAtLoginStatus()
                await appState.drainExternalScanRequests()
            },
            runScheduledScan: { jobID, paths in
                await appState.runScheduledScan(jobID: jobID, paths: paths)
            }
        )
        ScheduledSignatureUpdateLifecycle.shared.install {
            await appState.runScheduledSignatureUpdate()
        }
    }

    var body: some Scene {
        Window(Self.mainWindowTitle, id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(uiTestColorScheme)
                .background(MainWindowIdentifier(identifier: Self.mainWindowID))
                .onChange(of: appState.settings.hideFromDock) { isHidden in
                    menuBarManager.applyDockVisibility(hidden: launchMode.hidesDock(
                        settings: updatedSettings(hideFromDock: isHidden),
                        isUITesting: isUITesting
                    ))
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_060, height: 720)
        .commands {
            ScanCommands()
        }

        MenuBarExtra(isInserted: $presentsMenuBarExtra) {
            MenuBarPopoverView()
                .environmentObject(appState)
                .environmentObject(menuBarManager)
                .preferredColorScheme(uiTestColorScheme)
        } label: {
            Image(systemName: menuBarIcon)
                .accessibilityLabel("SafeMac AV")
                .accessibilityIdentifier("safe-mac-menu-bar-item")
                .background(MainWindowPresentationBridge(
                    lifecycle: .shared,
                    openWindow: openWindow
                ))
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        if appState.isScanning || appState.isUpdatingSignatures {
            return "shield.lefthalf.filled"
        }
        return appState.protectionScore.score >= 80 ? "checkmark.shield.fill" : "shield.fill"
    }

    private var isUITesting: Bool {
        CommandLine.arguments.contains("--ui-testing")
    }

    private func updatedSettings(hideFromDock: Bool) -> AppSettings {
        var settings = appState.settings
        settings.hideFromDock = hideFromDock
        return settings
    }

    private var uiTestColorScheme: ColorScheme? {
#if DEBUG
        if CommandLine.arguments.contains("--force-light-appearance") {
            return .light
        }
        if CommandLine.arguments.contains("--force-dark-appearance") {
            return .dark
        }
#endif
        return nil
    }

}

private struct MainWindowPresentationBridge: NSViewRepresentable {
    let lifecycle: MainWindowPresentationLifecycle
    let openWindow: OpenWindowAction

    func makeNSView(context: Context) -> NSView {
        installAction()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        installAction()
    }

    private func installAction() {
        lifecycle.install {
            openWindow(id: ClamAVApp.mainWindowID)
        }
    }
}

private struct MainWindowIdentifier: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> MainWindowIdentifierView {
        MainWindowIdentifierView(identifier: identifier)
    }

    func updateNSView(_ nsView: MainWindowIdentifierView, context: Context) {
        nsView.identifierToApply = identifier
        nsView.applyIdentifier()
    }
}

private final class MainWindowIdentifierView: NSView {
    var identifierToApply: String

    init(identifier: String) {
        identifierToApply = identifier
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIdentifier()
    }

    func applyIdentifier() {
        window?.identifier = NSUserInterfaceItemIdentifier(identifierToApply)
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
