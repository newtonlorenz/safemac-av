import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            GlassCanvasBackground()

            NavigationSplitView {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 280)
            } detail: {
                VStack(spacing: GlassDesign.canvasPadding) {
                    DetailHeader(tab: appState.selectedTab)

                    DetailView()
                        .id(appState.selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(GlassDesign.canvasPadding)
                .background(GlassCanvasBackground())
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 800, minHeight: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-shell")
        .accessibilityLabel(uiTestAppearanceLabel)
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

    private var uiTestAppearanceLabel: Text {
        guard CommandLine.arguments.contains("--ui-testing") else {
            return Text("")
        }
        return Text(colorScheme == .dark ? "dark" : "light")
    }
}

struct Sidebar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SidebarBrand()

            VStack(spacing: 6) {
                ForEach(NavigationTab.allCases) { tab in
                    SidebarButton(tab: tab, isSelected: appState.selectedTab == tab) {
                        appState.selectedTab = tab
                    }
                }
            }

            Spacer()

            SidebarProtectionSummary()
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("primary-sidebar")
    }
}

private struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.gradient)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: Color.accentColor.opacity(0.28), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("ClamAV")
                    .font(.headline)
                Text("Security Center")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarButton: View {
    let tab: NavigationTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)

                Text(tab.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))

                Spacer()
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
                        lineWidth: 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(tab.sidebarAccessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }
}

private struct SidebarProtectionSummary: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let score = appState.protectionScore.score

        HStack(spacing: 10) {
            Image(systemName: score >= 80 ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .foregroundStyle(score >= 80 ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("Protection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(score)%")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer()
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: GlassDesign.compactCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protection score \(score) percent")
    }
}

struct DetailHeader: View {
    let tab: NavigationTab

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tab.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            Text(tab.rawValue)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("screen-title-\(tab.accessibilitySlug)")

            Spacer()

            InstallationStatusBadge()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .adaptiveGlassSurface(cornerRadius: GlassDesign.chromeCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-header")
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
