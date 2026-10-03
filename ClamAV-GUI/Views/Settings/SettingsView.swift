import SwiftUI
import UniformTypeIdentifiers

/// A local editing session. Apply changes only the fields the user edited,
/// preserving settings changed by other controls while the editor was open.
struct EngineSettingsDraft {
    private let original: AppSettings
    var settings: AppSettings

    init(settings: AppSettings) {
        original = settings
        self.settings = settings
    }

    var hasChanges: Bool { merging(into: original) != original }

    var validationMessage: String? {
        let paths = [settings.clamScanPath, settings.freshclamPath, settings.configDirectory,
                     settings.signatureDirectory, settings.quarantineDirectory]
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            return "Use an absolute path beginning with / for each executable and folder."
        }
        if settings.scannerBackend == .clamdscan,
           ![settings.clamdSettings.clamdScanPath, settings.clamdSettings.socketPath].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) {
            return "Use absolute paths for the daemon client and local socket."
        }
        return nil
    }

    func merging(into current: AppSettings) -> AppSettings {
        var result = current
        merge(\.clamScanPath, into: &result)
        merge(\.freshclamPath, into: &result)
        merge(\.configDirectory, into: &result)
        merge(\.signatureDirectory, into: &result)
        merge(\.quarantineDirectory, into: &result)
        merge(\.scannerBackend, into: &result)
        merge(\.clamdSettings.clamdScanPath, into: &result)
        merge(\.clamdSettings.socketPath, into: &result)
        merge(\.clamdSettings.isEnabled, into: &result)
        return result
    }

    private func merge<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>, into result: inout AppSettings) {
        if settings[keyPath: keyPath] != original[keyPath: keyPath] {
            result[keyPath: keyPath] = settings[keyPath: keyPath]
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var advancedExpanded = false

    private var needsEngineSetup: Bool {
        !appState.configManager.validateClamAVInstallation(using: appState.settings).isInstalled
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = appState.settingsSaveError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("settings-save-error")
                }
                if needsEngineSetup {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Finish setting up the scan engine").font(.headline)
                            Text("SafeMac AV needs ClamAV before it can scan. Engine setup is available below.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show Setup") {
                            withAnimation { advancedExpanded = true; proxy.scrollTo("settings-advanced", anchor: .top) }
                        }
                            .accessibilityIdentifier("settings-show-engine-setup")
                    }
                }
                AutomationSettingsView()
                MonitoringSection()
                NotificationsSection()
                AppBehaviourSettingsSection()
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 24) {
                        EngineConfigurationSection(settings: appState.settings)
                        ExclusionsSection()
                    }
                    .padding(.top, 16)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced").font(.headline)
                        Text("Scan engine, storage locations and exclusions")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .id("settings-advanced")
                .accessibilityIdentifier("settings-advanced")
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(GlassDesign.contentPadding)
        }
        .onAppear { if needsEngineSetup { advancedExpanded = true } }
        }
        .accessibilityIdentifier("settings-content")
    }
}

private struct EngineConfigurationSection: View {
    @EnvironmentObject var appState: AppState
    @State private var draft: EngineSettingsDraft
    @State private var pickerField: EnginePathField = .scanner
    @State private var showingPicker = false
    @State private var feedback: String?

    init(settings: AppSettings) { _draft = State(initialValue: EngineSettingsDraft(settings: settings)) }

    private enum EnginePathField {
        case scanner, updater, configuration, signatures, quarantine, daemon
        var isFolder: Bool { self == .configuration || self == .signatures || self == .quarantine }
    }

