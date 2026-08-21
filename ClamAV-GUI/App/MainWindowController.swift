import AppKit
import SwiftUI

@MainActor
protocol MainWindowControlling: AnyObject {
    func showMainWindow(selecting selection: NavigationTab?)
}

@MainActor
final class MainWindowControllerRegistry {
    static let shared = MainWindowControllerRegistry()

    private var factory: (() -> MainWindowControlling?)?
    private var router: ((NavigationTab?) -> Void)?

    func installFactory(_ factory: @escaping () -> MainWindowControlling?) {
        self.factory = factory
    }

    func makeController() -> MainWindowControlling? {
        factory?()
    }

    func installRouter(_ router: @escaping (NavigationTab?) -> Void) {
        self.router = router
    }

    func showMainWindow(selecting selection: NavigationTab?) {
        router?(selection)
    }
}

@MainActor
final class MainWindowController: MainWindowControlling {
    let appState: AppState
    let menuBarManager: MenuBarManager
    let windowController: NSWindowController

    init(
        appState: AppState,
        menuBarManager: MenuBarManager,
        preferredColorScheme: ColorScheme?
    ) {
        self.appState = appState
        self.menuBarManager = menuBarManager

        let root = MainWindowRootView(
            appState: appState,
            preferredColorScheme: preferredColorScheme
        )
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = ClamAVApp.mainWindowTitle
        window.identifier = NSUserInterfaceItemIdentifier(ClamAVApp.mainWindowID)
        window.setAccessibilityIdentifier(ClamAVApp.mainWindowID)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1_060, height: 720))
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        windowController = NSWindowController(window: window)
    }

    func showMainWindow(selecting selection: NavigationTab?) {
        if let selection {
            appState.selectedTab = selection
        }
        menuBarManager.activateApplication()
        windowController.showWindow(nil)
        windowController.window?.deminiaturize(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
}

private struct MainWindowRootView: View {
    let appState: AppState
    let preferredColorScheme: ColorScheme?

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .preferredColorScheme(preferredColorScheme)
    }
}
