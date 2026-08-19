import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ClamAVPathsSection()
                ScannerBackendSection()
                AutomationSettingsView()
                ExclusionsSection()
                MonitoringSection()
                NotificationsSection()
            }
            .padding()
        }
    }
}

struct ClamAVPathsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showingClamscanPicker = false
    @State private var showingFreshclamPicker = false

    var installationStatus: ClamAVInstallationStatus {
        appState.configManager.validateClamAVInstallation()
    }

    var body: some View {
        SettingsSection(title: "ClamAV Configuration", icon: "terminal") {
            VStack(alignment: .leading, spacing: 16) {
                StatusRow(status: installationStatus)

                PathSettingRow(
                    label: "clamscan path:",
                    path: $appState.settings.clamScanPath,
                    isValid: FileManager.default.isExecutableFile(atPath: appState.settings.clamScanPath)
                ) {
                    showingClamscanPicker = true
                }

                PathSettingRow(
                    label: "freshclam path:",
                    path: $appState.settings.freshclamPath,
                    isValid: FileManager.default.isExecutableFile(atPath: appState.settings.freshclamPath)
                ) {
                    showingFreshclamPicker = true
                }

                PathSettingRow(
                    label: "Config directory:",
                    path: $appState.settings.configDirectory,
                    isValid: FileManager.default.fileExists(atPath: appState.settings.configDirectory)
                ) {
                    // Config directory picker
                }

                PathSettingRow(
                    label: "Quarantine directory:",
                    path: $appState.settings.quarantineDirectory,
                    isValid: true
                ) {
                    // Quarantine directory picker
                }

                HStack {
                    Button("Auto-detect Paths") {
                        autoDetectPaths()
                    }
                    .buttonStyle(.bordered)

                    Button("Save") {
                        appState.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .fileImporter(isPresented: $showingClamscanPicker, allowedContentTypes: [.unixExecutable]) { result in
            if case .success(let url) = result {
                appState.settings.clamScanPath = url.path
            }
        }
        .fileImporter(isPresented: $showingFreshclamPicker, allowedContentTypes: [.unixExecutable]) { result in
            if case .success(let url) = result {
                appState.settings.freshclamPath = url.path
            }
        }
    }

    private func autoDetectPaths() {
        let detected = appState.configManager.detectClamAVPaths()
        var updatedSettings = appState.settings
        if let clamscan = detected.clamscan {
            updatedSettings.clamScanPath = clamscan
        }
        if let freshclam = detected.freshclam {
            updatedSettings.freshclamPath = freshclam
        }
        if let configDir = detected.configDir {
            updatedSettings.configDirectory = configDir
        }
        appState.settings = updatedSettings
        appState.saveSettings()
    }
}

struct StatusRow: View {
    let status: ClamAVInstallationStatus

    var body: some View {
        HStack {
            Circle()
                .fill(status.isReady ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            Text(status.message)
                .font(.caption)
                .foregroundColor(status.isReady ? .secondary : .orange)
        }
    }
}

struct PathSettingRow: View {
    let label: String
    @Binding var path: String
    let isValid: Bool
    let onBrowse: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 140, alignment: .trailing)

            TextField("", text: $path)
                .textFieldStyle(.roundedBorder)

            Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(isValid ? .green : .red)

            Button("Browse...") {
                onBrowse()
            }
            .buttonStyle(.bordered)
        }
    }
}

struct ScannerBackendSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showingClamdscanPicker = false

    var body: some View {
        SettingsSection(title: "Scanner Backend", icon: "cpu") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Scanner backend:", selection: Binding(
                    get: { appState.settings.scannerBackend },
                    set: {
                        appState.settings.scannerBackend = $0
                        appState.saveSettings()
                    }
                )) {
                    Text("clamscan").tag(ScannerBackend.clamscan)
                    Text("clamdscan").tag(ScannerBackend.clamdscan)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if appState.settings.scannerBackend == .clamdscan {
                    Toggle("Use local clamd daemon", isOn: Binding(
                        get: { appState.settings.clamdSettings.isEnabled },
                        set: {
                            appState.settings.clamdSettings.isEnabled = $0
                            appState.saveSettings()
                        }
                    ))

                    PathSettingRow(
                        label: "clamdscan path:",
                        path: Binding(
                            get: { appState.settings.clamdSettings.clamdScanPath },
                            set: { appState.settings.clamdSettings.clamdScanPath = $0 }
                        ),
                        isValid: FileManager.default.isExecutableFile(atPath: appState.settings.clamdSettings.clamdScanPath)
                    ) {
                        showingClamdscanPicker = true
                    }

                    HStack {
                        Text("Local socket:")
                            .frame(width: 140, alignment: .trailing)

                        TextField("", text: Binding(
                            get: { appState.settings.clamdSettings.socketPath },
                            set: { appState.settings.clamdSettings.socketPath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            appState.saveSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text("clamdscan reduces repeated scan overhead when a local clamd daemon is configured. Remote TCP clamd is not configured by this app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showingClamdscanPicker, allowedContentTypes: [.unixExecutable]) { result in
            if case .success(let url) = result {
                appState.settings.clamdSettings.clamdScanPath = url.path
                appState.saveSettings()
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
                Text("Files and directories matching these patterns will be skipped during scans.")
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
                    TextField("Add exclusion pattern...", text: $newExclusion)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addExclusion()
                        }

                    Button("Add") {
                        addExclusion()
                    }
                    .disabled(newExclusion.isEmpty)
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
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isDefault ? Color.gray.opacity(0.2) : Color.blue.opacity(0.2))
        .cornerRadius(4)
    }
}

struct MonitoringSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showingFolderPicker = false

    var body: some View {
        SettingsSection(title: "Real-time Monitoring", icon: "eye") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable real-time folder monitoring", isOn: Binding(
                    get: { appState.settings.monitoringEnabled },
                    set: {
                        appState.settings.monitoringEnabled = $0
                        appState.saveSettings()
                    }
                ))

                if appState.settings.monitoringEnabled {
                    Text("Monitored Directories")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(appState.settings.monitoredDirectories, id: \.self) { dir in
                        HStack {
                            Image(systemName: "folder")
                            Text(dir)
                            Spacer()
                            Button {
                                appState.settings.monitoredDirectories.removeAll { $0 == dir }
                                appState.saveSettings()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Add Directory...") {
                        showingFolderPicker = true
                    }

                    Divider()

                    HStack {
                        Text("Batch scan interval:")
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
                    }

                    HStack {
                        Text("Batch scan threshold:")
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
                    }

                    Text("Files will be scanned when either the interval elapses or the threshold is reached.")
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
                    }
                ))

                Toggle("Play sound on threat detection", isOn: Binding(
                    get: { appState.settings.playSoundOnDetection },
                    set: {
                        appState.settings.playSoundOnDetection = $0
                        appState.saveSettings()
                    }
                ))
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.headline)
            }

            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
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
