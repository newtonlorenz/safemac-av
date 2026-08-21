import XCTest
@testable import ClamAV_GUI

@MainActor
final class AppStateTests: XCTestCase {
    func testLaunchAtLoginManagerRegistersMainAppAndReportsEnabledStatus() throws {
        let service = AppStateMockLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let manager = LaunchAtLoginManager(service: service)

        try manager.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(manager.status, .enabled)
    }

    func testLaunchAtLoginManagerAttemptsRegistrationFromNotFoundStatus() throws {
        let service = AppStateMockLoginItemService(status: .notFound)
        service.statusAfterRegister = .enabled
        let manager = LaunchAtLoginManager(service: service)

        try manager.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(manager.status, .enabled)
    }

    func testLaunchAtLoginManagerMapsSystemStatuses() {
        let service = AppStateMockLoginItemService(status: .notRegistered)
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertEqual(manager.status, .disabled)
        service.serviceStatus = .enabled
        XCTAssertEqual(manager.status, .enabled)
        service.serviceStatus = .requiresApproval
        XCTAssertEqual(manager.status, .requiresApproval)
        service.serviceStatus = .notFound
        XCTAssertEqual(manager.status, .unavailable)
    }

    func testLaunchAtLoginStatusesProvideClearSettingsPresentation() {
        XCTAssertEqual(LaunchAtLoginStatus.disabled.title, "Off")
        XCTAssertEqual(LaunchAtLoginStatus.enabled.title, "On")
        XCTAssertEqual(LaunchAtLoginStatus.requiresApproval.title, "Approval required")
        XCTAssertEqual(LaunchAtLoginStatus.unavailable.title, "Unavailable")

        XCTAssertNil(LaunchAtLoginStatus.disabled.detail)
        XCTAssertNil(LaunchAtLoginStatus.enabled.detail)
        XCTAssertNotNil(LaunchAtLoginStatus.requiresApproval.detail)
        XCTAssertNotNil(LaunchAtLoginStatus.unavailable.detail)

        XCTAssertEqual(LaunchAtLoginStatus.disabled.symbolName, "circle")
        XCTAssertEqual(LaunchAtLoginStatus.enabled.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(LaunchAtLoginStatus.requiresApproval.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(LaunchAtLoginStatus.unavailable.symbolName, "xmark.circle")
    }

    func testLaunchAtLoginManagerAvoidsDuplicateRegistrationAndUnregisters() throws {
        let service = AppStateMockLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(service: service)

        try manager.setEnabled(true)
        try manager.setEnabled(false)
        try manager.setEnabled(false)

        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .disabled)
    }

    func testLaunchAtLoginStartupReconcilesSavedPreferenceWithSystemStatus() {
        var settings = AppSettings.default
        settings.launchAtLogin = true
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let service = AppStateMockLoginItemService(status: .notRegistered)

        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        XCTAssertFalse(appState.settings.launchAtLogin)
        XCTAssertFalse(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .disabled)
    }

    func testLaunchAtLoginStartupDoesNotPersistFallbackLoadedDefaults() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        mockConfig.lastSettingsLoadState = .fallbackDueToError(reason: "The data is not in the correct format.")
        let service = AppStateMockLoginItemService(status: .enabled)

        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        XCTAssertTrue(appState.settings.launchAtLogin)
        XCTAssertFalse(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(mockConfig.saveSettingsCalls, 0)
        XCTAssertEqual(appState.launchAtLoginStatus, .enabled)
        XCTAssertNotNil(appState.settingsSaveError)
        XCTAssertTrue(appState.logs.contains { entry in
            entry.level == .error && entry.message == "Skipped launch-at-login reconciliation because settings could not be loaded safely"
        })
    }

    func testLaunchAtLoginRefreshReconcilesExternalSystemChange() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notRegistered)
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )
        service.serviceStatus = .enabled

        appState.refreshLaunchAtLoginStatus()

        XCTAssertEqual(appState.launchAtLoginStatus, .enabled)
        XCTAssertTrue(appState.settings.launchAtLogin)
        XCTAssertTrue(mockConfig.settings.launchAtLogin)
    }

    func testLaunchAtLoginRefreshClearsStaleServiceError() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notRegistered)
        service.registerError = AppStateTestError.loginItemFailure
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )
        appState.setLaunchAtLoginEnabled(true)
        XCTAssertNotNil(appState.launchAtLoginError)
        service.serviceStatus = .enabled

        appState.refreshLaunchAtLoginStatus()

        XCTAssertNil(appState.launchAtLoginError)
        XCTAssertEqual(appState.launchAtLoginStatus, .enabled)
    }

    func testEnablingLaunchAtLoginPersistsRegisteredState() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        appState.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(appState.settings.launchAtLogin)
        XCTAssertTrue(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .enabled)
        XCTAssertNil(appState.launchAtLoginError)
    }

    func testEnablingLaunchAtLoginFromNotFoundStatusPersistsRegisteredState() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notFound)
        service.statusAfterRegister = .enabled
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        appState.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(appState.settings.launchAtLogin)
        XCTAssertTrue(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .enabled)
        XCTAssertNil(appState.launchAtLoginError)
    }

    func testLaunchAtLoginApprovalRequirementKeepsRequestedPreferenceEnabled() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        appState.setLaunchAtLoginEnabled(true)

        XCTAssertTrue(appState.settings.launchAtLogin)
        XCTAssertTrue(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .requiresApproval)
        XCTAssertNil(appState.launchAtLoginError)
    }

    func testDisablingApprovalRequiredLaunchAtLoginUnregistersIt() {
        var settings = AppSettings.default
        settings.launchAtLogin = true
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let service = AppStateMockLoginItemService(status: .requiresApproval)
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        appState.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(appState.settings.launchAtLogin)
        XCTAssertFalse(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .disabled)
    }

    func testLaunchAtLoginUnregisterFailureKeepsApprovalRequiredPreference() {
        var settings = AppSettings.default
        settings.launchAtLogin = true
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let service = AppStateMockLoginItemService(status: .requiresApproval)
        service.unregisterError = AppStateTestError.loginItemFailure
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        appState.setLaunchAtLoginEnabled(false)

        XCTAssertTrue(appState.settings.launchAtLogin)
        XCTAssertTrue(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .requiresApproval)
        XCTAssertNotNil(appState.launchAtLoginError)
    }

    func testLaunchAtLoginServiceFailureKeepsPersistedPreferenceConsistent() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notRegistered)
        service.registerError = AppStateTestError.loginItemFailure
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )

        appState.setLaunchAtLoginEnabled(true)

        XCTAssertFalse(appState.settings.launchAtLogin)
        XCTAssertFalse(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .disabled)
        XCTAssertNotNil(appState.launchAtLoginError)
    }

    func testLaunchAtLoginPersistenceFailureRollsBackRegistration() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let service = AppStateMockLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: service)
        )
        mockConfig.saveError = AppStateTestError.settingsFailure

        appState.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(appState.settings.launchAtLogin)
        XCTAssertFalse(mockConfig.settings.launchAtLogin)
        XCTAssertEqual(appState.launchAtLoginStatus, .disabled)
        XCTAssertNotNil(appState.launchAtLoginError)
        XCTAssertNotNil(appState.settingsSaveError)
    }

    func testSaveSettingsSurfacesPersistenceFailureAndLogsIt() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let settingsURL = tempDirectory
            .appendingPathComponent("ClamAV-GUI", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        let configManager = ConfigManager(appSupportURL: tempDirectory)
        let appState = AppState(
            configManager: configManager,
            scanScheduler: ScanScheduler(),
            fileWatcher: MockFileWatcher()
        )

        appState.saveSettings()

        XCTAssertEqual(
            appState.settingsSaveError,
            "Your settings could not be saved. Check that the app can write to Application Support, then try again."
        )
        XCTAssertTrue(appState.logs.contains { entry in
            entry.level == .error && entry.message.hasPrefix("Failed to save settings:")
        })
    }

    func testSaveSettingsInstallsSignatureUpdateScheduleWhenEnabled() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        settings.updateSchedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 6, minute: 15),
            dayOfWeek: 3
        )
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let signatureScheduler = AppStateMockSignatureUpdateScheduler()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            signatureUpdateScheduler: signatureScheduler
        )

        appState.saveSettings()

        XCTAssertEqual(signatureScheduler.installedSchedules, [settings.updateSchedule])
        XCTAssertEqual(signatureScheduler.removeCalls, 0)
    }

    func testSaveSettingsFailureDoesNotMutateSignatureUpdateSchedule() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        let mockConfig = AppStateMockConfigManager(settings: settings)
        mockConfig.saveError = AppStateTestError.settingsFailure
        let signatureScheduler = AppStateMockSignatureUpdateScheduler()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            signatureUpdateScheduler: signatureScheduler
        )

        appState.saveSettings()

        XCTAssertTrue(signatureScheduler.installedSchedules.isEmpty)
        XCTAssertEqual(signatureScheduler.removeCalls, 0)
        XCTAssertNotNil(appState.settingsSaveError)
    }

    func testSaveSettingsRemovesSignatureUpdateScheduleWhenDisabled() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let signatureScheduler = AppStateMockSignatureUpdateScheduler()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            signatureUpdateScheduler: signatureScheduler
        )

        appState.saveSettings()

        XCTAssertTrue(signatureScheduler.installedSchedules.isEmpty)
        XCTAssertEqual(signatureScheduler.removeCalls, 1)
    }

    func testAutomaticSignatureUpdateChangePersistsOnlyAfterSchedulerSucceeds() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let signatureScheduler = AppStateMockSignatureUpdateScheduler()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            signatureUpdateScheduler: signatureScheduler
        )
        let schedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 8, minute: 30),
            dayOfWeek: 4
        )

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: schedule)

        XCTAssertEqual(signatureScheduler.installedSchedules, [schedule])
        XCTAssertTrue(appState.settings.autoUpdateSignatures)
        XCTAssertEqual(appState.settings.updateSchedule, schedule)
        XCTAssertEqual(mockConfig.settings, appState.settings)
        XCTAssertNil(appState.signatureUpdateScheduleError)
    }

    func testAutomaticSignatureUpdateSchedulerFailureLeavesSettingsUnchanged() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let signatureScheduler = AppStateMockSignatureUpdateScheduler()
        signatureScheduler.installError = AppStateTestError.settingsFailure
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            signatureUpdateScheduler: signatureScheduler
        )

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: .daily9am)

        XCTAssertFalse(appState.settings.autoUpdateSignatures)
        XCTAssertEqual(mockConfig.saveSettingsCalls, 0)
        XCTAssertNotNil(appState.signatureUpdateScheduleError)
    }

    func testAutomaticSignatureUpdateSaveFailureRollsBackScheduler() {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        mockConfig.saveError = AppStateTestError.settingsFailure
        let signatureScheduler = AppStateMockSignatureUpdateScheduler()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            signatureUpdateScheduler: signatureScheduler
        )

        appState.setAutomaticSignatureUpdates(enabled: true, schedule: .daily9am)

        XCTAssertEqual(signatureScheduler.installedSchedules, [.daily9am])
        XCTAssertEqual(signatureScheduler.removeCalls, 1)
        XCTAssertFalse(appState.settings.autoUpdateSignatures)
        XCTAssertNotNil(appState.settingsSaveError)
        XCTAssertNotNil(appState.signatureUpdateScheduleError)
    }

    func testStartCustomScanNotificationSwitchesToScanAndOpensPicker() {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let mockWatcher = MockFileWatcher()
        let appState = AppState(configManager: mockConfig, fileWatcher: mockWatcher)

        mockWatcher.reset()
        appState.selectedTab = .dashboard
        appState.shouldOpenCustomScanPicker = false

        NotificationCenter.default.post(name: .startCustomScan, object: nil)

        XCTAssertEqual(appState.selectedTab, .scan)
        XCTAssertTrue(appState.shouldOpenCustomScanPicker)
    }

    func testDashboardSignatureFixStartsUpdateAndPublishesProgress() async throws {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let mockWatcher = MockFileWatcher()
        let freshclamRunner = AppStateDelayedFreshclamRunner()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            freshclamRunner: freshclamRunner
        )
        let component = ScoreComponent(
            title: "Signatures Up to Date",
            isComplete: false,
            points: 25,
            action: .updateSignatures
        )

        DashboardScoreActionHandler.handle(component, appState: appState)

        try await waitUntil {
            freshclamRunner.updateCalls == 1 && appState.isUpdatingSignatures
        }

        XCTAssertEqual(appState.lastUpdateResult?.status, .inProgress)

        freshclamRunner.complete(with: .alreadyUpToDate())
        try await waitUntil { !appState.isUpdatingSignatures }

        XCTAssertEqual(appState.lastUpdateResult?.status, .upToDate)
    }

    func testUpdateSignaturesIgnoresSecondCallWhileFirstUpdateIsInProgress() async throws {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let mockWatcher = MockFileWatcher()
        let freshclamRunner = AppStateDelayedFreshclamRunner()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            freshclamRunner: freshclamRunner
        )

        let firstUpdate = Task { await appState.updateSignatures() }
        try await waitUntil {
            freshclamRunner.updateCalls == 1 && appState.isUpdatingSignatures
        }
        let inProgressResult = appState.lastUpdateResult

        await appState.updateSignatures()

        XCTAssertEqual(freshclamRunner.updateCalls, 1)
        XCTAssertTrue(appState.isUpdatingSignatures)
        XCTAssertEqual(appState.lastUpdateResult, inProgressResult)
        XCTAssertEqual(appState.lastUpdateResult?.status, .inProgress)

        freshclamRunner.complete(with: .alreadyUpToDate())
        await firstUpdate.value

        XCTAssertFalse(appState.isUpdatingSignatures)
        XCTAssertEqual(appState.lastUpdateResult?.status, .upToDate)
    }

    func testScheduledSignatureUpdateSkipsWhenSettingsLoadedFromFallback() async {
        var settings = AppSettings.default
        settings.autoUpdateSignatures = true
        let mockConfig = AppStateMockConfigManager(settings: settings)
        mockConfig.lastSettingsLoadState = .fallbackDueToError(reason: "corrupt")
        let mockWatcher = MockFileWatcher()
        let freshclamRunner = AppStateDelayedFreshclamRunner()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            freshclamRunner: freshclamRunner
        )

        await appState.runScheduledSignatureUpdate()

        XCTAssertEqual(freshclamRunner.updateCalls, 0)
        XCTAssertNil(appState.lastUpdateResult)
    }

    func testUpdateSignaturesPublishesFailureAndClearsUpdatingState() async throws {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let mockWatcher = MockFileWatcher()
        let freshclamRunner = AppStateDelayedFreshclamRunner()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            freshclamRunner: freshclamRunner
        )
        let errorMessage = "Freshclam update failed"
        let updateError = NSError(
            domain: "AppStateTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
        )

        let update = Task { await appState.updateSignatures() }
        try await waitUntil {
            freshclamRunner.updateCalls == 1 && appState.isUpdatingSignatures
        }

        freshclamRunner.complete(throwing: updateError)
        await update.value

        XCTAssertEqual(appState.lastUpdateResult?.status, .failed)
        XCTAssertEqual(appState.lastUpdateResult?.message, errorMessage)
        XCTAssertFalse(appState.isUpdatingSignatures)
    }

    func testThreatScanSendsDetectionNotificationInsteadOfCompletionNotification() async throws {
        var settings = AppSettings.default
        settings.showNotifications = true
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications
        )
        let privatePath = "/Users/alice/Private/medical-record.pdf"
        runner.nextScanReportInfectedFiles = [
            ScanResult(path: privatePath, threatName: "Test.Signature")
        ]
        var options = ScanOptions.default
        options.quarantineInfected = false

        let scan = Task {
            await appState.startScan(
                paths: [URL(fileURLWithPath: privatePath)],
                options: options,
                source: .manual
            )
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        let _ = await scan.value

        XCTAssertEqual(notifications.threatNotifications.count, 1)
        XCTAssertEqual(notifications.threatNotifications.first?.first?.path, privatePath)
        XCTAssertTrue(notifications.scanCompleteReports.isEmpty)
    }

    func testCleanDownloadNotificationIsOnlyRequestedWhenOptedIn() async throws {
        var settings = AppSettings.default
        settings.showNotifications = true
        settings.notifyOnCleanFiles = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications
        )
        let firstDownload = URL(fileURLWithPath: "/Users/alice/Downloads/first.pdf")

        let firstScan = Task {
            await appState.startScan(paths: [firstDownload], options: .default, source: .download)
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        let _ = await firstScan.value
        XCTAssertTrue(notifications.cleanFileURLs.isEmpty)

        appState.settings.notifyOnCleanFiles = true
        let secondDownload = URL(fileURLWithPath: "/Users/alice/Downloads/second.pdf")
        let secondScan = Task {
            await appState.startScan(paths: [secondDownload], options: .default, source: .download)
        }
        try await waitUntil { runner.scanPaths.count == 2 }
        runner.resumeNextScan()
        let _ = await secondScan.value

        XCTAssertEqual(notifications.cleanFileURLs, [secondDownload])
        XCTAssertTrue(notifications.scanCompleteReports.isEmpty)
    }

    func testSignatureUpdateSendsResultNotification() async throws {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let freshclamRunner = AppStateDelayedFreshclamRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            freshclamRunner: freshclamRunner,
            notificationManager: notifications
        )

        let update = Task { await appState.updateSignatures() }
        try await waitUntil { freshclamRunner.updateCalls == 1 }
        freshclamRunner.complete(with: .success(main: "63", daily: "28022", bytecode: "339"))
        await update.value

        XCTAssertEqual(notifications.signatureResults.map(\.status), [.success])
    }

    func testScheduledScanSendsStartingNotificationBeforeRunning() async throws {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let runner = AppStateControlledRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let notifications = AppStateMockNotificationManager()
        notifications.blockScheduledNotification = true
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            scanCoordinator: coordinator,
            notificationManager: notifications
        )
        let scheduledPath = URL(fileURLWithPath: "/tmp/scheduled")

        let scan = Task {
            await appState.runScheduledScan(jobID: nil, paths: [scheduledPath])
        }
        try await waitUntil { notifications.scheduledJobNames == ["Scheduled scan"] }

        XCTAssertTrue(coordinator.isScanning)
        XCTAssertTrue(runner.scanPaths.isEmpty)

        notifications.resumeScheduledNotification()
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        await scan.value

        XCTAssertEqual(notifications.scheduledJobNames, ["Scheduled scan"])
    }

    func testScheduledScanWithNoPathsDoesNotSendStartingNotification() async {
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications
        )

        await appState.runScheduledScan(jobID: nil, paths: [])

        XCTAssertTrue(notifications.scheduledJobNames.isEmpty)
        XCTAssertTrue(runner.scanPaths.isEmpty)
        XCTAssertEqual(appState.scanError, "No scan paths selected.")
    }

    func testScheduledScanWithInvalidClamAVDoesNotSendStartingNotification() async {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        mockConfig.validationStatus = .notInstalled
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications
        )

        await appState.runScheduledScan(
            jobID: nil,
            paths: [URL(fileURLWithPath: "/tmp/scheduled")]
        )

        XCTAssertTrue(notifications.scheduledJobNames.isEmpty)
        XCTAssertTrue(runner.scanPaths.isEmpty)
        XCTAssertEqual(appState.scanError, ClamAVInstallationStatus.notInstalled.message)
    }

    func testScheduledScanRejectedWhileAnotherScanRunsDoesNotSendStartingNotification() async throws {
        let runner = AppStateControlledRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: coordinator,
            notificationManager: notifications
        )
        let manualPath = URL(fileURLWithPath: "/tmp/manual")

        let manualScan = Task {
            await appState.startScan(paths: [manualPath], options: .default, source: .manual)
        }
        try await waitUntil { runner.scanPaths.count == 1 }

        await appState.runScheduledScan(
            jobID: nil,
            paths: [URL(fileURLWithPath: "/tmp/scheduled")]
        )

        XCTAssertTrue(notifications.scheduledJobNames.isEmpty)
        XCTAssertEqual(runner.scanPaths, [[manualPath]])
        XCTAssertEqual(appState.scanError, "Skipped because a manual scan is already running.")

        runner.resumeNextScan()
        let _ = await manualScan.value
    }

    func testRequestNotificationPermissionPublishesManagerState() async {
        let notifications = AppStateMockNotificationManager()
        notifications.permissionStatus = .notDetermined
        notifications.statusAfterRequest = .authorized
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            notificationManager: notifications
        )

        await appState.requestNotificationPermission()

        XCTAssertEqual(appState.notificationPermissionStatus, .authorized)
        XCTAssertNil(appState.notificationPermissionError)
    }

    func testProtectionScoreIsCachedDuringScanProgressUpdates() {
        var settings = AppSettings.default
        settings.monitoringEnabled = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let mockWatcher = MockFileWatcher()
        let appState = AppState(configManager: mockConfig, fileWatcher: mockWatcher)
        mockConfig.resetProtectionScoreInputCalls()

        appState.currentScanProgress = ScanProgress(
            status: .scanning,
            currentFile: "/tmp/example",
            filesScanned: 42,
            infectedCount: 0,
            startTime: Date()
        )

        XCTAssertGreaterThanOrEqual(appState.protectionScore.score, 0)
        XCTAssertEqual(mockConfig.validateInstallationCalls, 0)
        XCTAssertEqual(mockConfig.signatureInfoCalls, 0)
    }

    func testProtectionScoreRefreshesAfterSettingsSave() {
        var settings = AppSettings.default
        settings.monitoringEnabled = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let mockWatcher = MockFileWatcher()
        let appState = AppState(configManager: mockConfig, fileWatcher: mockWatcher)
        let initialScore = appState.protectionScore.score
        mockConfig.resetProtectionScoreInputCalls()

        appState.settings.monitoringEnabled = true
        appState.saveSettings()

        XCTAssertGreaterThan(appState.protectionScore.score, initialScore)
        XCTAssertGreaterThan(mockConfig.validateInstallationCalls, 0)
        XCTAssertGreaterThan(mockConfig.signatureInfoCalls, 0)
    }

    func testSaveSettingsReconfiguresMonitoringAndStopsWhenDisabled() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var initialSettings = AppSettings.default
        initialSettings.monitoringEnabled = false
        initialSettings.autoScanDownloads = false
        initialSettings.monitoredDirectories = [tempDirectory.path]
        let mockConfig = AppStateMockConfigManager(settings: initialSettings)
        let mockWatcher = MockFileWatcher()
        let appState = AppState(configManager: mockConfig, fileWatcher: mockWatcher)

        mockWatcher.reset()
        appState.settings.monitoringEnabled = true
        appState.settings.autoScanDownloads = false
        appState.settings.monitoredDirectories = [tempDirectory.path]
        appState.settings.batchScanIntervalMinutes = 3
        appState.settings.batchScanFileThreshold = 9
        appState.saveSettings()

        XCTAssertEqual(mockWatcher.updateCalls, 1)
        XCTAssertEqual(mockWatcher.lastBatchIntervalMinutes, 3)
        XCTAssertEqual(mockWatcher.lastBatchThreshold, 9)
        XCTAssertEqual(mockWatcher.startCalls, 1)
        XCTAssertTrue(mockWatcher.isWatching)
        XCTAssertEqual(mockWatcher.lastDirectories.map(\.path), [tempDirectory.path])
        XCTAssertEqual(mockWatcher.lastImmediateDirectories, [])

        appState.settings.monitoringEnabled = false
        appState.settings.autoScanDownloads = false
        appState.saveSettings()

        XCTAssertEqual(mockWatcher.stopCalls, 1)
        XCTAssertFalse(mockWatcher.isWatching)
    }

    func testAutoScanDownloadsWatchesDownloadsWithoutDirectoryMonitoring() {
        var settings = AppSettings.default
        settings.monitoringEnabled = false
        settings.autoScanDownloads = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let mockWatcher = MockFileWatcher()
        let appState = AppState(configManager: mockConfig, fileWatcher: mockWatcher)
        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .standardizedFileURL

        mockWatcher.reset()
        appState.settings.autoScanDownloads = true
        appState.saveSettings()

        XCTAssertEqual(mockWatcher.startCalls, 1)
        XCTAssertEqual(mockWatcher.lastDirectories, [downloadsURL])
        XCTAssertEqual(mockWatcher.lastImmediateDirectories, [downloadsURL])
        XCTAssertTrue(mockWatcher.isWatching)
    }

    func testDownloadsDetectedDuringManualScanAreCoalescedAndScannedWhenIdle() async throws {
        var settings = AppSettings.default
        settings.autoScanDownloads = true
        settings.monitoringEnabled = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let mockWatcher = MockFileWatcher()
        let runner = AppStateControlledRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            scanCoordinator: coordinator
        )
        let manualURL = URL(fileURLWithPath: "/tmp/manual")
        let firstDownloadURL = URL(fileURLWithPath: "/tmp/download-one")
        let secondDownloadURL = URL(fileURLWithPath: "/tmp/download-two")
        runner.nextScanReportInfectedFiles = [
            ScanResult(path: "/tmp/missing-test-infected-file", threatName: "Test.Signature")
        ]

        let manualScan = Task { @MainActor in
            await appState.startScan(paths: [manualURL], options: .default, source: .manual)
        }
        try await waitUntil { runner.scanPaths.count == 1 }

        mockWatcher.detect(firstDownloadURL)
        mockWatcher.detect(secondDownloadURL)
        XCTAssertEqual(runner.scanPaths, [[manualURL]])

        runner.resumeNextScan()
        try await waitUntil { runner.scanPaths.count == 2 }
        let _ = await manualScan.value

        XCTAssertEqual(runner.scanPaths[1], [firstDownloadURL, secondDownloadURL])
        XCTAssertTrue(appState.isScanning)
        XCTAssertEqual(appState.currentScanProgress?.status, .preparing)

        runner.resumeNextScan()
        try await waitUntil { !appState.isScanning }
        XCTAssertNil(appState.currentScanProgress)
    }

    func testDisablingDownloadAutoScanClearsPendingDownloads() async throws {
        var settings = AppSettings.default
        settings.autoScanDownloads = true
        settings.monitoringEnabled = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let mockWatcher = MockFileWatcher()
        let runner = AppStateControlledRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            scanCoordinator: coordinator
        )
        let manualURL = URL(fileURLWithPath: "/tmp/manual")
        let downloadURL = URL(fileURLWithPath: "/tmp/download")

        let manualScan = Task { @MainActor in
            await appState.startScan(paths: [manualURL], options: .default, source: .manual)
        }
        try await waitUntil { runner.scanPaths.count == 1 }

        mockWatcher.detect(downloadURL)
        await Task.yield()
        await Task.yield()
        appState.settings.autoScanDownloads = false
        appState.saveSettings()

        runner.resumeNextScan()
        let _ = await manualScan.value
        for _ in 0..<20 {
            await Task.yield()
        }

        if runner.scanPaths.count > 1 {
            runner.resumeNextScan()
        }
        XCTAssertEqual(runner.scanPaths, [[manualURL]])
    }

    func testReenablingDownloadAutoScanDoesNotStartClearedPendingWork() async throws {
        var settings = AppSettings.default
        settings.autoScanDownloads = true
        settings.monitoringEnabled = false
        let mockConfig = AppStateMockConfigManager(settings: settings)
        let mockWatcher = MockFileWatcher()
        let runner = AppStateControlledRunner()
        let coordinator = ScanCoordinator(clamAVRunner: runner)
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: mockWatcher,
            scanCoordinator: coordinator
        )
        let manualURL = URL(fileURLWithPath: "/tmp/manual")
        let downloadURL = URL(fileURLWithPath: "/tmp/download")

        let manualScan = Task { @MainActor in
            await appState.startScan(paths: [manualURL], options: .default, source: .manual)
        }
        try await waitUntil { runner.scanPaths.count == 1 }

        mockWatcher.detect(downloadURL)
        for _ in 0..<20 {
            await Task.yield()
        }
        appState.settings.autoScanDownloads = false
        appState.saveSettings()
        appState.settings.autoScanDownloads = true
        appState.saveSettings()

        runner.resumeNextScan()
        let _ = await manualScan.value
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(runner.scanPaths, [[manualURL]])
        XCTAssertNil(appState.scanError)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() {
                return
            }
            try await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
        }
        throw AppStateTestError.conditionTimedOut
    }
}

