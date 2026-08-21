import Foundation
import UserNotifications

enum NotificationPermissionStatus: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown
        }
    }

    var isAuthorized: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .unknown:
            return "Status unavailable"
        case .notDetermined:
            return "Permission not requested"
        case .denied:
            return "Disabled in System Settings"
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Delivered quietly"
        case .ephemeral:
            return "Temporarily allowed"
        }
    }
}

protocol UserNotificationCenterProtocol: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

final class SystemUserNotificationCenter: UserNotificationCenterProtocol {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }
}

@MainActor
protocol NotificationManaging: AnyObject {
    var permissionStatus: NotificationPermissionStatus { get }
    var permissionError: String? { get }

    func setupNotificationCategories()
    func refreshPermissionStatus() async
    func requestPermission() async
    func sendScanComplete(report: ScanReport, settings: AppSettings) async
    func sendThreatDetected(threats: [ScanResult], settings: AppSettings) async
    func sendFileClean(url: URL, settings: AppSettings) async
    func sendSignaturesUpdated(result: UpdateResult, settings: AppSettings) async
    func sendScheduledScanStarting(jobName: String, settings: AppSettings) async
}

@MainActor
final class NotificationManager: NotificationManaging {
    static let shared = NotificationManager()

    private enum Category {
        static let scanResult = "SCAN_RESULT"
        static let threatDetected = "THREAT_DETECTED"
        static let signatureUpdate = "SIGNATURE_UPDATE"
        static let scheduledScan = "SCHEDULED_SCAN"
    }

    private let center: UserNotificationCenterProtocol
    private(set) var permissionStatus: NotificationPermissionStatus = .unknown
    private(set) var permissionError: String?

    init(center: UserNotificationCenterProtocol = SystemUserNotificationCenter()) {
        self.center = center
    }

    func refreshPermissionStatus() async {
        permissionStatus = NotificationPermissionStatus(await center.authorizationStatus())
    }

    func requestPermission() async {
        do {
            let _ = try await center.requestAuthorization(options: [.alert, .sound])
            permissionError = nil
            await refreshPermissionStatus()
        } catch {
            permissionStatus = .unknown
            permissionError = "SafeMac AV could not request notification permission. Try again in System Settings."
        }
    }

    func setupNotificationCategories() {
        let identifiers = [
            Category.scanResult,
            Category.threatDetected,
            Category.signatureUpdate,
            Category.scheduledScan
        ]
        let categories = Set(identifiers.map {
            UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], options: [])
        })
        center.setNotificationCategories(categories)
    }

    func sendScanComplete(report: ScanReport, settings: AppSettings) async {
        let content = notificationContent(
            title: "Scan complete",
            body: report.infectedFiles.isEmpty
                ? "SafeMac AV scanned \(report.filesScanned) files and found no threats."
                : "SafeMac AV scanned \(report.filesScanned) files and found \(report.infectedFiles.count) threats.",
            category: Category.scanResult
        )
        await post(content: content, identifierPrefix: "scan", settings: settings)
    }

    func sendThreatDetected(threats: [ScanResult], settings: AppSettings) async {
        guard !threats.isEmpty else { return }

        let count = threats.count
        let content = notificationContent(
            title: count == 1 ? "Threat detected" : "Threats detected",
            body: "SafeMac AV found \(count) threat\(count == 1 ? "" : "s"). Open the app to review details.",
            category: Category.threatDetected,
            sound: settings.playSoundOnDetection ? .default : nil
        )
        await post(content: content, identifierPrefix: "threat", settings: settings)
    }

    func sendFileClean(url: URL, settings: AppSettings) async {
        guard settings.notifyOnCleanFiles else { return }

        let content = notificationContent(
            title: "Download is clean",
            body: "A downloaded file passed its SafeMac AV scan.",
            category: Category.scanResult
        )
        await post(content: content, identifierPrefix: "clean-download", settings: settings)
    }

    func sendSignaturesUpdated(result: UpdateResult, settings: AppSettings) async {
        guard result.status != .inProgress else { return }

        let title: String
        let body: String
        switch result.status {
        case .success:
            title = "Signatures updated"
            body = "SafeMac AV updated its malware signatures."
        case .upToDate:
            title = "Signatures are current"
            body = "SafeMac AV malware signatures are already up to date."
        case .failed:
            title = "Signature update failed"
            body = "SafeMac AV could not update its malware signatures. Open the app for details."
        case .inProgress:
            return
        }
        let content = notificationContent(
            title: title,
            body: body,
            category: Category.signatureUpdate
        )
        await post(content: content, identifierPrefix: "signature-update", settings: settings)
    }

    func sendScheduledScanStarting(jobName: String, settings: AppSettings) async {
        let content = notificationContent(
            title: "Scheduled scan starting",
            body: "SafeMac AV is starting a scheduled scan.",
            category: Category.scheduledScan
        )
        await post(content: content, identifierPrefix: "scheduled-scan", settings: settings)
    }

    private func notificationContent(
        title: String,
        body: String,
        category: String,
        sound: UNNotificationSound? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.threadIdentifier = "com.newtonlorenz.SafeMacAV.local-notifications"
        content.sound = sound
        return content
    }

    private func post(
        content: UNNotificationContent,
        identifierPrefix: String,
        settings: AppSettings
    ) async {
        guard settings.showNotifications else { return }

        await refreshPermissionStatus()
        guard permissionStatus.isAuthorized else { return }

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            permissionError = nil
        } catch {
            permissionError = "SafeMac AV could not deliver a notification. Check notification access in System Settings."
        }
    }
}
