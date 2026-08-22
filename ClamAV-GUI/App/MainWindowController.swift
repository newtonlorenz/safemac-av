import AppKit
import SwiftUI

typealias MainWindowActivationOperation = @MainActor @Sendable () -> Void

@MainActor
protocol MainWindowControlling: AnyObject {
    func showMainWindow(selecting selection: NavigationTab?)
}

@MainActor
final class MainWindowControllerRegistry {
    static let shared = MainWindowControllerRegistry()

    private var factory: (() -> MainWindowControlling?)?
    private var router: ((NavigationTab?) -> Void)?
    private var routerAvailabilityWaiters: [() -> Void] = []
    private var factoryAvailabilityWaiters: [() -> Void] = []

    func installFactory(_ factory: @escaping () -> MainWindowControlling?) {
        self.factory = factory
        let waiters = factoryAvailabilityWaiters
        factoryAvailabilityWaiters.removeAll()
        waiters.forEach { $0() }
    }

    func makeController() -> MainWindowControlling? {
        factory?()
    }

    func whenFactoryAvailable(_ operation: @escaping () -> Void) {
        if factory != nil {
            operation()
        } else {
            factoryAvailabilityWaiters.append(operation)
        }
    }

    func installRouter(_ router: @escaping (NavigationTab?) -> Void) {
        self.router = router
        let waiters = routerAvailabilityWaiters
        routerAvailabilityWaiters.removeAll()
        waiters.forEach { $0() }
    }

    var isRouterAvailable: Bool { router != nil }

    func whenRouterAvailable(_ operation: @escaping () -> Void) {
        if router != nil {
            operation()
        } else {
            routerAvailabilityWaiters.append(operation)
        }
    }

    @discardableResult
    func showMainWindow(selecting selection: NavigationTab?) -> Bool {
        guard let router else { return false }
        router(selection)
        return true
    }
}

@MainActor
final class MainWindowController: MainWindowControlling {
    let appState: AppState
    let menuBarManager: MenuBarManager
    let windowController: NSWindowController
    private let scheduleActivation: (@escaping MainWindowActivationOperation) -> Void
    private var isActivationPending = false

    convenience init(
        appState: AppState,
        menuBarManager: MenuBarManager,
        preferredColorScheme: ColorScheme?,
        scheduleActivation: @escaping (@escaping MainWindowActivationOperation) -> Void = { operation in
            DispatchQueue.main.async(execute: operation)
        }
    ) {
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
        self.init(
            appState: appState,
            menuBarManager: menuBarManager,
            windowController: NSWindowController(window: window),
            scheduleActivation: scheduleActivation
        )
    }

    init(
        appState: AppState,
        menuBarManager: MenuBarManager,
        windowController: NSWindowController,
        scheduleActivation: @escaping (@escaping MainWindowActivationOperation) -> Void
    ) {
        self.appState = appState
        self.menuBarManager = menuBarManager
        self.windowController = windowController
        self.scheduleActivation = scheduleActivation
    }

    func showMainWindow(selecting selection: NavigationTab?) {
        if let selection {
            appState.selectedTab = selection
        }
        windowController.showWindow(nil)
        guard let window = windowController.window else { return }
        window.deminiaturize(nil)
        window.orderFront(nil)
        scheduleActivationIfNeeded()
    }

    private func scheduleActivationIfNeeded() {
        guard !isActivationPending else { return }
        isActivationPending = true
        scheduleActivation { [weak self] in
            self?.activateAndFocus(allowsRetry: true)
        }
    }

    private func activateAndFocus(allowsRetry: Bool) {
        guard let window = windowController.window else {
            isActivationPending = false
            return
        }
        let didActivate = menuBarManager.activateApplication()
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)

        let isFocused = didActivate && menuBarManager.isApplicationActive && window.isKeyWindow
        guard allowsRetry, !isFocused else {
            isActivationPending = false
            return
        }
        scheduleActivation { [weak self] in
            self?.activateAndFocus(allowsRetry: false)
        }
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
