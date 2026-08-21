import XCTest
@testable import ClamAV_GUI

@MainActor
final class SignatureUpdateAppStateTests: XCTestCase {
    func testUpdatingSchedulePersistsOnlyAfterLaunchAgentSucceeds() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        settings.updateSchedule = .daily9am
        let config = SignatureScheduleConfigMock(settings: settings)
        let scheduler = SignatureScheduleMock()
        let appState = makeAppState(config: config, scheduler: scheduler)
        let weekly = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 7, minute: 30),
            dayOfWeek: 2
        )

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: weekly)

        XCTAssertEqual(scheduler.calls, [.init(enabled: true, schedule: weekly)])
        XCTAssertTrue(appState.settings.autoUpdateSignatures)
        XCTAssertEqual(appState.settings.updateSchedule, weekly)
        XCTAssertEqual(config.settings, appState.settings)
        XCTAssertEqual(config.saveCalls, 1)
        XCTAssertNil(appState.signatureUpdateScheduleError)
    }

    func testLaunchAgentFailureLeavesPersistedSettingsUnchangedAndUsesSafeError() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let config = SignatureScheduleConfigMock(settings: settings)
        let scheduler = SignatureScheduleMock()
        scheduler.failOnCalls = [1]
        let appState = makeAppState(config: config, scheduler: scheduler)

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: .daily9am)

        XCTAssertFalse(appState.settings.autoUpdateSignatures)
        XCTAssertEqual(config.settings, settings)
        XCTAssertEqual(config.saveCalls, 0)
        XCTAssertNotNil(appState.signatureUpdateScheduleError)
        XCTAssertFalse(appState.signatureUpdateScheduleError?.contains("/Users/private") == true)
        XCTAssertFalse(appState.logs.contains { $0.message.contains("/Users/private") })
    }

    func testUnknownLaunchctlInspectionFailurePublishesIndeterminateState() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let config = SignatureScheduleConfigMock(settings: settings)
        let scheduler = SignatureScheduleMock()
        scheduler.errorsByCall[1] = SignatureUpdateSchedulerError.launchctlFailed(
            command: "print",
            status: 5
        )
        let appState = makeAppState(config: config, scheduler: scheduler)

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: .daily9am)

        XCTAssertEqual(appState.signatureUpdateScheduleState, .indeterminate)
        XCTAssertEqual(appState.settings, settings)
        XCTAssertEqual(config.saveCalls, 0)
    }

    func testPersistenceFailureRollsLaunchAgentBackToPreviousSchedule() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let config = SignatureScheduleConfigMock(settings: settings)
        config.saveError = SignatureScheduleTestError.settingsFailure
        let scheduler = SignatureScheduleMock()
        let appState = makeAppState(config: config, scheduler: scheduler)
        let weekly = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 8, minute: 15),
            dayOfWeek: 6
        )

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: weekly)

        XCTAssertEqual(scheduler.calls, [
            .init(enabled: true, schedule: weekly),
            .init(enabled: false, schedule: settings.updateSchedule ?? .daily9am)
        ])
        XCTAssertEqual(appState.settings, settings)
        XCTAssertEqual(config.settings, settings)
        XCTAssertNotNil(appState.settingsSaveError)
        XCTAssertNotNil(appState.signatureUpdateScheduleError)
        XCTAssertFalse(appState.logs.contains { $0.message.contains("/Users/private") })
    }

    func testPersistenceAndRollbackFailurePublishesIndeterminateScheduleState() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let config = SignatureScheduleConfigMock(settings: settings)
        config.saveError = SignatureScheduleTestError.settingsFailure
        let scheduler = SignatureScheduleMock()
        scheduler.failOnCalls = [2]
        let appState = makeAppState(config: config, scheduler: scheduler)

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: .daily9am)

        XCTAssertEqual(appState.settings, settings)
        XCTAssertEqual(config.settings, settings)
        XCTAssertEqual(appState.signatureUpdateScheduleState, .indeterminate)
        XCTAssertNotNil(appState.signatureUpdateScheduleError)
    }

    func testSuccessfulReconciliationPublishesConfiguredScheduleState() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        let config = SignatureScheduleConfigMock(settings: settings)
        let appState = makeAppState(config: config, scheduler: SignatureScheduleMock())

        appState.reconcileSignatureUpdateSchedule()

        XCTAssertEqual(appState.signatureUpdateScheduleState, .configured(enabled: true))
    }

    func testStartupReconciliationUsesLoadedSettingsButSkipsCorruptFallback() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        let config = SignatureScheduleConfigMock(settings: settings)
        let scheduler = SignatureScheduleMock()
        let appState = makeAppState(config: config, scheduler: scheduler)

        appState.reconcileSignatureUpdateSchedule()

        XCTAssertEqual(scheduler.calls, [
            .init(enabled: true, schedule: settings.updateSchedule ?? .daily9am)
        ])

        let fallbackConfig = SignatureScheduleConfigMock(settings: settings)
        fallbackConfig.lastSettingsLoadState = .fallbackDueToError(reason: "corrupt")
        let fallbackScheduler = SignatureScheduleMock()
        let fallbackState = makeAppState(config: fallbackConfig, scheduler: fallbackScheduler)

        fallbackState.reconcileSignatureUpdateSchedule()

        XCTAssertTrue(fallbackScheduler.calls.isEmpty)
        XCTAssertNotNil(fallbackState.signatureUpdateScheduleError)
    }

    func testDisabledScheduledLaunchIsNoOp() async {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let config = SignatureScheduleConfigMock(settings: settings)
        let runner = SignatureScheduleFreshclamMock()
        let notifications = SignatureScheduleNotificationMock()
        let appState = makeAppState(
            config: config,
            scheduler: SignatureScheduleMock(),
            freshclamRunner: runner,
            notifications: notifications
        )

        await appState.runScheduledSignatureUpdate()

        XCTAssertEqual(runner.updateCalls, 0)
        XCTAssertTrue(notifications.signatureResults.isEmpty)
    }

    func testCorruptSettingsScheduledLaunchIsNoOp() async {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        let config = SignatureScheduleConfigMock(settings: settings)
        config.lastSettingsLoadState = .fallbackDueToError(reason: "corrupt")
        let runner = SignatureScheduleFreshclamMock()
        let notifications = SignatureScheduleNotificationMock()
        let appState = makeAppState(
            config: config,
            scheduler: SignatureScheduleMock(),
            freshclamRunner: runner,
            notifications: notifications
        )

        await appState.runScheduledSignatureUpdate()

        XCTAssertEqual(runner.updateCalls, 0)
        XCTAssertTrue(notifications.signatureResults.isEmpty)
    }

    func testEnabledScheduledLaunchUsesExistingUpdateAndNotificationPath() async {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        settings.showNotifications = true
        let config = SignatureScheduleConfigMock(settings: settings)
        let runner = SignatureScheduleFreshclamMock()
        let notifications = SignatureScheduleNotificationMock()
        let appState = makeAppState(
            config: config,
            scheduler: SignatureScheduleMock(),
            freshclamRunner: runner,
            notifications: notifications
        )

        await appState.runScheduledSignatureUpdate()

        XCTAssertEqual(runner.updateCalls, 1)
        XCTAssertEqual(notifications.signatureResults.map(\.status), [.upToDate])
    }

    func testScheduledLaunchUsesAuthoritativeSettingsSnapshotWhenConfigLaterCorrupts() async {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        settings.freshclamPath = "/validated/bin/freshclam"
        settings.configDirectory = "/validated/etc/clamav"
        settings.signatureDirectory = "/validated/share/clamav"
        let config = SignatureScheduleConfigMock(settings: settings)
        let runner = SignatureScheduleFreshclamMock()
        let appState = makeAppState(
            config: config,
            scheduler: SignatureScheduleMock(),
            freshclamRunner: runner
        )
        config.settings = .default
        config.lastSettingsLoadState = .fallbackDueToError(reason: "corrupt")

        await appState.runScheduledSignatureUpdate()

        XCTAssertEqual(runner.settingsSnapshots, [settings])
        XCTAssertEqual(runner.updateCalls, 1)
    }

    func testScheduledLaunchDoesNotStartInteractiveBackgroundServices() {
        var settings = AppSettings.default
        settings.monitoringEnabled = true
        settings.autoScanDownloads = true
        settings.monitoredDirectories = ["/tmp/watch"]
        let config = SignatureScheduleConfigMock(settings: settings)
        let fileWatcher = SignatureScheduleFileWatcherMock()

        _ = makeAppState(
            config: config,
            scheduler: SignatureScheduleMock(),
            fileWatcher: fileWatcher,
            startsInteractiveBackgroundServices: false
        )

        XCTAssertEqual(fileWatcher.updateConfigurationCalls, 0)
        XCTAssertEqual(fileWatcher.configureImmediateScanDirectoriesCalls, 0)
        XCTAssertEqual(fileWatcher.startWatchingCalls, 0)
        XCTAssertNil(fileWatcher.onNewFileDetected)
    }

    private func makeAppState(
        config: SignatureScheduleConfigMock,
        scheduler: SignatureScheduleMock,
        fileWatcher: SignatureScheduleFileWatcherMock = SignatureScheduleFileWatcherMock(),
        freshclamRunner: FreshclamRunnerProtocol = SignatureScheduleFreshclamMock(),
        notifications: NotificationManaging? = nil,
        startsInteractiveBackgroundServices: Bool = true
    ) -> AppState {
        AppState(
            configManager: config,
            fileWatcher: fileWatcher,
            freshclamRunner: freshclamRunner,
            notificationManager: notifications ?? SignatureScheduleNotificationMock(),
            launchAtLoginManager: SignatureScheduleLaunchAtLoginMock(),
            signatureUpdateScheduler: scheduler,
            startsInteractiveBackgroundServices: startsInteractiveBackgroundServices
        )
    }
}

