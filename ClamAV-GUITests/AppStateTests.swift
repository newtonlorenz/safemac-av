import XCTest
@testable import ClamAV_GUI

@MainActor
final class AppStateTests: XCTestCase {
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

    var errorDescription: String? {
        "Timed out waiting for an asynchronous AppState test condition."
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
    private(set) var validateInstallationCalls = 0
    private(set) var signatureInfoCalls = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    func loadSettings() -> AppSettings {
        settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        self.settings = settings
    }

    func detectClamAVPaths() -> (clamscan: String?, freshclam: String?, configDir: String?) {
        (settings.clamScanPath, settings.freshclamPath, settings.configDirectory)
    }

    func validateClamAVInstallation() -> ClamAVInstallationStatus {
        validateInstallationCalls += 1
        return .ready(clamscanPath: settings.clamScanPath)
    }

    func validateClamAVInstallation(using settings: AppSettings) -> ClamAVInstallationStatus {
        .ready(clamscanPath: settings.clamScanPath)
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
