import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(appState.scanHistoryManager.entries) { entry in
            HStack {
                Text(entry.scanType.rawValue)
                Spacer()
                Text("\(entry.filesScanned) files")
                Text("\(entry.threatsFound) threats")
            }
        }
        .scrollContentBackground(.hidden)
        .padding(.horizontal, GlassDesign.contentPadding)
        .accessibilityIdentifier("history-content")
    }
}
