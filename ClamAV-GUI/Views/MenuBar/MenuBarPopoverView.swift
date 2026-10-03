import AppKit
import SwiftUI

@MainActor
struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var softwareUpdateManager: SoftwareUpdateManager

    private let showMainWindowAction: @MainActor (NavigationTab?) -> Void
    private let quitAction: @MainActor () -> Void

    init(
        showMainWindowAction: (@MainActor (NavigationTab?) -> Void)? = nil,
        quitAction: (@MainActor () -> Void)? = nil
    ) {
        self.showMainWindowAction = showMainWindowAction ?? {
            MainWindowControllerRegistry.shared.showMainWindow(selecting: $0)
        }
        self.quitAction = quitAction ?? { NSApplication.shared.terminate(nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            statusCard

            HStack(spacing: 10) {
                Button {
                    Task { await appState.startQuickScan() }
                } label: {
                    Label("Quick Scan", systemImage: "bolt.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isScanning)
                .accessibilityIdentifier("menu-bar-quick-scan")
                .accessibilityLabel(appState.isScanning ? "Quick Scan, scan already in progress" : "Start Quick Scan")

                Button {
                    Task { await appState.updateSignatures() }
                } label: {
                    Label("Definitions", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(appState.isUpdatingSignatures)
                .accessibilityIdentifier("menu-bar-update-signatures")
                .accessibilityLabel(appState.isUpdatingSignatures ? "Update Signatures, update in progress" : "Update Signatures")
            }

            Divider()

            Button {
                showMainWindow(tab: nil)
            } label: {
                Label("Open SafeMac AV", systemImage: "macwindow")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-bar-open-main-window")

            Button {
                showMainWindow(tab: .settings)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-bar-open-settings")

            Button {
                softwareUpdateManager.checkForUpdates()
            } label: {
                Label("Check for App Updates", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(!softwareUpdateManager.isConfigured)
            .accessibilityIdentifier("menu-bar-check-for-app-updates")
            .accessibilityLabel(updateAccessibilityLabel)

            Divider()

            Button(role: .destructive, action: quitAction) {
                Label("Quit SafeMac AV", systemImage: "power")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-bar-quit")
        }
        .padding(16)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-popover")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("SafeMac AV")
                    .font(.headline)
                Text("Local malware scanning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                let destination = MenuBarScanStatusRoute.resolve(
                    isScanning: appState.isScanning, hasReport: appState.lastScanResult != nil,
                    hasScanError: appState.scanError != nil, overviewKind: appState.scanOverviewStatus.kind
                )
                if destination == .scan { appState.presentLastScanResult() }
                showMainWindow(tab: destination)
            } label: {
                MenuBarStatusRow(
                    icon: scanStatus.icon,
                    tint: scanStatus.tint,
                    title: "Scan",
                    detail: scanStatus.detail,
                    accessibilityIdentifier: "menu-bar-scan-status"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View scan: \(scanStatus.detail)")

            Divider()

            Button { showMainWindow(tab: .updates) } label: {
                MenuBarStatusRow(
                    icon: updateStatus.icon,
                    tint: updateStatus.tint,
                    title: "Definitions",
                    detail: updateStatus.detail,
                    accessibilityIdentifier: "menu-bar-update-status"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View definition updates: \(updateStatus.detail)")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var scanStatus: MenuBarStatus {
        if let progress = appState.currentScanProgress, appState.isScanning {
            return MenuBarStatus(
                icon: "waveform.path.ecg",
                tint: .blue,
                detail: "\(progress.status.rawValue) · \(progress.filesScanned) files"
            )
        }

        if let error = appState.scanError {
            return MenuBarStatus(icon: "exclamationmark.triangle.fill", tint: .orange, detail: error)
        }

        if let report = appState.lastScanResult {
            if report.threatsFound == 0 && !report.completedWithoutErrors {
                return MenuBarStatus(icon: "exclamationmark.triangle.fill", tint: .orange, detail: "Last scan needs attention · \(report.filesScanned) files")
            }
            let detail = report.isClean
                ? "No threats detected · \(report.filesScanned) files"
                : "\(report.threatsFound) threat\(report.threatsFound == 1 ? "" : "s") found"
            return MenuBarStatus(
                icon: report.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: report.isClean ? .green : .red,
                detail: detail
            )
        }

        return MenuBarStatus(icon: "circle.dashed", tint: .secondary, detail: appState.scanOverviewStatus.title)
    }

    private var updateStatus: MenuBarStatus {
        if appState.isUpdatingSignatures {
            return MenuBarStatus(icon: "arrow.triangle.2.circlepath", tint: .blue, detail: "Updating definitions…")
        }

        if let result = appState.lastUpdateResult {
            return MenuBarStatus(
                icon: result.status == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tint: result.status == .failed ? .red : .green,
                detail: result.message
            )
        }

        return MenuBarStatus(icon: "shield.checkered", tint: .secondary, detail: "No update run this session")
    }

    private var updateAccessibilityLabel: String {
        softwareUpdateManager.isConfigured
            ? "Check for SafeMac AV app updates"
            : "App updates are not configured"
    }

    private func showMainWindow(tab: NavigationTab?) {
        showMainWindowAction(tab)
    }
}

private struct MenuBarStatus {
    let icon: String
    let tint: Color
    let detail: String
}

private struct MenuBarStatusRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let accessibilityIdentifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(detail)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Match the destination to the outcome shown by the scan status row.
enum MenuBarScanStatusRoute {
    static func resolve(isScanning: Bool, hasReport: Bool, hasScanError: Bool, overviewKind: ScanOverviewStatus.Kind) -> NavigationTab {
        if isScanning || hasReport || hasScanError { return .scan }
        switch overviewKind {
        case .setupNeeded: return .dashboard
        case .definitionsNeeded, .updating: return .updates
        default: return .scan
        }
    }
}
