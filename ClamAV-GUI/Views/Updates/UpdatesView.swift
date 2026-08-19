import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isUpdating = false
    @State private var updateError: String?

    var signatureInfo: SignatureInfo {
        appState.configManager.getSignatureInfo()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SignatureStatusCard(info: signatureInfo)

                UpdateActionCard(
                    isUpdating: isUpdating,
                    lastResult: appState.lastUpdateResult,
                    onUpdate: performUpdate
                )

                if let error = updateError {
                    ErrorCard(message: error) {
                        updateError = nil
                    }
                }

                AutoUpdateSettingsCard()
            }
            .padding()
        }
    }

    private func performUpdate() {
        isUpdating = true
        updateError = nil

        Task {
            await appState.updateSignatures()
            if appState.lastUpdateResult?.status == .failed {
                updateError = appState.lastUpdateResult?.message
            }
            isUpdating = false
        }
    }
}

struct SignatureStatusCard: View {
    let info: SignatureInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Signature Database")
                    .font(.headline)
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                SignatureVersionItem(
                    name: "Main",
                    version: info.mainVersion
                )

                SignatureVersionItem(
                    name: "Daily",
                    version: info.dailyVersion
                )

                SignatureVersionItem(
                    name: "Bytecode",
                    version: info.bytecodeVersion
                )
            }

            if let lastUpdated = info.lastUpdated {
                HStack {
                    Text("Last Updated:")
                        .foregroundColor(.secondary)
                    Text(lastUpdated, style: .relative)
                    Text("ago")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct SignatureVersionItem: View {
    let name: String
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(version)
                .font(.headline)
        }
    }
}

struct UpdateActionCard: View {
    let isUpdating: Bool
    let lastResult: UpdateResult?
    let onUpdate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isUpdating {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Updating signatures...")
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: onUpdate) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Update Signatures Now")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
            }

            if let result = lastResult {
                UpdateResultBanner(result: result)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct UpdateResultBanner: View {
    let result: UpdateResult

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(iconColor)

            VStack(alignment: .leading) {
                Text(result.status.rawValue)
                    .fontWeight(.medium)
                Text(result.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(result.timestamp, style: .relative)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(8)
    }

    private var iconName: String {
        switch result.status {
        case .success: return "checkmark.circle.fill"
        case .upToDate: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .inProgress: return "arrow.clockwise"
        }
    }

    private var iconColor: Color {
        switch result.status {
        case .success, .upToDate: return .green
        case .failed: return .red
        case .inProgress: return .blue
        }
    }

    private var backgroundColor: Color {
        switch result.status {
        case .success, .upToDate: return Color.green.opacity(0.1)
        case .failed: return Color.red.opacity(0.1)
        case .inProgress: return Color.blue.opacity(0.1)
        }
    }
}

struct ErrorCard: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.caption)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}

struct AutoUpdateSettingsCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Automatic Updates")
                    .font(.headline)
            }

            Toggle("Enable automatic signature updates", isOn: Binding(
                get: { appState.settings.autoUpdateSignatures },
                set: {
                    appState.settings.autoUpdateSignatures = $0
                    appState.saveSettings()
                }
            ))

            if appState.settings.autoUpdateSignatures {
                HStack {
                    Text("Update frequency:")
                    Picker("", selection: Binding(
                        get: { appState.settings.updateSchedule?.frequency ?? .daily },
                        set: {
                            var schedule = appState.settings.updateSchedule ?? .daily9am
                            schedule.frequency = $0
                            appState.settings.updateSchedule = schedule
                            appState.saveSettings()
                        }
                    )) {
                        Text("Daily").tag(ScheduleFrequency.daily)
                        Text("Weekly").tag(ScheduleFrequency.weekly)
                    }
                    .frame(width: 120)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

#Preview {
    UpdatesView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
