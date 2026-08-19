import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func setupNotificationCategories() {}

    func sendScanComplete(report: ScanReport, settings: AppSettings) {}
    func sendThreatDetected(threats: [ScanResult], settings: AppSettings) {}
    func sendFileClean(url: URL, settings: AppSettings) {}
    func sendSignaturesUpdated(result: UpdateResult, settings: AppSettings) {}
    func sendScheduledScanStarting(jobName: String, settings: AppSettings) {}
}