private enum AppStateTestError: LocalizedError {
    case conditionTimedOut
    case loginItemFailure
    case settingsFailure

    var errorDescription: String? {
        switch self {
        case .conditionTimedOut:
            return "Timed out waiting for an asynchronous AppState test condition."
        case .loginItemFailure:
            return "The login item could not be registered."
        case .settingsFailure:
            return "The settings file could not be written."
        }
    }
}

private final class AppStateMockLoginItemService: LaunchAtLoginService {
    var serviceStatus: LaunchAtLoginServiceStatus
    var statusAfterRegister: LaunchAtLoginServiceStatus = .enabled
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: LaunchAtLoginServiceStatus) {
        serviceStatus = status
    }

    func register() throws {
        registerCalls += 1
        if let registerError {
            throw registerError
        }
        serviceStatus = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError {
            throw unregisterError
        }
        serviceStatus = .notRegistered
    }
}

private final class AppStateDelayedFreshclamRunner: FreshclamRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedUpdateCalls = 0
    private var continuation: CheckedContinuation<UpdateResult, Error>?

    var updateCalls: Int {
        lock.withLock { storedUpdateCalls }
    }

    func update() async throws -> UpdateResult {
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                storedUpdateCalls += 1
            }
        }
    }

    func checkForUpdates() async throws -> Bool {
        true
    }

    func complete(with result: UpdateResult) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }

    func complete(throwing error: Error) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: error)
    }
}

