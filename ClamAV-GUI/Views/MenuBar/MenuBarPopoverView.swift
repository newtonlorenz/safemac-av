import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SafeMac AV")
                .font(.headline)
            Button("Quick Scan") {
                Task { await appState.startQuickScan() }
            }
            Button("Update Signatures") {
                Task { await appState.updateSignatures() }
            }
        }
        .padding()
        .frame(width: 220)
    }
}
