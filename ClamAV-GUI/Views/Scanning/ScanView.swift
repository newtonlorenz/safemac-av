import SwiftUI
import UniformTypeIdentifiers

struct ScanView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPaths: [URL] = []
    @State private var scanOptions: ScanOptions = .default
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
            } else if let report = appState.lastScanResult {
                ScanResultsView(report: report) {
                    appState.lastScanResult = nil
                }
            } else {
                ScanSetupView(
                    selectedPaths: $selectedPaths,
                    scanOptions: $scanOptions,
                    showingFilePicker: $showingFilePicker,
                    isDragOver: $isDragOver
                ) {
                    startScan()
                }
            }
        }
        .accessibilityIdentifier("scan-content")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                selectedPaths.append(contentsOf: urls)
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

    private func startScan() {
        guard !selectedPaths.isEmpty else { return }
        Task {
            await appState.startScan(paths: selectedPaths, options: scanOptions)
            selectedPaths = []
        }
    }
}

struct ScanSetupView: View {
    @Binding var selectedPaths: [URL]
    @Binding var scanOptions: ScanOptions
    @Binding var showingFilePicker: Bool
    @Binding var isDragOver: Bool
    let onStartScan: () -> Void

    var body: some View {
        ScrollView {
            AdaptiveGlassEffectContainer(spacing: 20) {
                VStack(spacing: 20) {
                    DropZoneView(
                        selectedPaths: $selectedPaths,
                        isDragOver: $isDragOver,
                        onBrowse: { showingFilePicker = true }
                    )

                    if !selectedPaths.isEmpty {
                        SelectedPathsList(paths: $selectedPaths)
                    }

                    ScanOptionsView(options: $scanOptions)

                    Button(action: onStartScan) {
                        Label("Start Scan", systemImage: "magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .adaptiveGlassButton(prominent: true)
                    .disabled(selectedPaths.isEmpty)
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(isDragOver ? .blue : .secondary)

            Text("Drop files or folders to scan")
                .font(.headline)

            Text("or")
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Browse...") {
                    onBrowse()
                }

                Button("Quick Scan") {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    selectedPaths = [
                        home.appendingPathComponent("Downloads"),
                        home.appendingPathComponent("Desktop")
                    ]
                }
                .buttonStyle(.bordered)
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
                    if !selectedPaths.contains(url) {
                        selectedPaths.append(url)
                    }
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
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .adaptiveGlassSurface()
    }
}

struct ScanOptionsView: View {
    @Binding var options: ScanOptions
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Scan Options", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Scan subdirectories", isOn: $options.recursive)
                Toggle("Follow symbolic links", isOn: $options.followSymlinks)
                Toggle("Scan archives (ZIP, TAR, etc.)", isOn: $options.scanArchives)
                Toggle("Detect potentially unwanted apps", isOn: $options.detectPUA)
                Toggle("Quarantine infected files", isOn: $options.quarantineInfected)

                Divider()

                HStack {
                    Text("Max file size:")
                    Picker("", selection: $options.maxFileSize) {
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
                    Picker("", selection: $options.maxRecursionDepth) {
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("15").tag(15)
                        Text("20").tag(20)
                        Text("Unlimited").tag(100)
                    }
                    .frame(width: 100)
                }
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
        VStack(spacing: 24) {
            Spacer()

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

            if let fractionComplete = progress.fractionComplete {
                VStack(spacing: 8) {
                    ProgressView(value: fractionComplete)
                        .progressViewStyle(.linear)
                        .accessibilityIdentifier("scan-progress-bar")
                        .accessibilityValue("\(progress.percentComplete ?? 0) percent")

                    HStack {
                        Text("\(progress.percentComplete ?? 0)% complete")
                        Spacer()
                        if let remaining = progress.estimatedTimeRemaining {
                            Text("About \(formatDuration(remaining)) remaining")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if let totalFiles = progress.estimatedTotalFiles {
                        Text(estimatedWorkDescription(
                            totalFiles: totalFiles,
                            totalBytes: progress.estimatedTotalBytes
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: 520)
            } else {
                ProgressView()
                    .scaleEffect(2)
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

                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: 720, maxHeight: 520)
        .padding(30)
        .adaptiveGlassSurface(tint: Color.blue.opacity(0.06), cornerRadius: 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatElapsedTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(1, Int(interval.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? String(format: "%dm %02ds", minutes, seconds) : "\(seconds)s"
    }

    private func estimatedWorkDescription(totalFiles: Int, totalBytes: Int64?) -> String {
        let fileDescription = "Estimated total: \(totalFiles) file\(totalFiles == 1 ? "" : "s")"
        guard let totalBytes, totalBytes > 0 else { return fileDescription }
        return "\(fileDescription) · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }
}

struct ScanResultsView: View {
    let report: ScanReport
    let onDismiss: () -> Void
    @State private var exportError: ScanExportError?

    var body: some View {
        VStack(spacing: 0) {
            ScanSummaryHeader(report: report)

            if report.infectedFiles.isEmpty {
                CleanResultView()
            } else {
                InfectedFilesList(files: report.infectedFiles)
            }

            HStack {
                Button("Export Results...") {
                    exportResults()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("New Scan", action: onDismiss)
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
        let data: [[String: Any]] = report.infectedFiles.map { file in
            [
                "path": file.path,
                "threat": file.threatName,
                "severity": file.severity.rawValue,
                "action": file.actionTaken.rawValue
            ]
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
            try jsonData.write(to: url, options: .atomic)
        } catch {
            showExportError(for: url)
        }
    }

    private func exportCSV(to url: URL) {
        let header = ["Path", "Threat", "Severity", "Action"].map(csvField).joined(separator: ",")
        let rows = report.infectedFiles.map { file in
            [file.path, file.threatName, file.severity.rawValue, file.actionTaken.rawValue]
                .map(csvField)
                .joined(separator: ",")
        }
        let csv = ([header] + rows).joined(separator: "\r\n") + "\r\n"

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showExportError(for: url)
        }
    }

    private func csvField(_ value: String) -> String {
        let escapedValue = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escapedValue)\""
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
                Text("\(report.infectedFiles.count)")
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(report.isClean ? .green : .red)
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
            tint: (report.isClean ? Color.green : Color.red).opacity(0.08)
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
            Text("Your scanned files are clean.")
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
            return filtered.sorted { $0.severity.rawValue > $1.severity.rawValue }
        case .path:
            return filtered.sorted { $0.path < $1.path }
        case .name:
            return filtered.sorted { $0.threatName < $1.threatName }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

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

            List(sortedFiles) { file in
                InfectedFileRow(file: file)
            }
        }
    }
}

struct InfectedFileRow: View {
    let file: ScanResult

    var body: some View {
        HStack {
            Circle()
                .fill(severityColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading) {
                Text(file.threatName)
                    .fontWeight(.medium)
                Text(file.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(file.severity.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(severityColor.opacity(0.2))
                .foregroundColor(severityColor)
                .cornerRadius(4)

            Text(file.actionTaken.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)

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
        }
    }

    private var severityColor: Color {
        switch file.severity {
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

#Preview {
    ScanView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