    var body: some View {
        SettingsSection(title: "Scan engine and storage", icon: "gearshape.2") {
            VStack(alignment: .leading, spacing: 16) {
                StatusRow(status: appState.configManager.validateClamAVInstallation(using: appState.settings))
                Text("If ClamAV is already installed, use Auto-detect or browse to its executables. If you use Homebrew, install it in Terminal with brew install clamav, then return here.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Picker("Scan engine", selection: $draft.settings.scannerBackend) {
                    Text("Direct scan (clamscan)").tag(ScannerBackend.clamscan)
                    Text("Local daemon (clamdscan)").tag(ScannerBackend.clamdscan)
                }
                .accessibilityIdentifier("engine-backend-picker")
                if draft.settings.scannerBackend == .clamdscan {
                    Toggle("A local ClamAV daemon is configured", isOn: $draft.settings.clamdSettings.isEnabled)
                    PathSettingRow(label: "Daemon client", path: $draft.settings.clamdSettings.clamdScanPath,
                                   isValid: executableExists(draft.settings.clamdSettings.clamdScanPath)) { browse(.daemon) }
                    LabeledContent("Expected local socket", value: draft.settings.clamdSettings.socketPath)
                        .textSelection(.enabled)
                    Text("The daemon reads its connection, limits and exclusions from clamd.conf. The socket shown here is for reference.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    PathSettingRow(label: "Scanner", path: $draft.settings.clamScanPath,
                                   isValid: executableExists(draft.settings.clamScanPath)) { browse(.scanner) }
                }
                PathSettingRow(label: "Definition updater", path: $draft.settings.freshclamPath,
                               isValid: executableExists(draft.settings.freshclamPath)) { browse(.updater) }
                PathSettingRow(label: "Configuration folder", path: $draft.settings.configDirectory,
                               isValid: directoryExists(draft.settings.configDirectory)) { browse(.configuration) }
                PathSettingRow(label: "Definitions folder", path: $draft.settings.signatureDirectory,
                               isValid: directoryExists(draft.settings.signatureDirectory)) { browse(.signatures) }
                PathSettingRow(label: "Quarantine folder", path: $draft.settings.quarantineDirectory,
                               isValid: directoryExists(draft.settings.quarantineDirectory)) { browse(.quarantine) }
                Text("Changing the quarantine folder does not move existing quarantined files. Return to the original folder to see them again.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = draft.validationMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                if let feedback { Text(feedback).font(.callout).foregroundStyle(.secondary) }
                if let error = appState.settingsSaveError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
                if appState.isScanning || appState.isUpdatingSignatures || appState.isManagingQuarantine {
                    Text("Finish the current scan, definition update or quarantine action before applying engine changes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Auto-detect") { autoDetect() }.accessibilityIdentifier("engine-auto-detect")
                    Button("Use Default Paths") { useDefaultPaths() }
                    Spacer()
                    Button("Cancel") { draft = EngineSettingsDraft(settings: appState.settings); feedback = nil }
                        .disabled(!draft.hasChanges).accessibilityIdentifier("engine-cancel")
                    Button("Apply Changes") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.hasChanges || draft.validationMessage != nil || appState.isScanning || appState.isUpdatingSignatures || appState.isManagingQuarantine)
                        .accessibilityIdentifier("engine-apply")
                }
                if draft.hasChanges {
                    Text("Engine changes are not saved until you apply them.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("engine-unsaved-changes")
                }
            }
        }
        .onChange(of: appState.settings) { settings in
            if !draft.hasChanges { draft = EngineSettingsDraft(settings: settings) }
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: pickerField.isFolder ? [.folder] : [.unixExecutable]) { result in
            switch result {
            case .success(let url):
                switch pickerField {
                case .scanner: draft.settings.clamScanPath = url.path
                case .updater: draft.settings.freshclamPath = url.path
                case .configuration: draft.settings.configDirectory = url.path
                case .signatures: draft.settings.signatureDirectory = url.path
                case .quarantine: draft.settings.quarantineDirectory = url.path
                case .daemon: draft.settings.clamdSettings.clamdScanPath = url.path
                }
                feedback = nil
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { feedback = "The location could not be selected. Try Browse again." }
            }
        }
    }

    private func browse(_ field: EnginePathField) { pickerField = field; showingPicker = true }
    private func executableExists(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
    private func directoryExists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    private func apply() {
        if appState.applySettings(draft.merging(into: appState.settings)) {
            draft = EngineSettingsDraft(settings: appState.settings)
            feedback = "Engine settings applied."
        }
    }
    private func autoDetect() {
        let paths = appState.configManager.detectClamAVPaths()
        if let value = paths.clamscan { draft.settings.clamScanPath = value }
        if let value = paths.freshclam { draft.settings.freshclamPath = value }
        if let value = paths.configDir { draft.settings.configDirectory = value }
        feedback = paths.clamscan == nil || paths.freshclam == nil
            ? "ClamAV was not fully detected. Install it with Homebrew or choose the executable locations with Browse."
            : "ClamAV locations found. Review them, then apply your changes."
    }
    private func useDefaultPaths() {
        let defaults = AppSettings.default
        draft.settings.clamScanPath = defaults.clamScanPath
        draft.settings.freshclamPath = defaults.freshclamPath
        draft.settings.configDirectory = defaults.configDirectory
        draft.settings.signatureDirectory = defaults.signatureDirectory
        draft.settings.quarantineDirectory = defaults.quarantineDirectory
        draft.settings.clamdSettings.clamdScanPath = defaults.clamdSettings.clamdScanPath
        draft.settings.clamdSettings.socketPath = defaults.clamdSettings.socketPath
        feedback = "Default paths are ready to review. Apply to save them."
    }
}

struct StatusRow: View {
    let status: ClamAVInstallationStatus
    var body: some View {
        Label(status.message, systemImage: status.isReady ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.callout).foregroundStyle(status.isReady ? Color.secondary : Color.orange)
    }
}

struct PathSettingRow: View {
    let label: String
    @Binding var path: String
    let isValid: Bool
    let onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text(isValid ? "Available" : "Not found").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(label, text: $path).textFieldStyle(.roundedBorder).accessibilityLabel(label)
                Button("Browse…", action: onBrowse)
                    .accessibilityLabel("Choose \(label.lowercased())")
            }
        }
    }
}

