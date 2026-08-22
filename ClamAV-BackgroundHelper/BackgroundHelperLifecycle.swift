import Foundation

@MainActor
final class BackgroundHelperCoordinator {
    enum Presentation: Equatable {
        case hidden
        case visibleMenuBar
    }

    private let installStatusItem: () -> Void
    private let acquireMonitoringLease: () -> Bool
    private let runScheduledSignatureUpdate: (@escaping () -> Void) -> Void
    private let terminate: () -> Void
    private var scheduledUpdateHasStarted = false
    private var scheduledUpdateHasFinished = false

    private(set) var presentation: Presentation = .hidden

    init(
        installStatusItem: @escaping () -> Void,
        acquireMonitoringLease: @escaping () -> Bool,
        runScheduledSignatureUpdate: @escaping (@escaping () -> Void) -> Void,
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