private enum SignatureScheduleTestError: LocalizedError {
    case settingsFailure

    var errorDescription: String? {
        "/Users/private/settings could not be written"
    }
}

private struct SignatureScheduleCall: Equatable {
    let enabled: Bool
    let schedule: ScanSchedule
}

private final class SignatureScheduleMock: SignatureUpdateScheduling {
    var failOnCalls: Set<Int> = []
    var errorsByCall: [Int: Error] = [:]
    private(set) var calls: [SignatureScheduleCall] = []

    func reconcile(enabled: Bool, schedule: ScanSchedule) throws {
        calls.append(.init(enabled: enabled, schedule: schedule))
        if let error = errorsByCall[calls.count] {
            throw error
        }
        if failOnCalls.contains(calls.count) {
            throw NSError(
                domain: "SignatureScheduleMock",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "/Users/private/LaunchAgents failed"]
            )
        }
    }
}

private final class SignatureScheduleConfigMock: ConfigManagerProtocol {
    var settings: AppSettings
    var saveError: Error?
    var lastSettingsLoadState: SettingsLoadState = .loaded
    private(set) var saveCalls = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    func loadSettings() -> AppSettings { settings }

    func saveSettings(_ settings: AppSettings) throws {
        saveCalls += 1
        if let saveError { throw saveError }
        self.settings = settings
    }

