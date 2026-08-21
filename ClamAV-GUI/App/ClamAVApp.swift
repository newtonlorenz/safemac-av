import AppKit
import SwiftUI

@main
struct ClamAVApp: App {
    static let mainWindowID = "main-window"

    @NSApplicationDelegateAdaptor(MenuBarApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState = AppState()
    @StateObject private var menuBarManager = MenuBarManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var didHandleInitialLaunch = false

    var body: some Scene {
        WindowGroup("SafeMac AV", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(uiTestColorScheme)
                .task {
                    menuBarManager.applyDockVisibility(hidden: shouldHideDock)
                    await handleInitialLaunch()
                }
                .onChange(of: appState.settings.hideFromDock) { isHidden in
                    menuBarManager.applyDockVisibility(hidden: isHidden && !isUITesting)
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
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

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(appState)
                .environmentObject(menuBarManager)
                .preferredColorScheme(uiTestColorScheme)
        } label: {
            Image(systemName: menuBarIcon)
                .accessibilityLabel("SafeMac AV")
                .accessibilityIdentifier("safe-mac-menu-bar-item")
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

    private var shouldHideDock: Bool {
        appState.settings.hideFromDock && !isUITesting
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
        guard !didHandleInitialLaunch else { return }
        didHandleInitialLaunch = true

        switch LaunchModeParser.parse(arguments: CommandLine.arguments) {
        case .interactive:
            await appState.drainExternalScanRequests()
        case .scheduledScan(let jobID, let paths):
            await appState.runScheduledScan(jobID: jobID, paths: paths)
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