private final class AppStateMockConfigManager: ConfigManagerProtocol {
    var settings: AppSettings
    var saveError: Error?
    var validationStatus: ClamAVInstallationStatus?
    var lastSettingsLoadState: SettingsLoadState = .loaded
    private(set) var saveSettingsCalls = 0
    private(set) var validateInstallationCalls = 0
    private(set) var signatureInfoCalls = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    func loadSettings() -> AppSettings {
        settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        saveSettingsCalls += 1
        if let saveError {
            throw saveError
        }
        self.settings = settings
    }

    func detectClamAVPaths() -> (clamscan: String?, freshclam: String?, configDir: String?) {
        (settings.clamScanPath, settings.freshclamPath, settings.configDirectory)
    }

    func validateClamAVInstallation() -> ClamAVInstallationStatus {
        validateInstallationCalls += 1
        return validationStatus ?? .ready(clamscanPath: settings.clamScanPath)
    }

    func validateClamAVInstallation(using settings: AppSettings) -> ClamAVInstallationStatus {
        validationStatus ?? .ready(clamscanPath: settings.clamScanPath)
    }

    func getSignatureInfo() -> SignatureInfo {
        signatureInfoCalls += 1
        return SignatureInfo(
            mainVersion: "1",
            dailyVersion: "1",
            bytecodeVersion: "1",
            lastUpdated: Date(),
            signatureCount: nil
        )
    }