    func detectClamAVPaths() -> (clamscan: String?, freshclam: String?, configDir: String?) {
        (settings.clamScanPath, settings.freshclamPath, settings.configDirectory)
    }

    func validateClamAVInstallation() -> ClamAVInstallationStatus {
        .ready(clamscanPath: settings.clamScanPath)
    }

    func validateClamAVInstallation(using settings: AppSettings) -> ClamAVInstallationStatus {
        .ready(clamscanPath: settings.clamScanPath)
    }

    func getSignatureInfo() -> SignatureInfo {
        SignatureInfo(
            mainVersion: "1",
            dailyVersion: "1",
            bytecodeVersion: "1",
            lastUpdated: Date(),
            signatureCount: nil
        )
    }
}

private final class SignatureScheduleFreshclamMock: FreshclamRunnerProtocol, @unchecked Sendable {
    private(set) var updateCalls = 0
    private(set) var settingsSnapshots: [AppSettings] = []

    func update() async throws -> UpdateResult {
        updateCalls += 1
        return .alreadyUpToDate()
    }

    func update(using settings: AppSettings) async throws -> UpdateResult {
        settingsSnapshots.append(settings)
        updateCalls += 1
        return .alreadyUpToDate()
    }

    func checkForUpdates() async throws -> Bool { false }
}

private final class SignatureScheduleFileWatcherMock: FileWatcherProtocol {
    var isWatching = false
    var onNewFileDetected: ((URL) -> Void)?
    private(set) var startWatchingCalls = 0
    private(set) var stopWatchingCalls = 0
    private(set) var updateConfigurationCalls = 0
    private(set) var configureImmediateScanDirectoriesCalls = 0

    func startWatching(directories: [URL], handler: @escaping ([URL]) -> Void) {
        startWatchingCalls += 1
    }

    func stopWatching() {
        stopWatchingCalls += 1
    }

    func updateConfiguration(batchIntervalMinutes: Int, batchThreshold: Int) {
        updateConfigurationCalls += 1
    }

    func configureImmediateScanDirectories(_ directories: [URL]) {
        configureImmediateScanDirectoriesCalls += 1
    }
}

private final class SignatureScheduleLaunchAtLoginMock: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus = .disabled
    func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
private final class SignatureScheduleNotificationMock: NotificationManaging {
    var permissionStatus: NotificationPermissionStatus = .authorized
    var permissionError: String?
    private(set) var signatureResults: [UpdateResult] = []

    func setupNotificationCategories() {}
    func refreshPermissionStatus() async {}
    func requestPermission() async {}
    func sendScanComplete(report: ScanReport, settings: AppSettings) async {}
    func sendThreatDetected(threats: [ScanResult], settings: AppSettings) async {}
    func sendFileClean(url: URL, settings: AppSettings) async {}
    func sendSignaturesUpdated(result: UpdateResult, settings: AppSettings) async {
        signatureResults.append(result)
    }
    func sendScheduledScanStarting(jobName: String, settings: AppSettings) async {}
}
