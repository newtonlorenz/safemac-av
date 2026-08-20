import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            AdaptiveGlassEffectContainer(spacing: 20) {
                VStack(spacing: 20) {
                    ProtectionScoreView(score: appState.protectionScore) { component in
                        DashboardScoreActionHandler.handle(component, appState: appState)
                    }

                    StatusCardsSection()

                    QuickActionsSection()

                    if let lastScan = appState.lastScanResult {
                        LastScanSection(report: lastScan)
                    }
                }
                .frame(maxWidth: GlassDesign.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, GlassDesign.contentPadding)
                .padding(.vertical, 16)
            }
        }
        .accessibilityIdentifier("dashboard-content")
    }
}

@MainActor
enum DashboardScoreActionHandler {
    static func handle(_ component: ScoreComponent, appState: AppState) {
        switch component.action {
        case .configureClamAV:
            appState.selectedTab = .settings
        case .updateSignatures:
            Task { await appState.updateSignatures() }
        case .runQuickScan:
            Task { await appState.startQuickScan() }
        case .enableMonitoring:
            appState.settings.monitoringEnabled = true
            appState.saveSettings()
        case .openFinderSettings:
            FinderExtensionManager.openSystemSettings()
        case nil:
            break
        }
    }
}

struct StatusCardsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 16)
        ], spacing: 16) {
            StatusCard(
                title: "ClamAV Status",
                value: installationStatus.message,
                icon: "checkmark.shield",
                color: installationStatus.isReady ? .green : .orange
            )

            StatusCard(
                title: "Signatures",
                value: signatureStatus,
                icon: "doc.text",
                color: .blue
            )

            StatusCard(
                title: "Quarantine",
                value: "\(appState.quarantinedFiles.count) files",
                icon: "lock.shield",
                color: appState.quarantinedFiles.isEmpty ? .gray : .orange
            )

            StatusCard(
                title: "Last Scan",
                value: lastScanStatus,
                icon: "magnifyingglass",
                color: lastScanColor
            )

            StatusCard(
                title: "Last Update",
                value: lastUpdateStatus,
                icon: "arrow.down.circle",
                color: .blue
            )

            StatusCard(
                title: "Monitoring",
                value: appState.settings.monitoringEnabled ? "Active" : "Disabled",
                icon: "eye",
                color: appState.settings.monitoringEnabled ? .green : .gray
            )
        }
    }

    private var installationStatus: ClamAVInstallationStatus {
        appState.configManager.validateClamAVInstallation()
    }

    private var signatureStatus: String {
        let info = appState.configManager.getSignatureInfo()
        if let date = info.lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "Not available"
    }

    private var lastScanStatus: String {
        guard let scan = appState.lastScanResult else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: scan.endTime, relativeTo: Date())
    }

    private var lastScanColor: Color {
        guard let scan = appState.lastScanResult else { return .gray }
        return scan.isClean ? .green : .red
    }

    private var lastUpdateStatus: String {
        guard let update = appState.lastUpdateResult else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: update.timestamp, relativeTo: Date())
    }
}

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: Circle())

                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .adaptiveGlassSurface(tint: color.opacity(0.08))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

struct QuickActionsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)
            ], spacing: 12) {
                QuickActionButton(
                    title: "Scan Downloads",
                    icon: "arrow.down.doc",
                    color: .blue
                ) {
                    Task {
                        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                        await appState.startScan(paths: [downloadsURL], options: .default)
                    }
                }

                QuickActionButton(
                    title: "Scan Home",
                    icon: "house",
                    color: .purple
                ) {
                    Task {
                        let homeURL = FileManager.default.homeDirectoryForCurrentUser
                        await appState.startScan(paths: [homeURL], options: .default)
                    }
                }

                QuickActionButton(
                    title: "Update Signatures",
                    icon: "arrow.clockwise",
                    color: .green
                ) {
                    Task {
                        await appState.updateSignatures()
                    }
                }

                QuickActionButton(
                    title: "View Quarantine",
                    icon: "lock.shield",
                    color: .orange
                ) {
                    appState.selectedTab = .quarantine
                }
            }
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: Circle())
                Text(title)
                    .font(.subheadline.weight(.medium))

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .foregroundColor(color)
            .adaptiveGlassSurface(
                tint: color.opacity(0.10),
                interactive: true,
                cornerRadius: GlassDesign.compactCornerRadius
            )
        }
        .buttonStyle(.plain)
    }
}

struct LastScanSection: View {
    let report: ScanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last Scan Results")
                    .font(.headline)
                Spacer()
                Text(report.endTime, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 20) {
                ScanStatView(title: "Files Scanned", value: "\(report.filesScanned)", color: .blue)
                ScanStatView(title: "Threats Found", value: "\(report.infectedFiles.count)", color: report.isClean ? .green : .red)
                ScanStatView(title: "Duration", value: formatDuration(report.duration), color: .gray)
            }

            if !report.infectedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected Threats:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(report.infectedFiles.prefix(5)) { file in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(file.threatName)
                                .font(.caption)
                            Spacer()
                            Text((file.path as NSString).lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if report.infectedFiles.count > 5 {
                        Text("... and \(report.infectedFiles.count - 5) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .adaptiveGlassSurface()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

struct ScanStatView: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct InstallationStatusBadge: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let status = appState.configManager.validateClamAVInstallation()

        HStack(spacing: 4) {
            Circle()
                .fill(status.isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(status.isReady ? "Ready" : "Setup Required")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            (status.isReady ? Color.green : Color.orange).opacity(0.11),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    (status.isReady ? Color.green : Color.orange).opacity(0.20),
                    lineWidth: 0.75
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.isReady ? "ClamAV is ready" : "ClamAV setup required")
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
