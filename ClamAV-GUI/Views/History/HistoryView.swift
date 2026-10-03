import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScanHistoryList(history: appState.scanHistoryManager)
    }
}

private struct ScanHistoryList: View {
    @ObservedObject var history: ScanHistoryManager
    @State private var selectedEntry: ScanHistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The latest 200 scan results from this app session. Reports and file paths are kept only until SafeMac AV quits. Export a report if you need to keep it.")
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
                    Text("Finished or cancelled scans will appear here with their date and results.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("history-empty-state")
            } else {
                List(history.entries) { entry in
                    HStack(spacing: 16) {
                        Image(systemName: entry.threatsFound == 0 && entry.completedWithoutErrors ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(entry.threatsFound == 0 && entry.completedWithoutErrors ? Color.green : Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry.scanType.rawValue) scan")
                                .font(.headline)
                            if entry.report.completionState == .cancelled {
                                Text("Cancelled — partial results").font(.caption).foregroundStyle(.secondary)
                            } else if !entry.completedWithoutErrors {
                                Text("Needs attention").font(.caption).foregroundStyle(.orange)
                            }
                            Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(entry.filesScanned) files · \(entry.threatsFound) threats")
                                .font(.callout)
                            Button("View Report") { selectedEntry = entry }
                                .accessibilityLabel("View \(entry.scanType.rawValue) scan report from \(entry.date.formatted())")
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, GlassDesign.contentPadding)
        .padding(.bottom, 16)
        .accessibilityIdentifier("history-content")
        .sheet(item: $selectedEntry) { entry in
            ScanResultsView(report: history.entries.first(where: { $0.id == entry.id })?.report ?? entry.report, dismissTitle: "Done") {
                selectedEntry = nil
            }
            .frame(minWidth: 560, idealWidth: 700, minHeight: 500, idealHeight: 600)
        }
    }
}
