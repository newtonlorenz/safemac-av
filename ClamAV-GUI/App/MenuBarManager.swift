import SwiftUI

@MainActor
final class MenuBarManager: ObservableObject {
    private weak var appState: AppState?

    func setup(appState: AppState) {
        self.appState = appState
    }

    func updateStatus() {}
}
