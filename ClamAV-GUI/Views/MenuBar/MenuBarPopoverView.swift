import AppKit
import SwiftUI

@MainActor
struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState

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
                .adaptiveGlassButton(prominent: true)
                .disabled(appState.isScanning)
                .accessibilityIdentifier("menu-bar-quick-scan")
                .accessibilityLabel(appState.isScanning ? "Quick Scan, scan already in progress" : "Start Quick Scan")

                Button {
                    Task { await appState.updateSignatures() }
                } label: {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
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

            Divider()

            Button(role: .destructive, action: quitAction) {
                Label("Quit SafeMac AV", systemImage: "power")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-bar-quit")
        }
        .padding(16)
        .frame(width: 330)
        .background(GlassCanvasBackground())
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
                Text("Protection at a glance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(appState.protectionScore.score)%")
                .font(.title3.weight(.semibold))
                .foregroundStyle(protectionColor)
                .accessibilityLabel("Protection score \(appState.protectionScore.score) percent")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            MenuBarStatusRow(
                icon: scanStatus.icon,
                tint: scanStatus.tint,
                title: "Scan",
                detail: scanStatus.detail,
                accessibilityIdentifier: "menu-bar-scan-status"
            )

            Divider()

            MenuBarStatusRow(
                icon: updateStatus.icon,
                tint: updateStatus.tint,
                title: "Signatures",
                detail: updateStatus.detail,
                accessibilityIdentifier: "menu-bar-update-status"
            )
        }
        .padding(12)
        .adaptiveGlassSurface(cornerRadius: GlassDesign.compactCornerRadius)
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
            let detail = report.isClean
                ? "Last scan clean · \(report.filesScanned) files"
                : "\(report.infectedFiles.count) threat\(report.infectedFiles.count == 1 ? "" : "s") found"
            return MenuBarStatus(
                icon: report.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: report.isClean ? .green : .red,
                detail: detail
            )
        }

        return MenuBarStatus(icon: "circle.dashed", tint: .secondary, detail: "Ready for a quick scan")
    }

    private var updateStatus: MenuBarStatus {
        if appState.isUpdatingSignatures {
            return MenuBarStatus(icon: "arrow.triangle.2.circlepath", tint: .blue, detail: "Updating signatures…")
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

    private var protectionColor: Color {
        if appState.protectionScore.score >= 80 { return .green }
        if appState.protectionScore.score >= 50 { return .orange }
        return .red
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
