import ServiceManagement
import SwiftUI

struct AutomationSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsSection(title: "Automatic Protection", icon: "bolt.shield") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Launch SafeMac AV at login",
                    isOn: Binding(
                        get: { appState.launchAtLoginStatus.isRequested },
                        set: { appState.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(appState.launchAtLoginStatus == .unavailable)
                .accessibilityIdentifier("launch-at-login-toggle")

                HStack(spacing: 6) {
                    Image(systemName: appState.launchAtLoginStatus.symbolName)
                        .foregroundStyle(launchStatusColor)
                    Text(appState.launchAtLoginStatus.title)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("launch-at-login-status")
                }
                .font(.caption)

                if let detail = appState.launchAtLoginStatus.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.launchAtLoginStatus == .requiresApproval {
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                }

                if let error = appState.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("launch-at-login-error")
                }
            }

            Divider()

            Toggle("Scan new downloads immediately", isOn: savedBinding(\.autoScanDownloads))
            Toggle("Scan when Mac is idle", isOn: savedBinding(\.scanWhenIdle))
            Toggle("Pause scans on battery", isOn: savedBinding(\.pauseOnBattery))
            Toggle("Low impact mode", isOn: savedBinding(\.lowImpactMode))
        }
    }

    private var launchStatusColor: Color {
        switch appState.launchAtLoginStatus {
        case .enabled:
            return .green
        case .requiresApproval:
            return .orange
        case .disabled, .unavailable:
            return .secondary
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
