import SwiftUI

struct AutomationSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            SettingsSection(title: "Automatic Protection", icon: "bolt.shield") {
                Toggle("Scan new downloads immediately", isOn: savedBinding(\.autoScanDownloads))
                Toggle("Scan when Mac is idle", isOn: savedBinding(\.scanWhenIdle))
                Toggle("Pause scans on battery", isOn: savedBinding(\.pauseOnBattery))
                Toggle("Low impact mode", isOn: savedBinding(\.lowImpactMode))
            }

            SettingsSection(title: "Menu Bar & Dock", icon: "menubar.rectangle") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Hide SafeMac AV from the Dock", isOn: savedBinding(\.hideFromDock))
                        .accessibilityIdentifier("hide-from-dock-toggle")

                    Text("SafeMac AV keeps running in the menu bar. You can scan, update signatures, or reopen the main window at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func savedBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: {
                var updatedSettings = appState.settings
                updatedSettings[keyPath: keyPath] = $0
                appState.settings = updatedSettings
                appState.saveSettings()
            }
        )
    }
}
