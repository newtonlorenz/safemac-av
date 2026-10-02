import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScanHistoryList(history: appState.scanHistoryManager)
    }
}

private struct ScanHistoryList: View {
    @ObservedObject var history: ScanHistoryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Completed scans from this app session. History is cleared when SafeMac AV quits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history-session-notice")

            if history.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No scans yet")
                        .font(.headline)
                    Text("Completed scans will appear here with their date and results.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("history-empty-state")
            } else {
                List(history.entries) { entry in
                    HStack(spacing: 16) {
                        Image(systemName: entry.threatsFound == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(entry.threatsFound == 0 ? Color.green : Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry.scanType.rawValue) scan")
                                .font(.headline)
                            Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(entry.filesScanned) files")
                        Text("\(entry.threatsFound) threats")
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, GlassDesign.contentPadding)
        .padding(.bottom, 16)
        .accessibilityIdentifier("history-content")
    }
}
