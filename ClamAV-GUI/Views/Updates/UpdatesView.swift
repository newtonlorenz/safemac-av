import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var appState: AppState

    @State private var configurationStatus: FreshclamConfigurationStatus = .ready
    @State private var folderOpenError: String?

    private var signatureInfo: SignatureInfo { appState.configManager.getSignatureInfo() }
    private var updaterAvailable: Bool { FileManager.default.isExecutableFile(atPath: appState.settings.freshclamPath) }
    private var canUpdateDefinitions: Bool {
        updaterAvailable && configurationStatus != .example && configurationStatus != .unreadable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Malware definitions", icon: "shield") {
                    DefinitionFreshnessSummary(info: signatureInfo)
                    HStack(spacing: 12) {
                        Button(appState.isUpdatingSignatures ? "Updating…" : "Update Definitions") {
                            Task { await appState.updateSignatures() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isUpdatingSignatures || !canUpdateDefinitions)
                        .accessibilityIdentifier("update-definitions-button")
                        if appState.isUpdatingSignatures {
                            ProgressView().controlSize(.small).accessibilityLabel("Updating malware definitions")
                        } else if !updaterAvailable {
                            Button("Open Engine Setup") { appState.selectedTab = .settings }
                        }
                    }
                    if !updaterAvailable {
                        Text("Set up ClamAV in Settings before downloading definitions.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if updaterAvailable && configurationStatus != .ready {
                        configurationSetupGuidance
                    }
                    if let result = appState.lastUpdateResult, result.status != .inProgress {
                        Divider()
                        UpdateResultBanner(result: result)
                        if result.status == .failed && configurationStatus == .ready {
                            configurationHelpActions
                        }
                    }
                    DisclosureGroup("Database details") {
                        VStack(spacing: 10) {
                            SignatureVersionItem(name: "Main database", version: signatureInfo.mainVersion)
                            SignatureVersionItem(name: "Daily definitions", version: signatureInfo.dailyVersion)
                            SignatureVersionItem(name: "Bytecode database", version: signatureInfo.bytecodeVersion)
                        }
                        .padding(.top, 10)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("definition-database-details")
                }
                AutoUpdateSettingsCard()
                SettingsSection(title: "SafeMac AV app", icon: "app") {
                    Text("App updates are separate from malware definitions. They update SafeMac AV itself; the ClamAV engine is managed through your existing installation.")
                        .font(.callout).foregroundStyle(.secondary)
                    if SoftwareUpdateManager.hasRequiredSparkleConfiguration(bundle: .main) {
                        Button("Check for App Updates…") {
                            NotificationCenter.default.post(name: .checkForAppUpdates, object: nil)
                        }
                        .accessibilityIdentifier("check-for-app-updates-button")
                    } else {
                        Text("Automatic app updates are not configured for this build.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(GlassDesign.contentPadding)
        }
        .accessibilityIdentifier("updates-content")
        .onAppear(perform: refreshConfiguration)
        .onChange(of: appState.settings.configDirectory) { _ in refreshConfiguration() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshConfiguration()
        }
    }

    private var configurationSetupGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(configurationStatus == .missing ? "Check the update configuration" : "Finish configuring definition updates")
                .font(.callout.weight(.medium))
            Text(configurationExplanation).font(.callout).foregroundStyle(.secondary)
            Text(appState.settings.configDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            configurationHelpActions
        }
        .accessibilityIdentifier("definition-configuration-setup")
    }

    private var configurationExplanation: String {
        switch configurationStatus {
        case .missing:
            return "This folder has no freshclam.conf. You can try updating with ClamAV’s installation defaults. If setup is needed, copy freshclam.conf.sample to freshclam.conf, then comment out or remove the standalone Example line. Keep any existing configuration."
        case .example:
            return "Open freshclam.conf in a text editor and comment out or remove the standalone Example line. Keep the rest of your configuration, then return here to update."
        case .unreadable:
            return "ClamAV’s freshclam.conf cannot be read. Check that it is a text file and that your account can read it, then return here to update."
        case .ready:
            return ""
        }
    }

    private var configurationHelpActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Open Configuration Folder") {
                    let folder = URL(fileURLWithPath: appState.settings.configDirectory, isDirectory: true)
                    folderOpenError = NSWorkspace.shared.open(folder) ? nil : "The configuration folder could not be opened. Check its location in Settings."
                }
                .accessibilityIdentifier("open-definition-configuration-folder")
                Link("ClamAV Setup Guide", destination: URL(string: "https://docs.clamav.net/manual/Usage/Configuration.html")!)
            }
            if let folderOpenError { Text(folderOpenError).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func refreshConfiguration() {
        configurationStatus = FreshclamConfigurationStatus.inspect(directory: appState.settings.configDirectory)
        folderOpenError = nil
    }
}

private struct DefinitionFreshnessSummary: View {
    let info: SignatureInfo
    private var missing: Bool { info.mainVersion == "Unknown" }
    private var age: Int? { info.lastUpdated.map { max(0, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0) } }
    private var needsAttention: Bool { missing || age == nil || (age ?? 0) > 7 }
    private var title: String {
        if missing { return "Definitions are not installed" }
        guard let age else { return "Last update date is unavailable" }
        if age == 0 { return "Definitions updated today" }
        return "Definitions updated \(age) day\(age == 1 ? "" : "s") ago"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.title2).foregroundStyle(needsAttention ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(missing ? "Download the definitions ClamAV needs before running a scan." : "Keep definitions updated so ClamAV can recognise newly identified threats.")
                    .font(.callout).foregroundStyle(.secondary)
                if let date = info.lastUpdated {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SignatureVersionItem: View {
    let name: String
    let version: String
    var body: some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(version == "Unknown" ? "Not available" : version).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct UpdateResultBanner: View {
    let result: UpdateResult
    private var title: String {
        switch result.status {
        case .success: return "Definitions updated"
        case .upToDate: return "Definitions are already up to date"
        case .failed: return "Definitions could not be updated"
        case .inProgress: return "Updating definitions…"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.status == .failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(result.status == .failed ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.medium))
                if result.status == .failed {
                    Text(result.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(result.timestamp, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("definition-update-result")
    }
}

struct AutoUpdateSettingsCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsSection(title: "Automatic definition updates", icon: "calendar") {
            Text("Choose when the background helper checks for new definitions, even when this window is closed.")
                .font(.callout).foregroundStyle(.secondary)

            if let configuredEnabled {
                Toggle("Update definitions automatically", isOn: Binding(
                    get: { configuredEnabled },
                    set: { enabled in
                        apply(enabled: enabled, schedule: currentSchedule)
                    }
                ))
                .accessibilityLabel("Automatically update malware signatures")
                .accessibilityIdentifier("automatic-signature-updates-toggle")
            } else {
                Label(
                    "The malware signature schedule needs review before its status can be shown.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityLabel("Malware signature schedule status needs review")

                Button("Review Schedule") {
                    appState.reconcileSignatureUpdateSchedule()
                }
                .accessibilityLabel("Review malware signature update schedule")
                .accessibilityIdentifier("signature-update-schedule-review")
            }

            if configuredEnabled == true {
                HStack {
                    Text("Update frequency:")
                    Picker("", selection: Binding(
                        get: { currentSchedule.frequency },
                        set: { frequency in
                            var schedule = currentSchedule
                            schedule.frequency = frequency
                            if frequency == .weekly, schedule.dayOfWeek == nil { schedule.dayOfWeek = 2 }
                            if frequency == .monthly, schedule.dayOfMonth == nil { schedule.dayOfMonth = 1 }
                            apply(enabled: true, schedule: schedule)
                        }
                    )) {
                        Text("Daily").tag(ScheduleFrequency.daily)
                        Text("Weekly").tag(ScheduleFrequency.weekly)
                        Text("Monthly").tag(ScheduleFrequency.monthly)
                    }
                    .frame(width: 120)
                    .accessibilityLabel("Malware signature update frequency")
                    .accessibilityIdentifier("signature-update-frequency")
                }

                DatePicker(
                    "Update time:",
                    selection: Binding(
                        get: { scheduleDate },
                        set: { date in
                            var schedule = currentSchedule
                            schedule.time = Calendar.current.dateComponents([.hour, .minute], from: date)
                            apply(enabled: true, schedule: schedule)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .accessibilityLabel("Malware signature update time")
                .accessibilityIdentifier("signature-update-time")

                if currentSchedule.frequency == .weekly {
                    HStack {
                        Text("Update day:")
                        Picker("", selection: Binding(
                            get: { currentSchedule.dayOfWeek ?? 2 },
                            set: { weekday in
                                var schedule = currentSchedule
                                schedule.dayOfWeek = weekday
                                apply(enabled: true, schedule: schedule)
                            }
                        )) {
                            ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index + 1)
                            }
                        }
                        .frame(width: 150)
                        .accessibilityLabel("Malware signature update day")
                        .accessibilityIdentifier("signature-update-weekday")
                    }
                }
            }

            if configuredEnabled == true, currentSchedule.frequency == .monthly {
                Picker("Day of month", selection: Binding(
                    get: { currentSchedule.dayOfMonth ?? 1 },
                    set: { day in
                        var schedule = currentSchedule
                        schedule.dayOfMonth = day
                        apply(enabled: true, schedule: schedule)
                    }
                )) {
                    ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(maxWidth: 240)
                .accessibilityIdentifier("signature-update-month-day")
                Text("Months without the selected day skip that update.").font(.caption).foregroundStyle(.secondary)
            }

            if let error = appState.signatureUpdateScheduleError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityLabel("Malware signature schedule error: \(error)")
                    .accessibilityIdentifier("signature-update-schedule-error")
            }
        }
    }

    private var configuredEnabled: Bool? {
        guard case .configured(let enabled) = appState.signatureUpdateScheduleState else {
            return nil
        }
        return enabled
    }

    private var currentSchedule: ScanSchedule {
        appState.settings.updateSchedule ?? .daily9am
    }

    private var scheduleDate: Date {
        Calendar.current.date(from: currentSchedule.time) ?? Date()
    }

    private func apply(enabled: Bool, schedule: ScanSchedule) {
        appState.setAutomaticSignatureUpdates(enabled: enabled, schedule: schedule)
    }
}

#Preview {
    UpdatesView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
