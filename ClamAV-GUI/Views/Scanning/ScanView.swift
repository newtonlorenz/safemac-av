import SwiftUI
import UniformTypeIdentifiers

struct ScanView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingFilePicker = false
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.isScanning, let progress = appState.currentScanProgress {
                ScanProgressView(
                    progress: progress,
                    isPaused: appState.isScanPaused,
                    onPauseResume: {
                        if appState.isScanPaused {
                            appState.resumeScan()
                        } else {
                            appState.pauseScan()
                        }
                    },
                    onCancel: {
                        appState.cancelScan()
                    }
                )
            } else if !appState.isPreparingNewScan, let report = appState.lastScanResult {
                ScanResultsView(report: report) {
                    appState.isPreparingNewScan = true
                }
            } else {
                ScanSetupView(
                    selectedPaths: $appState.scanDraftPaths,
                    scanOptions: $appState.scanDraftOptions,
                    showingFilePicker: $showingFilePicker,
                    isDragOver: $isDragOver,
                    onQuickScan: { Task { await appState.startQuickScan() } },
                    onHomeScan: { Task { await appState.startScan(paths: [FileManager.default.homeDirectoryForCurrentUser], options: .default, scanType: .full) } }
                ) {
                    startScan()
                }
            }
        }
        .accessibilityIdentifier("scan-content")
        .onAppear { consumeCustomScanRequest() }
        .onChange(of: appState.shouldOpenCustomScanPicker) { _ in
            consumeCustomScanRequest()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                appState.addScanDraftPaths(urls)
            }
        }
        .alert("Scan Failed", isPresented: Binding(
            get: { appState.scanError != nil },
            set: { if !$0 { appState.scanError = nil } }
        )) {
            Button("OK") { appState.scanError = nil }
        } message: {
            Text(appState.scanError ?? "Unknown error")
        }
    }

    private func consumeCustomScanRequest() {
        guard appState.shouldOpenCustomScanPicker else { return }
        appState.shouldOpenCustomScanPicker = false
        appState.isPreparingNewScan = true
        showingFilePicker = true
    }

    private func startScan() {
        guard !appState.scanDraftPaths.isEmpty else { return }
        Task {
            let outcome = await appState.startScan(paths: appState.scanDraftPaths, options: appState.scanDraftOptions)
            if case .completed = outcome {
                appState.scanDraftPaths = []
                appState.isPreparingNewScan = false
            }
        }
    }
}

