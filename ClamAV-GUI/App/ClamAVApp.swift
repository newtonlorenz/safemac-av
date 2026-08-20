import SwiftUI

@main
struct ClamAVApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var didHandleInitialLaunch = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(uiTestColorScheme)
                .task {
                    await handleInitialLaunch()
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    Task { await appState.drainExternalScanRequests() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_060, height: 720)
        .commands {
            ScanCommands()
        }
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
