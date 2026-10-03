import Foundation

@MainActor
final class ScanCoordinator {
    private let clamAVRunner: ClamAVRunnerProtocol
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRequested = false

    private(set) var isScanning = false
    private(set) var activeScanSource: ScanSource?

    var currentProcessPID: Int32? {
        clamAVRunner.currentProcessPID
    }

    var scanIsPaused: Bool {
        clamAVRunner.scanIsPaused
    }

    init(clamAVRunner: ClamAVRunnerProtocol) {
        self.clamAVRunner = clamAVRunner
    }

    func run(
        _ request: ScanRequest,
        onAdmitted: (() async throws -> Void)? = nil,
        admissionFailureMessage: String = "SafeMac AV couldn’t start this scan. Try again.",
        progressHandler: @escaping (ScanProgress) -> Void
    ) async -> ScanOutcome {
        guard !isScanning else {
            return .skippedAlreadyRunning(active: activeScanSource)
        }

        isScanning = true
        cancellationRequested = false
        activeScanSource = request.source
        defer {
            isScanning = false
            activeScanSource = nil
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        do {
            try await onAdmitted?()
        } catch {
            return cancellationRequested ? .cancelled : .failed(admissionFailureMessage)
        }

        // Admission can await notification delivery or durable handoff work.
        // Remember cancellation even when no scanner process exists yet.
        guard !cancellationRequested else { return .cancelled }

        do {
            let report = try await clamAVRunner.scan(
                paths: request.paths,
                options: request.options,
                progressHandler: progressHandler
            )
            return .completed(report)
        } catch ClamAVError.cancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func cancelCurrentScan() {
        cancellationRequested = true
        clamAVRunner.cancelCurrentScan()
    }

    func pauseScan() {
        clamAVRunner.pauseScan()
    }

    func resumeScan() {
        clamAVRunner.resumeScan()
    }

    func waitUntilIdle() async {
        guard isScanning else { return }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}
