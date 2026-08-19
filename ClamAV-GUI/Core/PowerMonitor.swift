import Foundation
import IOKit.ps

final class PowerMonitor: ObservableObject {
    @Published private(set) var isOnBattery = false
    @Published private(set) var batteryLevel = 100
    private var timer: Timer?

    func startMonitoring() {
        update()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as NSArray
        for case let source as CFTypeRef in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                isOnBattery = state == kIOPSBatteryPowerValue
            }
            if let capacity = description[kIOPSCurrentCapacityKey] as? Int {
                batteryLevel = capacity
            }
        }
    }
}
