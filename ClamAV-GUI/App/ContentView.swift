import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 220)

            Divider()

            VStack(spacing: 0) {
                DetailHeader(tab: appState.selectedTab)
                Divider()
                DetailView()
                    .id(appState.selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .alert(
            "Settings Couldn’t Be Saved",
            isPresented: Binding(
                get: { appState.settingsSaveError != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.settingsSaveError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.settingsSaveError = nil
            }
        } message: {
            Text(appState.settingsSaveError ?? "")
                .accessibilityIdentifier("settings-save-error-message")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ClamAV")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(NavigationTab.allCases, id: \.self) { tab in
                SidebarButton(tab: tab, isSelected: appState.selectedTab == tab) {
                    appState.selectedTab = tab
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("primary-sidebar")
    }
}

struct SidebarButton: View {
    let tab: NavigationTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)

                Text(tab.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))

                Spacer()
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tab.sidebarAccessibilityIdentifier)
    }
}

struct DetailHeader: View {
    let tab: NavigationTab

    var body: some View {
        HStack {
            Label(tab.rawValue, systemImage: tab.icon)
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityIdentifier("screen-title-\(tab.accessibilitySlug)")

            Spacer()

            InstallationStatusBadge()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.selectedTab {
        case .dashboard:
            DashboardView()
        case .scan:
            ScanView()
        case .quarantine:
            QuarantineView()
        case .history:
            HistoryView()
        case .updates:
            UpdatesView()
        case .scheduler:
            SchedulerView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