struct ScanSetupView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedPaths: [URL]
    @Binding var scanOptions: ScanOptions
    @Binding var showingFilePicker: Bool
    @Binding var isDragOver: Bool
    let onQuickScan: () -> Void
    let onHomeScan: () -> Void
    let onStartScan: () -> Void

    private var installation: ClamAVInstallationStatus {
        appState.configManager.validateClamAVInstallation(using: appState.settings)
    }

    var body: some View {
        ScrollView {
            AdaptiveGlassEffectContainer(spacing: 20) {
                VStack(spacing: 20) {
                    if !installation.isReady {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(installation.isInstalled ? "Update malware definitions before scanning" : "Finish setting up the scanner", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(installation.message)
                                .foregroundStyle(.secondary)
                            Button(installation.isInstalled ? "Open Definition Updates" : "Open Engine Settings") {
                                appState.selectedTab = installation.isInstalled ? .updates : .settings
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    DropZoneView(
                        selectedPaths: $selectedPaths,
                        isDragOver: $isDragOver,
                        onBrowse: { showingFilePicker = true },
                        onQuickScan: onQuickScan
                    )

                    if !selectedPaths.isEmpty {
                        SelectedPathsList(paths: $selectedPaths)
                    }

                    if !selectedPaths.isEmpty {
                        Label(scanOptions.quarantineInfected ? "Detected files will be moved to quarantine." : "Detections will be reported. Files will stay in their original locations.", systemImage: scanOptions.quarantineInfected ? "lock.shield" : "doc.text.magnifyingglass")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ScanOptionsView(options: $scanOptions)

                    if !selectedPaths.isEmpty {
                        Button(action: onStartScan) {
                            Label("Start Scan", systemImage: "magnifyingglass")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .adaptiveGlassButton(prominent: true)
                        .disabled(!installation.isReady)
                        .accessibilityIdentifier("start-custom-scan")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                    HStack {
                        Button("Scan Home Folder", action: onHomeScan)
                            .disabled(!installation.isReady)
                        Text("Checks your user folder. This can take a while.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, GlassDesign.contentPadding)
                .padding(.vertical, 16)
            }
        }
    }
}

struct DropZoneView: View {
    @Binding var selectedPaths: [URL]
    @Binding var isDragOver: Bool
    let onBrowse: () -> Void
    let onQuickScan: () -> Void
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(isDragOver ? .blue : .secondary)

            Text("Drop files or folders to scan")
                .font(.headline)

            Button("Choose Files or Folders…", action: onBrowse)
                .adaptiveGlassButton(prominent: true)
                .accessibilityIdentifier("browse-scan-files")

            Divider().padding(.horizontal, 30)
            HStack {
                Button("Quick Scan", action: onQuickScan)
                    .disabled(!appState.configManager.validateClamAVInstallation(using: appState.settings).isReady)
                    .accessibilityIdentifier("start-quick-scan")
                Text("Checks Downloads and Desktop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(isDragOver ? .blue : .secondary.opacity(0.5))
        )
        .adaptiveGlassSurface(
            tint: isDragOver ? Color.blue.opacity(0.16) : nil,
            interactive: true
        )
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    appState.addScanDraftPaths([url])
                }
            }
        }
        return true
    }
}

struct SelectedPathsList: View {
    @Binding var paths: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected Items")
                    .font(.headline)
                Spacer()
                Button("Clear All") {
                    paths.removeAll()
                }
                .font(.caption)
            }

            ForEach(paths, id: \.self) { url in
                HStack {
                    Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                        .foregroundColor(.secondary)
                    Text(url.lastPathComponent)
                    Spacer()
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button {
                        paths.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(url.lastPathComponent) from scan")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .adaptiveGlassSurface()
    }
}

struct ScanOptionsView: View {
    @EnvironmentObject var appState: AppState
    @Binding var options: ScanOptions
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Scan Options (Advanced)", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if appState.settings.scannerBackend == .clamdscan {
                    Text("The ClamAV daemon controls scan limits, exclusions and archive settings through clamd.conf. These per-scan options apply to clamscan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Group {
                Toggle("Include subfolders", isOn: $options.recursive)
                Toggle("Follow symbolic links", isOn: $options.followSymlinks)
                Toggle("Scan archives (ZIP, TAR, etc.)", isOn: $options.scanArchives)
                Toggle("Detect potentially unwanted apps", isOn: $options.detectPUA)
                }
                .disabled(appState.settings.scannerBackend == .clamdscan)
                Toggle("Move detected files to quarantine", isOn: $options.quarantineInfected)

                Divider()
                Group {

                HStack {
                    Text("Maximum file size:")
                    Picker("Maximum file size", selection: $options.maxFileSize) {
                        Text("25 MB").tag(25)
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                    }
                    .frame(width: 100)
                }

                HStack {
                    Text("Max recursion depth:")
                    Picker("Maximum folder depth", selection: $options.maxRecursionDepth) {
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("15").tag(15)
                        Text("20").tag(20)
                        Text("100").tag(100)
                    }
                    .frame(width: 100)
                }
                }
                .disabled(appState.settings.scannerBackend == .clamdscan)
            }
            .padding(.top, 8)
        }
        .padding(18)
        .adaptiveGlassSurface()
    }
}

struct ScanProgressView: View {
    let progress: ScanProgress
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 24) {
                Spacer()

                ProgressView()
                    .scaleEffect(2)

                VStack(spacing: 8) {
                    Text(progress.status.rawValue)
                        .font(.headline)

                    if let currentFile = progress.currentFile {
                        Text(currentFile)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 40) {
                    VStack {
                        Text("\(progress.filesScanned)")
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("Files Scanned")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack {
                        Text("\(progress.infectedCount)")
                            .font(.title)
                            .fontWeight(.semibold)
                            .foregroundColor(progress.infectedCount > 0 ? .red : .primary)
                        Text("Threats Found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack {
                        Text(formatElapsedTime(progress.elapsedTime))
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("Elapsed Time")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button(action: onPauseResume) {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(progress.status == .preparing)

                    Button(action: onCancel) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(progress.status == .completing || progress.status == .cancelling)

                Spacer()
            }
            .frame(maxWidth: 720, maxHeight: 520)
            .padding(30)
            .adaptiveGlassSurface(tint: Color.blue.opacity(0.06), cornerRadius: 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formatElapsedTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct ScanResultsView: View {
    @EnvironmentObject var appState: AppState
    let report: ScanReport
    var dismissTitle: String = "New Scan"
    let onDismiss: () -> Void
    @State private var exportError: ScanExportError?

    var body: some View {
        VStack(spacing: 0) {
            ScanSummaryHeader(report: report)
            VStack(alignment: .leading, spacing: 4) {
                Text("Finished \(report.endTime.formatted(date: .abbreviated, time: .shortened))")
                Text(report.scanPaths.map(\.path).joined(separator: " • "))
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)

            if !report.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Scan needs attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                            Text(error).font(.callout).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(maxHeight: 150)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("scan-result-warnings")
            }

            if report.isClean {
                CleanResultView()
            } else if report.infectedFiles.isEmpty {
                IncompleteResultView(report: report)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.infectedFiles.contains { $0.actionTaken == .reported }
                         ? "Some detections are still at their original locations. Quarantine them before opening them."
                         : "Detected files have been handled. Review isolated files in Quarantine; you can leave them there.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Review Quarantine") {
                        onDismiss()
                        appState.selectedTab = .quarantine
                    }
                    InfectedFilesList(files: report.infectedFiles)
                        .alert(item: $appState.quarantineActionError) { error in
                            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
                        }
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Export Results...") {
                    exportResults()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(dismissTitle, action: onDismiss)
                    .adaptiveGlassButton(prominent: true)
            }
            .padding()
        }
        .alert(item: $exportError) { error in
            Alert(
                title: Text("Results Couldn’t Be Exported"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func exportResults() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.nameFieldStringValue = "scan-results-\(ISO8601DateFormatter().string(from: Date()))"

        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension == "csv" {
                exportCSV(to: url)
            } else {
                exportJSON(to: url)
            }
        }
    }

    private func exportJSON(to url: URL) {
        do { try report.exportJSONData().write(to: url, options: .atomic) }
        catch { showExportError(for: url) }
    }

    private func exportCSV(to url: URL) {
        do { try report.exportCSVData().write(to: url, options: .atomic) }
        catch { showExportError(for: url) }
    }

    private func showExportError(for url: URL) {
        exportError = ScanExportError(
            message: "The app could not write \(url.path). Check the folder permissions and available disk space, then try again."
        )
    }
}

private struct ScanExportError: Identifiable {
    let id = UUID()
    let message: String
}

struct ScanSummaryHeader: View {
    let report: ScanReport

    var body: some View {
        HStack(spacing: 40) {
            VStack {
                Text("\(report.filesScanned)")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Files Scanned")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack {
                Text("\(report.threatsFound)")
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(report.infectedFiles.isEmpty ? (report.isClean ? .green : .orange) : .red)
                Text("Threats Found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack {
                Text(formatDuration(report.duration))
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Duration")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .adaptiveGlassSurface(
            tint: (report.infectedFiles.isEmpty ? (report.isClean ? Color.green : Color.orange) : Color.red).opacity(0.08)
        )
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

struct IncompleteResultView: View {
    let report: ScanReport

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(report.completionState == .cancelled ? "Scan Cancelled" : (report.filesScanned == 0 ? "No Files Scanned" : "Scan Needs Attention"))
                .font(.title2.weight(.semibold))
            Text("This scan did not establish a clean result. Review the warnings and scan locations, then try again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .accessibilityIdentifier("scan-incomplete-result")
    }
}

struct CleanResultView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            Text("No Threats Found")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No threats were detected in the files checked by this scan.")
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct InfectedFilesList: View {
    let files: [ScanResult]
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .severity

    enum SortOrder {
        case severity, path, name
    }

    var sortedFiles: [ScanResult] {
        let filtered = searchText.isEmpty ? files : files.filter {
            $0.path.localizedCaseInsensitiveContains(searchText) ||
            $0.threatName.localizedCaseInsensitiveContains(searchText)
        }

        switch sortOrder {
        case .severity:
            return filtered.sorted { $0.severity.priority > $1.severity.priority }
        case .path:
            return filtered.sorted { $0.path < $1.path }
        case .name:
            return filtered.sorted { $0.threatName < $1.threatName }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search detections", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, maxWidth: 220)

                Picker("Sort by:", selection: $sortOrder) {
                    Text("Severity").tag(SortOrder.severity)
                    Text("Path").tag(SortOrder.path)
                    Text("Threat Name").tag(SortOrder.name)
                }
                .frame(width: 150)

                Spacer()

                Text("\(files.count) threat\(files.count == 1 ? "" : "s") found")
                    .foregroundColor(.secondary)
            }
            .padding()

            if sortedFiles.isEmpty {
                VStack(spacing: 10) {
                    Text("No detections match your search").font(.headline)
                    Button("Clear Search") { searchText = "" }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sortedFiles) { file in
                    InfectedFileRow(file: file)
                }
            }
        }
    }
}

struct InfectedFileRow: View {
    @EnvironmentObject var appState: AppState
    let file: ScanResult

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading) {
                Text((file.path as NSString).lastPathComponent)
                    .fontWeight(.medium)
                Text(file.threatName)
                    .font(.caption)
                Text(file.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(currentFile.actionTaken == .reported ? "At original location" : currentFile.actionTaken.rawValue)
                .font(.caption)
                .foregroundColor(currentFile.actionTaken == .reported ? .orange : .secondary)

            if currentFile.actionTaken == .reported,
               appState.lastScanResult?.infectedFiles.contains(where: { $0.id == file.id }) == true {
                Button("Quarantine") {
                    Task {
                        do { try await appState.quarantineDetection(currentFile) }
                        catch { /* AppState retains the failure and exposes it across navigation. */ }
                    }
                }
                .disabled(appState.isManagingQuarantine || appState.isScanning)
                .accessibilityLabel("Quarantine \((file.path as NSString).lastPathComponent)")
            }
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("Actions for \((file.path as NSString).lastPathComponent)")
        }

    }

    private var currentFile: ScanResult {
        appState.lastScanResult?.infectedFiles.first(where: { $0.id == file.id }) ?? file
    }


}

#Preview {
    ScanView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
