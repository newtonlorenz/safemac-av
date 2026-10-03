import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            NavigationSplitView {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            } detail: {
                VStack(spacing: GlassDesign.canvasPadding) {
                    DetailHeader(tab: appState.selectedTab)

                    ActiveOperationBanner()

                    DetailView()
                        .id(appState.selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(GlassDesign.canvasPadding)
                .background(Color(nsColor: .windowBackgroundColor))
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
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
                .frame(width: 38, height: 38)
                .shadow(color: Color.accentColor.opacity(0.28), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("SafeMac AV")
                    .font(.headline)
                Text("Scan locally. Stay in control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

                Text(tab.displayTitle)
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
        Button {
            appState.selectedTab = .dashboard
        } label: {
            Label(appState.scanOverviewStatus.title, systemImage: appState.scanOverviewStatus.symbol)
                .font(.caption)
                .foregroundStyle(appState.scanOverviewStatus.tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(8)
        .accessibilityLabel("Overview: \(appState.scanOverviewStatus.title)")
    }
}

struct DetailHeader: View {
    let tab: NavigationTab

    var body: some View {
        HStack {
            Text(tab.displayTitle)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("screen-title-\(tab.accessibilitySlug)")
            Spacer()
        }
        .padding(.horizontal, GlassDesign.contentPadding)
        .padding(.top, 12)
        .accessibilityIdentifier("detail-header")
    }
}

private struct ActiveOperationBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            if appState.isScanning && appState.selectedTab != .scan {
                operationRow(
                    title: appState.isScanPaused ? "Scan paused" : "Scan in progress",
                    detail: "\(appState.currentScanProgress?.filesScanned ?? 0) files checked",
                    action: "View scan", tab: .scan,
                    running: !appState.isScanPaused
                )
            }
            if appState.isUpdatingSignatures && appState.selectedTab != .updates {
                operationRow(title: "Updating malware definitions", detail: nil, action: "View update", tab: .updates, running: true)
            } else if appState.lastUpdateResult?.status == .failed && appState.selectedTab != .updates {
                operationRow(title: "Definitions update failed", detail: "Open updates to review the error and try again.", action: "Review update", tab: .updates, running: false)
            }
        }
    }

    private func operationRow(title: String, detail: String?, action: String, tab: NavigationTab, running: Bool) -> some View {
        HStack(spacing: 10) {
            if running {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            Button(action) { appState.selectedTab = tab }.buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, GlassDesign.contentPadding)
        .accessibilityIdentifier(tab == .scan ? "active-scan-banner" : "active-update-banner")
    }
}

extension NavigationTab {
    var displayTitle: String {
        switch self {
        case .dashboard: return "Overview"
        case .scheduler: return "Scheduled scans"
        case .updates: return "Definition updates"
        case .logs: return "Diagnostics"
        default: return rawValue
        }
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
