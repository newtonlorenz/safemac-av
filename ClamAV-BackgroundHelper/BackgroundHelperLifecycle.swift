import Foundation

/// Keeps the durable fixed-enum request authoritative across a canonical main
/// app launch. A failed launch removes the pending request so it cannot replay
/// later; distributed notifications remain only a post-launch wake hint.
final class BackgroundRouteHandoff {
    private let requestStore: BackgroundRouteRequestStore
    private let validateMainApplication: () -> Bool
    private let openMainApplication: (@escaping (Bool) -> Void) -> Void
    private let postWakeHint: (BackgroundRoute) -> Void

    init(
        requestStore: BackgroundRouteRequestStore,
        validateMainApplication: @escaping () -> Bool,
        openMainApplication: @escaping (@escaping (Bool) -> Void) -> Void,
        postWakeHint: @escaping (BackgroundRoute) -> Void
    ) {
        self.requestStore = requestStore
        self.validateMainApplication = validateMainApplication
        self.openMainApplication = openMainApplication
        self.postWakeHint = postWakeHint
    }

    func send(_ route: BackgroundRoute) {
        guard validateMainApplication(), requestStore.enqueue(route) else { return }
        openMainApplication { [requestStore, postWakeHint] succeeded in
            guard succeeded else {
                requestStore.discard(route)
                return
            }
            postWakeHint(route)
        }
    }
}

@MainActor
final class BackgroundHelperCoordinator {
    enum Presentation: Equatable {
        case hidden
        case visibleMenuBar
    }

    private let installStatusItem: () -> Void
    private let acquireMonitoringLease: () -> Bool
    private let runScheduledSignatureUpdate: (@escaping @MainActor @Sendable () -> Void) -> Void
    private let terminate: () -> Void
    private var scheduledUpdateHasStarted = false
    private var scheduledUpdateHasFinished = false

    private(set) var presentation: Presentation = .hidden

    init(
        installStatusItem: @escaping () -> Void,
        acquireMonitoringLease: @escaping () -> Bool,
        runScheduledSignatureUpdate: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void,
        terminate: @escaping () -> Void
    ) {
        self.installStatusItem = installStatusItem
        self.acquireMonitoringLease = acquireMonitoringLease
        self.runScheduledSignatureUpdate = runScheduledSignatureUpdate
        self.terminate = terminate
    }

    func start(arguments: [String]) {
        switch BackgroundHelperLaunchModeParser.parse(arguments: arguments) {
        case .backgroundSession:
            startBackgroundSession()
        case .scheduledSignatureUpdate:
            startScheduledSignatureUpdate()
        case .invalid:
            terminate()
        }
    }

    private func startBackgroundSession() {
        BackgroundMenuBarOwnershipCoordinator.notifyHelperWillAcquireOwnership()
        guard acquireMonitoringLease() else {
            terminate()
            return
        }
        presentation = .visibleMenuBar
        installStatusItem()
    }

    private func startScheduledSignatureUpdate() {
        guard !scheduledUpdateHasStarted else { return }
        scheduledUpdateHasStarted = true
        runScheduledSignatureUpdate { [weak self] in
            self?.finishScheduledSignatureUpdate()
        }
    }

    private func finishScheduledSignatureUpdate() {
        guard !scheduledUpdateHasFinished else { return }
        scheduledUpdateHasFinished = true
        terminate()
    }
}