struct ExclusionsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var newExclusion = ""

    var body: some View {
        SettingsSection(title: "Scan Exclusions", icon: "eye.slash") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The direct scan engine skips files and folders matching these patterns. A local daemon uses exclusions in clamd.conf instead.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Default Exclusions")
                    .font(.subheadline)
                    .fontWeight(.medium)

                FlowLayout(spacing: 8) {
                    ForEach(appState.settings.defaultExclusions, id: \.self) { exclusion in
                        ExclusionTag(text: exclusion, isDefault: true) {
                            // Cannot remove defaults
                        }
                    }
                }

                Divider()

                Text("Custom Exclusions")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if appState.settings.customExclusions.isEmpty {
                    Text("No custom exclusions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(appState.settings.customExclusions, id: \.self) { exclusion in
                            ExclusionTag(text: exclusion, isDefault: false) {
                                appState.settings.customExclusions.removeAll { $0 == exclusion }
                                appState.saveSettings()
                            }
                        }
                    }
                }

                HStack {
                    TextField("Add exclusion pattern…", text: $newExclusion)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("New scan exclusion pattern")
                        .onSubmit {
                            addExclusion()
                        }

                    Button("Add") {
                        addExclusion()
                    }
                    .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !appState.settings.customExclusions.contains(trimmed),
              !appState.settings.defaultExclusions.contains(trimmed) else {
            return
        }
        appState.settings.customExclusions.append(trimmed)
        appState.saveSettings()
        newExclusion = ""
    }
}

struct ExclusionTag: View {
    let text: String
    let isDefault: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)

            if !isDefault {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove exclusion \(text)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)
    }
}

