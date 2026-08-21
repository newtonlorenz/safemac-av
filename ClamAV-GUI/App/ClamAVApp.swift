import AppKit
import SwiftUI

@main
struct ClamAVApp: App {
    static let mainWindowID = "main-window"

    @NSApplicationDelegateAdaptor(MenuBarApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState: AppState
    @StateObject private var menuBarManager = MenuBarManager()
    @StateObject private var initialLaunchHandler = InitialLaunchHandler()
    private let launchMode: LaunchMode
    @State private var presentsMenuBarExtra: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    init() {
        let launchMode = LaunchModeParser.parse(arguments: CommandLine.arguments)
        self.launchMode = launchMode
        _presentsMenuBarExtra = State(initialValue: launchMode.presentsUserInterface)

        let appState = AppState(
            startsInteractiveBackgroundServices: launchMode.startsInteractiveBackgroundServices
        )
        _appState = StateObject(wrappedValue: appState)
        ScheduledSignatureUpdateLifecycle.shared.install {
            await appState.runScheduledSignatureUpdate()
        }
    }

    var body: some Scene {
        WindowGroup("SafeMac AV", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(uiTestColorScheme)
                .background(MainWindowIdentifier(identifier: Self.mainWindowID))
                .task {
                    menuBarManager.applyDockVisibility(hidden: currentLaunchModeHidesDock)
                    await handleInitialLaunch()
                }
                .onChange(of: appState.settings.hideFromDock) { isHidden in
                    menuBarManager.applyDockVisibility(hidden: launchMode.hidesDock(
                        settings: updatedSettings(hideFromDock: isHidden),
                        isUITesting: isUITesting
                    ))
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active, launchMode.runsActiveSceneMaintenance else { return }
                    appState.refreshProtectionScore()
                    appState.refreshLaunchAtLoginStatus()
                    Task { await appState.drainExternalScanRequests() }
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
                .task {
                    await handleInitialLaunch()
                }
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

    private var isAutomatedTestLaunch: Bool {
        isUITesting
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var currentLaunchModeHidesDock: Bool {
        launchMode.hidesDock(settings: appState.settings, isUITesting: isUITesting)
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

    @MainActor
    private func handleInitialLaunch() async {
        await initialLaunchHandler.handle(
            launchMode: launchMode,
            shouldPresentInteractiveMainWindow: !currentLaunchModeHidesDock,
            presentInteractiveMainWindow: {
                menuBarManager.activateMainWindow {
                    openWindow(id: Self.mainWindowID)
                }
            },
            drainExternalScanRequests: {
                if SignatureScheduleReconciliationPolicy.shouldReconcile(
                    bundleURL: Bundle.main.bundleURL,
                    isAutomatedTest: isAutomatedTestLaunch
                ) {
                    appState.reconcileSignatureUpdateSchedule()
                }
                await appState.drainExternalScanRequests()
            },
            runScheduledScan: { jobID, paths in
                await appState.runScheduledScan(jobID: jobID, paths: paths)
            }
        )
    }
}

@MainActor
final class InitialLaunchHandler: ObservableObject {
    private var didHandleInitialLaunch = false

    func handle(
        launchMode: LaunchMode,
        shouldPresentInteractiveMainWindow: Bool,
        presentInteractiveMainWindow: () -> Void,
        drainExternalScanRequests: () async -> Void,
        runScheduledScan: (UUID?, [URL]) async -> Void
    ) async {
        guard !didHandleInitialLaunch else { return }
        didHandleInitialLaunch = true

        switch launchMode {
        case .interactive:
            if shouldPresentInteractiveMainWindow {
                presentInteractiveMainWindow()
            }
            await drainExternalScanRequests()
        case .scheduledScan(let jobID, let paths):
            await runScheduledScan(jobID, paths)
        case .scheduledSignatureUpdate:
            break
        }
    }
}

private struct MainWindowIdentifier: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        applyIdentifier(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyIdentifier(to: nsView)
    }

    private func applyIdentifier(to view: NSView) {
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
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

extension Notification.Name {
    static let startQuickScan = Notification.Name("startQuickScan")
    static let startCustomScan = Notification.Name("startCustomScan")
    static let updateSignatures = Notification.Name("updateSignatures")
}
