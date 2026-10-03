import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScanOverviewStatusView(status: appState.scanOverviewStatus) {
                    appState.performOverviewAction()
                }

                if case .notInstalled = appState.configManager.validateClamAVInstallation(using: appState.settings) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Install ClamAV using Homebrew in Terminal:")
                            .font(.callout)
                        Text("brew install clamav")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Already installed? Open engine settings and choose Auto-detect Paths.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        scanActions
                        VStack(alignment: .leading, spacing: 10) { scanButtons }
                    }
                    Text("Quick Scan checks Downloads and Desktop. Detected files are moved to quarantine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(spacing: 0) {
                    OverviewDetailRow(title: "Malware definitions", detail: definitionStatus, actionTitle: "View updates") {
                        appState.selectedTab = .updates
                    }
                    Divider()
                    OverviewDetailRow(title: "Automatic scanning", detail: automaticScanningStatus, actionTitle: "Configure") {
                        appState.selectedTab = .settings
                    }
                    Divider()
                    OverviewDetailRow(title: "Quarantine", detail: quarantineStatus, actionTitle: "Review files") {
                        appState.selectedTab = .quarantine
                    }
                    Divider()
                    OverviewDetailRow(title: "Last scan", detail: lastScanStatus, actionTitle: appState.lastScanResult == nil ? "Choose files" : "View results") {
                        if appState.lastScanResult == nil { appState.requestCustomScan() }
                        else { appState.presentLastScanResult() }
                    }
                }
                Text("Folder and download scanning run while SafeMac AV is open, including in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, GlassDesign.contentPadding)
            .padding(.vertical, 24)
        }
        .accessibilityIdentifier("dashboard-content")
    }

    private var scanActions: some View {
        HStack(spacing: 12) { scanButtons }
    }

    @ViewBuilder
    private var scanButtons: some View {
        Button("Choose Files or Folders…") { appState.requestCustomScan() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isScanning)
            .accessibilityIdentifier("overview-choose-files")
        Button("Quick Scan") {
            appState.selectedTab = .scan
            Task { await appState.startQuickScan() }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(appState.isScanning || !appState.configManager.validateClamAVInstallation(using: appState.settings).isReady)
        .accessibilityIdentifier("overview-quick-scan")
    }

    private var definitionStatus: String {
        if appState.isUpdatingSignatures { return "Updating…" }
        if appState.lastUpdateResult?.status == .failed { return "Last update failed. Open updates for details." }
        guard let date = appState.configManager.getSignatureInfo().lastUpdated else { return "Not available on this Mac" }
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var automaticScanningStatus: String {
        let downloads = appState.settings.autoScanDownloads
            ? (appState.fileWatcher.isWatching ? "New downloads: on" : "New downloads: unavailable")
            : "New downloads: off"
        let folders = appState.settings.monitoringEnabled
            ? (appState.isMonitoringActive ? "Selected folders: watching" : "Selected folders: unavailable")
            : "Selected folders: off"
        return "\(downloads) · \(folders)"
    }

    private var quarantineStatus: String {
        if appState.quarantineLoadError != nil { return "Could not load quarantined files" }
        let count = appState.quarantinedFiles.count
        return count == 0 ? "No files in quarantine" : "\(count) file\(count == 1 ? "" : "s") isolated"
    }

    private var lastScanStatus: String {
        guard let report = appState.lastScanResult else { return "No scans completed this session" }
        let outcome = report.isClean ? "No threats detected" : (report.threatsFound > 0 ? "\(report.threatsFound) detections" : "Needs attention")
        return "\(outcome) · \(report.filesScanned) files · \(report.endTime.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct OverviewDetailRow: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action).buttonStyle(.link)
                .fixedSize()
                .accessibilityLabel("\(actionTitle): \(title)")
        }
        .padding(.vertical, 15)
    }
}

@MainActor
extension AppState {
    var scanOverviewStatus: ScanOverviewStatus {
        ScanOverviewStatus.resolve(
            installation: configManager.validateClamAVInstallation(using: settings),
            isScanning: isScanning, isPaused: isScanPaused,
            isUpdating: isUpdatingSignatures, report: lastScanResult, scanError: scanError
        )
    }

    func presentLastScanResult() {
        isPreparingNewScan = false
        selectedTab = .scan
    }

    func performOverviewAction() {
        switch scanOverviewStatus.action {
        case .configureEngine: selectedTab = .settings
        case .updateDefinitions:
            selectedTab = .updates
            Task { await updateSignatures() }
        case .reviewScan: presentLastScanResult()
        case nil: break
        }
    }
}

/// Retained for compatibility with existing command tests. Review never enables a service.
@MainActor
enum DashboardScoreActionHandler {
    static func handle(_ component: ScoreComponent, appState: AppState) {
        switch component.action {
        case .configureClamAV, .enableMonitoring: appState.selectedTab = .settings
        case .updateSignatures:
            appState.selectedTab = .updates
            Task { await appState.updateSignatures() }
        case .reviewScan: appState.presentLastScanResult()
        case .openFinderSettings: FinderExtensionManager.openSystemSettings()
        case nil: break
        }
    }
}