struct MonitoringSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showingFolderPicker = false

    var body: some View {
        SettingsSection(title: "Watched folders", icon: "folder") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Scan changes in selected folders", isOn: Binding(
                    get: { appState.settings.monitoringEnabled },
                    set: {
                        appState.settings.monitoringEnabled = $0
                        appState.saveSettings()
                    }
                ))

                if appState.settings.monitoringEnabled {
                    Text("Folders to watch")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if appState.settings.monitoredDirectories.isEmpty {
                        Text("Add a folder to start checking changes here.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(appState.settings.monitoredDirectories, id: \.self) { dir in
                        HStack {
                            Image(systemName: "folder")
                            Text(dir).lineLimit(1).truncationMode(.middle).help(dir)
                            Spacer()
                            Button {
                                appState.settings.monitoredDirectories.removeAll { $0 == dir }
                                appState.saveSettings()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Stop watching \(dir)")
                        }
                    }

                    Button("Add Folder…") {
                        showingFolderPicker = true
                    }

                    Divider()

                    HStack {
                        Text("Check for changes every:")
                        Picker("", selection: Binding(
                            get: { appState.settings.batchScanIntervalMinutes },
                            set: {
                                appState.settings.batchScanIntervalMinutes = $0
                                appState.saveSettings()
                            }
                        )) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                        }
                        .frame(width: 120)
                        .accessibilityLabel("Folder scan interval")
                    }

                    HStack {
                        Text("Or when this many files change:")
                        Picker("", selection: Binding(
                            get: { appState.settings.batchScanFileThreshold },
                            set: {
                                appState.settings.batchScanFileThreshold = $0
                                appState.saveSettings()
                            }
                        )) {
                            Text("5 files").tag(5)
                            Text("10 files").tag(10)
                            Text("20 files").tag(20)
                            Text("50 files").tag(50)
                        }
                        .frame(width: 120)
                        .accessibilityLabel("Changed files before scanning")
                    }

                    Text("Changes are grouped into scans while SafeMac AV is running. A scan starts when either limit is reached.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                if !appState.settings.monitoredDirectories.contains(url.path) {
                    appState.settings.monitoredDirectories.append(url.path)
                    appState.saveSettings()
                }
            }
        }
    }
}

struct NotificationsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsSection(title: "Notifications", icon: "bell") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show notifications", isOn: Binding(
                    get: { appState.settings.showNotifications },
                    set: {
                        appState.settings.showNotifications = $0
                        appState.saveSettings()
                        if $0 {
                            Task { await appState.requestNotificationPermission() }
                        }
                    }
                ))
                .accessibilityIdentifier("notifications-enabled-toggle")

                Toggle("Play sound on threat detection", isOn: Binding(
                    get: { appState.settings.playSoundOnDetection },
                    set: {
                        appState.settings.playSoundOnDetection = $0
                        appState.saveSettings()
                    }
                ))
                .disabled(!appState.settings.showNotifications)

                Toggle("Notify when downloaded files are clean", isOn: Binding(
                    get: { appState.settings.notifyOnCleanFiles },
                    set: {
                        appState.settings.notifyOnCleanFiles = $0
                        appState.saveSettings()
                    }
                ))
                .disabled(!appState.settings.showNotifications)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notification permission")
                        Text(appState.notificationPermissionStatus.displayName)
                            .font(.caption)
                            .foregroundColor(appState.notificationPermissionStatus.isAuthorized ? .green : .secondary)
                    }

                    Spacer()

                    if appState.notificationPermissionStatus == .notDetermined ||
                        appState.notificationPermissionStatus == .unknown {
                        Button("Allow Notifications") {
                            Task { await appState.requestNotificationPermission() }
                        }
                    } else {
                        Button("Refresh Status") {
                            Task { await appState.refreshNotificationPermissionStatus() }
                        }
                    }
                }

                if appState.notificationPermissionStatus == .denied {
                    Text("Allow SafeMac AV notifications in System Settings to receive scan and update alerts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Background update notifications")
                    Text("Scheduled definition updates use a separate background helper. Allow its notifications to hear about updates when this window is closed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Allow Background Update Notifications") {
                        Task { await appState.requestBackgroundHelperNotificationPermission() }
                    }
                    .accessibilityIdentifier("allow-background-update-notifications")
                    if let error = appState.backgroundHelperNotificationPermissionError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .accessibilityIdentifier("background-notification-permission-error")
                    }
                }

                if let error = appState.notificationPermissionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .accessibilityIdentifier("notification-permission-error")
                }
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing

                self.size.width = max(self.size.width, x)
            }

            self.size.height = y + rowHeight
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .frame(width: 800, height: 800)
}