    func resetProtectionScoreInputCalls() {
        validateInstallationCalls = 0
        signatureInfoCalls = 0
    }
}

private final class AppStateMockSignatureUpdateScheduler: SignatureUpdateSchedulerProtocol {
    var installError: Error?
    var removeError: Error?
    private(set) var installedSchedules: [ScanSchedule?] = []
    private(set) var removeCalls = 0

    func install(schedule: ScanSchedule) throws {
        if let installError {
            throw installError
        }
        installedSchedules.append(schedule)
    }

    func remove() throws {
        if let removeError {
            throw removeError
        }
        removeCalls += 1
    }

    func launchArguments(executablePath: String) -> [String] {
        [executablePath, "--update-signatures"]
    }
}

private final class MockFileWatcher: FileWatcherProtocol {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var updateCalls = 0
    private(set) var lastDirectories: [URL] = []
    private(set) var lastBatchIntervalMinutes = 0
    private(set) var lastBatchThreshold = 0
    private(set) var lastImmediateDirectories: [URL] = []
    private var batchHandler: (([URL]) -> Void)?

    var isWatching = false
    var onNewFileDetected: ((URL) -> Void)?

    func startWatching(directories: [URL], handler: @escaping ([URL]) -> Void) {
        startCalls += 1
        isWatching = true
        lastDirectories = directories
        batchHandler = handler
    }

