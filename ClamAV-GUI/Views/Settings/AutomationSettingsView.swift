import SwiftUI

struct AutomationSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsSection(title: "Automatic Protection", icon: "bolt.shield") {
            Toggle("Scan new downloads immediately", isOn: savedBinding(\.autoScanDownloads))
            Toggle("Scan when Mac is idle", isOn: savedBinding(\.scanWhenIdle))
            Toggle("Pause scans on battery", isOn: savedBinding(\.pauseOnBattery))
            Toggle("Low impact mode", isOn: savedBinding(\.lowImpactMode))
        }
    }

    private func savedBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: {
                appState.settings[keyPath: keyPath] = $0
                appState.saveSettings()
            }
        )
    }
}
