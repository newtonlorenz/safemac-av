import ServiceManagement
import SwiftUI

struct AutomationSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsSection(title: "Automatic scanning", icon: "arrow.down.doc") {
            Toggle("Scan new downloads", isOn: savedBinding(\.autoScanDownloads))
                .accessibilityIdentifier("scan-downloads-toggle")
            Text("Checks new files in Downloads while SafeMac AV is running. Other scans finish before queued downloads are checked.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Toggle("Reduce impact on other apps", isOn: savedBinding(\.lowImpactMode))
            Text("Runs scans at a lower priority. Scans may take longer and still run on battery power.")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("automation-availability-note")
        }
    }

    private func savedBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: {
                var settings = appState.settings
                settings[keyPath: keyPath] = $0
                _ = appState.applySettings(settings)
            }
        )
    }
}

struct AppBehaviourSettingsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsSection(title: "Login, menu bar and Dock", icon: "menubar.rectangle") {
            Toggle("Open SafeMac AV at login", isOn: Binding(
                get: { appState.launchAtLoginStatus.isRequested },
                set: { appState.setLaunchAtLoginEnabled($0) }
            ))
            .accessibilityIdentifier("launch-at-login-toggle")
            Label(appState.launchAtLoginStatus.title, systemImage: appState.launchAtLoginStatus.symbolName)
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("launch-at-login-status")
            if let detail = appState.launchAtLoginStatus.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if appState.launchAtLoginStatus == .requiresApproval {
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = appState.launchAtLoginError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("launch-at-login-error")
            }
            Divider()
            Toggle("Hide SafeMac AV from the Dock", isOn: Binding(
                get: { appState.settings.hideFromDock },
                set: {
                    var settings = appState.settings
                    settings.hideFromDock = $0
                    _ = appState.applySettings(settings)
                }
            ))
            .accessibilityIdentifier("hide-from-dock-toggle")
            Text("Use the menu bar to reopen SafeMac AV, start a scan or update definitions. Closing the window keeps the app running.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
