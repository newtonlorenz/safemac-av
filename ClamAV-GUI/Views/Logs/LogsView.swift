import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedLevel: LogLevel?
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var exportError: LogExportError?

    var filteredLogs: [LogEntry] {
        appState.logs.filter { entry in
            let matchesLevel = selectedLevel == nil || entry.level == selectedLevel
            let matchesSearch = searchText.isEmpty ||
                entry.message.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            LogsToolbar(
                selectedLevel: $selectedLevel,
                searchText: $searchText,
                autoScroll: $autoScroll,
                onClear: clearLogs,
                onExport: exportLogs
            )

            if filteredLogs.isEmpty {
                EmptyLogsView()
            } else {
                LogsList(logs: filteredLogs, autoScroll: autoScroll)
            }
        }
        .padding(.horizontal, GlassDesign.contentPadding)
        .padding(.bottom, 16)
        .accessibilityIdentifier("logs-content")
        .alert(item: $exportError) { error in
            Alert(
                title: Text("Logs Couldn’t Be Exported"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func clearLogs() {
        appState.logs.removeAll()
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "clamav-gui-logs-\(ISO8601DateFormatter().string(from: Date())).log"

        if panel.runModal() == .OK, let url = panel.url {
            let content = filteredLogs.map { entry in
                "[\(entry.formattedTimestamp)] [\(entry.level.rawValue)] \(entry.message)"
            }.joined(separator: "\n")

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = LogExportError(
                    message: "The app could not write \(url.path). Check the folder permissions and available disk space, then try again."
                )
            }
        }
    }
}

private struct LogExportError: Identifiable {
    let id = UUID()
    let message: String
}

struct LogsToolbar: View {
    @Binding var selectedLevel: LogLevel?
    @Binding var searchText: String
    @Binding var autoScroll: Bool
    let onClear: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack {
            TextField("Search logs...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Picker("Level", selection: $selectedLevel) {
                Text("All Levels").tag(nil as LogLevel?)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level as LogLevel?)
                }
            }
            .frame(width: 120)

            Toggle("Auto-scroll", isOn: $autoScroll)

            Spacer()

            Button("Export...") {
                onExport()
            }
            .buttonStyle(.bordered)

            Button("Clear") {
                onClear()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .adaptiveGlassSurface(cornerRadius: GlassDesign.compactCornerRadius)
    }
}

struct EmptyLogsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Logs")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Activity will appear here as you use the app.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LogsList: View {
    let logs: [LogEntry]
    let autoScroll: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(logs) { entry in
                LogEntryRow(entry: entry)
                    .id(entry.id)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: logs.count) { _ in
                if autoScroll, let lastLog = logs.last {
                    withAnimation {
                        proxy.scrollTo(lastLog.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)

            LogLevelBadge(level: entry.level)

            Text(entry.message)
                .font(.system(.body, design: .default))
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct LogLevelBadge: View {
    let level: LogLevel

    var body: some View {
        Text(level.rawValue)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(4)
            .frame(width: 70)
    }

    private var backgroundColor: Color {
        switch level {
        case .debug: return Color.gray.opacity(0.2)
        case .info: return Color.blue.opacity(0.2)
        case .warning: return Color.orange.opacity(0.2)
        case .error: return Color.red.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    LogsView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
