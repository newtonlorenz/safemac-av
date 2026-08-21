import UserNotifications
import XCTest
@testable import ClamAV_GUI

@MainActor
final class NotificationManagerTests: XCTestCase {
    func testPermissionRefreshAndRequestPublishCurrentStatus() async {
        let center = MockUserNotificationCenter(status: .notDetermined)
        let manager = NotificationManager(center: center)

        await manager.refreshPermissionStatus()
        XCTAssertEqual(manager.permissionStatus, .notDetermined)

        center.requestResult = true
        await manager.requestPermission()

        XCTAssertEqual(manager.permissionStatus, .authorized)
        XCTAssertNil(manager.permissionError)
        XCTAssertEqual(center.requestedOptions, [.alert, .sound])
    }

    func testPermissionFailureUsesSafeUserFacingError() async {
        let center = MockUserNotificationCenter(status: .notDetermined)
        center.requestError = NSError(
            domain: "NotificationManagerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/Users/private/notification failure"]
        )
        let manager = NotificationManager(center: center)

        await manager.requestPermission()

        XCTAssertEqual(manager.permissionStatus, .unknown)
        XCTAssertEqual(
            manager.permissionError,
            "SafeMac AV could not request notification permission. Try again in System Settings."
        )
        XCTAssertFalse(manager.permissionError?.contains("/Users/private") == true)
    }

    func testThreatNotificationHonorsMasterAndSoundPreferencesWithoutLeakingPath() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let threat = ScanResult(
            path: "/Users/alice/Private/medical-record.pdf",
            threatName: "Sensitive.Test.Signature"
        )
        var settings = AppSettings.default
        settings.showNotifications = false

        await manager.sendThreatDetected(threats: [threat], settings: settings)
        XCTAssertTrue(center.requests.isEmpty)

        settings.showNotifications = true
        settings.playSoundOnDetection = false
        await manager.sendThreatDetected(threats: [threat], settings: settings)

        let silentContent = try XCTUnwrap(center.requests.last?.content)
        XCTAssertEqual(silentContent.title, "Threat detected")
        XCTAssertEqual(silentContent.body, "SafeMac AV found 1 threat. Open the app to review details.")
        XCTAssertNil(silentContent.sound)
        XCTAssertFalse(silentContent.body.contains("medical-record.pdf"))
        XCTAssertFalse(silentContent.body.contains("/Users/alice"))
        XCTAssertFalse(silentContent.body.contains(threat.threatName))

        settings.playSoundOnDetection = true
        await manager.sendThreatDetected(threats: [threat], settings: settings)
        XCTAssertNotNil(center.requests.last?.content.sound)
    }

    func testCleanDownloadNotificationRequiresOptInAndKeepsFilePrivate() async throws {
        let center = MockUserNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let privateURL = URL(fileURLWithPath: "/Users/alice/Downloads/tax-return.pdf")
        var settings = AppSettings.default
        settings.showNotifications = true
        settings.notifyOnCleanFiles = false

        await manager.sendFileClean(url: privateURL, settings: settings)
        XCTAssertTrue(center.requests.isEmpty)

        settings.notifyOnCleanFiles = true
        await manager.sendFileClean(url: privateURL, settings: settings)

        let content = try XCTUnwrap(center.requests.last?.content)
        XCTAssertEqual(content.title, "Download is clean")
        XCTAssertEqual(content.body, "A downloaded file passed its SafeMac AV scan.")
        XCTAssertFalse(content.body.contains("tax-return.pdf"))
        XCTAssertFalse(content.body.contains("/Users/alice"))
    }

    func testScanUpdateAndScheduleNotificationsUseGenericContent() async throws {
        let center = MockUserNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        var settings = AppSettings.default
        settings.showNotifications = true
        let report = ScanReport(
            startTime: Date(),
            endTime: Date(),
            filesScanned: 42,
            infectedFiles: [],
            errors: [],
            scanPaths: [URL(fileURLWithPath: "/Users/alice/Private")]
        )
        let failedUpdate = UpdateResult.failed(error: "/Users/alice/.config/freshclam.conf was rejected")

        await manager.sendScanComplete(report: report, settings: settings)
        await manager.sendSignaturesUpdated(result: failedUpdate, settings: settings)
        await manager.sendScheduledScanStarting(jobName: "Private finance folders", settings: settings)

        XCTAssertEqual(center.requests.count, 3)
        let combinedContent = center.requests
            .map { "\($0.content.title) \($0.content.body)" }
            .joined(separator: " ")
        XCTAssertTrue(combinedContent.contains("42 files"))
        XCTAssertTrue(combinedContent.contains("Signature update failed"))
        XCTAssertTrue(combinedContent.contains("Scheduled scan starting"))
        XCTAssertFalse(combinedContent.contains("/Users/alice"))
        XCTAssertFalse(combinedContent.contains("Private finance folders"))
    }

    func testCategoriesAreRegistered() {
        let center = MockUserNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)

        manager.setupNotificationCategories()

        XCTAssertEqual(
            center.categoryIdentifiers,
            Set(["SCAN_RESULT", "THREAT_DETECTED", "SIGNATURE_UPDATE", "SCHEDULED_SCAN"])
        )
    }
}

private final class MockUserNotificationCenter: UserNotificationCenterProtocol {
    var status: UNAuthorizationStatus
    var requestResult = false
    var requestError: Error?
    private(set) var requestedOptions: UNAuthorizationOptions = []
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var categoryIdentifiers: Set<String> = []

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        if let requestError {
            throw requestError
        }
        status = requestResult ? .authorized : .denied
        return requestResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        categoryIdentifiers = Set(categories.map(\.identifier))
    }
}
