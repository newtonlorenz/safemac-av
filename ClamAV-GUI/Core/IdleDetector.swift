import Foundation
import Combine

final class IdleDetector: ObservableObject {
    @Published private(set) var isIdle = false
    private var threshold: TimeInterval
    private var timer: Timer?

    init(thresholdMinutes: Int = 30) {
        threshold = TimeInterval(thresholdMinutes * 60)
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.isIdle = false
        }
    }

    func updateThreshold(minutes: Int) {
        threshold = TimeInterval(max(1, minutes) * 60)
    }
}