    func stopWatching() {
        stopCalls += 1
        isWatching = false
        batchHandler = nil
    }

    func updateConfiguration(batchIntervalMinutes: Int, batchThreshold: Int) {
        updateCalls += 1
        lastBatchIntervalMinutes = batchIntervalMinutes
        lastBatchThreshold = batchThreshold
    }

    func configureImmediateScanDirectories(_ directories: [URL]) {
        lastImmediateDirectories = directories
    }

    func detect(_ url: URL) {
        onNewFileDetected?(url)
    }

    func reset() {
        startCalls = 0
        stopCalls = 0
        updateCalls = 0
        lastDirectories = []
        lastBatchIntervalMinutes = 0
        lastBatchThreshold = 0
        lastImmediateDirectories = []
        batchHandler = nil
        isWatching = false
    }
}

private final class AppStateControlledRunner: ClamAVRunnerProtocol {
    private(set) var scanPaths: [[URL]] = []
    private var continuations: [CheckedContinuation<ScanReport, Error>] = []
    var nextScanReportInfectedFiles: [ScanResult] = []

    var currentProcessPID: Int32?
    var scanIsPaused = false

    func scan(paths: [URL], options: ScanOptions, progressHandler: @escaping (ScanProgress) -> Void) async throws -> ScanReport {
        scanPaths.append(paths)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNextScan() {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        let infectedFiles = nextScanReportInfectedFiles
        nextScanReportInfectedFiles = []
        continuation.resume(returning: ScanReport(
            startTime: Date(),
            endTime: Date(),
            filesScanned: 1,
            infectedFiles: infectedFiles,
            errors: [],
            scanPaths: scanPaths.first ?? [],
            exitCode: 0,
            completionState: .success
        ))
    }

    func cancelCurrentScan() {}

    func pauseScan() {
        scanIsPaused = true
    }

    func resumeScan() {
        scanIsPaused = false
    }
}

@MainActor
private final class AppStateMockNotificationManager: NotificationManaging {
    var permissionStatus: NotificationPermissionStatus = .authorized
    var permissionError: String?
    var statusAfterRequest: NotificationPermissionStatus?
    var blockScheduledNotification = false
    private(set) var threatNotifications: [[ScanResult]] = []
    private(set) var scanCompleteReports: [ScanReport] = []
    private(set) var cleanFileURLs: [URL] = []
    private(set) var signatureResults: [UpdateResult] = []
    private(set) var scheduledJobNames: [String] = []
    private var scheduledContinuation: CheckedContinuation<Void, Never>?

    func setupNotificationCategories() {}
    func refreshPermissionStatus() async {}

    func requestPermission() async {
        if let statusAfterRequest {
            permissionStatus = statusAfterRequest
        }
    }

    func sendScanComplete(report: ScanReport, settings: AppSettings) async {
        scanCompleteReports.append(report)
    }

    func sendThreatDetected(threats: [ScanResult], settings: AppSettings) async {
        threatNotifications.append(threats)
    }

    func sendFileClean(url: URL, settings: AppSettings) async {
        cleanFileURLs.append(url)
    }

    func sendSignaturesUpdated(result: UpdateResult, settings: AppSettings) async {
        signatureResults.append(result)
    }

    func sendScheduledScanStarting(jobName: String, settings: AppSettings) async {
        scheduledJobNames.append(jobName)
        if blockScheduledNotification {
            await withCheckedContinuation { continuation in
                scheduledContinuation = continuation
            }
        }
    }

    func resumeScheduledNotification() {
        scheduledContinuation?.resume()
        scheduledContinuation = nil
    }
}
