import AppKit
import SwiftUI
import Combine

enum SignatureUpdateScheduleState: Equatable {
    case configured(enabled: Bool)
    case indeterminate
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: NavigationTab = .dashboard
    @Published var isScanning: Bool = false
    @Published var currentScanProgress: ScanProgress?
    @Published var isScanPaused = false
    @Published var lastScanResult: ScanReport?
    @Published var lastUpdateResult: UpdateResult?
    @Published var isUpdatingSignatures = false
    @Published var quarantinedFiles: [QuarantinedFile] = []
    @Published private(set) var quarantineLoadError: String?
    @Published var settings: AppSettings
    @Published var logs: [LogEntry] = []
    @Published var scanError: String?
    @Published private(set) var isMonitoringActive = false
    @Published var settingsSaveError: String?
    @Published var launchAtLoginError: String?
    @Published var signatureUpdateScheduleError: String?
    @Published var scheduledScanMigrationError: String?
    @Published private(set) var signatureUpdateScheduleState: SignatureUpdateScheduleState
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .unknown
    @Published private(set) var notificationPermissionError: String?
    @Published private(set) var backgroundHelperNotificationPermissionError: String?
    @Published var shouldOpenCustomScanPicker = false
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var protectionScore: ProtectionScore

    let configManager: ConfigManagerProtocol
    let clamAVRunner: ClamAVRunner
    let freshclamRunner: FreshclamRunnerProtocol
    let quarantineManager: QuarantineManager
    let scanScheduler: ScanScheduler
    let fileWatcher: FileWatcherProtocol
    let scanCoordinator: ScanCoordinator
    let externalScanRequestStore: ExternalScanRequestStore
    let backgroundRouteRequestStore: BackgroundRouteRequestStore
    let scanHistoryManager: ScanHistoryManager
    let protectionScoreManager: ProtectionScoreManager
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let signatureUpdateScheduler: any SignatureUpdateScheduling
    private let allowsSignatureScheduleStartupReconciliation: Bool
    let notificationManager: NotificationManaging
    private let backgroundHelperNotificationAuthorizationRequester: any BackgroundHelperNotificationAuthorizationRequesting

    private let logManager = LogManager()
    private var cancellables = Set<AnyCancellable>()
    private var pendingAutomaticDownloadPaths: [URL] = []
    private var isProcessingAutomaticDownloads = false
    private var activeScanGeneration: UUID?
    private var scanLifecycleSource: ScanSource?
    private var scanLifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingAutomaticMonitoringPaths: [URL] = []
    private var isProcessingAutomaticMonitoring = false
    private var pendingExternalScanRequestIDs = Set<UUID>()
    private var shouldLoadAllExternalScanRequests = false
    private var isConsumingExternalScanRequests = false

    init(
        configManager: ConfigManagerProtocol = ConfigManager(),
        scanScheduler: ScanScheduler = ScanScheduler(),
        fileWatcher: FileWatcherProtocol? = nil,
        scanCoordinator: ScanCoordinator? = nil,
        freshclamRunner: FreshclamRunnerProtocol? = nil,
        notificationManager: NotificationManaging? = nil,
        externalScanRequestStore: ExternalScanRequestStore = ExternalScanRequestStore(),
        backgroundRouteRequestStore: BackgroundRouteRequestStore = BackgroundRouteRequestStore(),
        scanHistoryManager: ScanHistoryManager = ScanHistoryManager(),
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginManager(),
        signatureUpdateScheduler: any SignatureUpdateScheduling = SignatureUpdateScheduler(),
        backgroundHelperNotificationAuthorizationRequester: (any BackgroundHelperNotificationAuthorizationRequesting)? = nil,
        startsInteractiveBackgroundServices: Bool = true
    ) {
        var loadedSettings = configManager.loadSettings()
        let settingsLoadState = configManager.lastSettingsLoadState
        let loginItemMigrationError: String?
        do {
            try launchAtLoginManager.migrateLegacyRegistrationIfNeeded()
            loginItemMigrationError = nil
        } catch {
            loginItemMigrationError = "SafeMac AV could not finish moving your login item to its background helper. Check Login Items in System Settings."
        }
        let initialLaunchAtLoginStatus = launchAtLoginManager.status
        let shouldPersistLaunchAtLoginStatus = loadedSettings.launchAtLogin != initialLaunchAtLoginStatus.isRequested
        loadedSettings.launchAtLogin = initialLaunchAtLoginStatus.isRequested
        let runner = ClamAVRunner(configManager: configManager)
        let resolvedNotificationManager = notificationManager ?? NotificationManager.shared

        self.configManager = configManager
        self.settings = loadedSettings
        self.clamAVRunner = runner
        self.freshclamRunner = freshclamRunner ?? FreshclamRunner(configManager: configManager)
        self.notificationManager = resolvedNotificationManager
        self.backgroundHelperNotificationAuthorizationRequester = backgroundHelperNotificationAuthorizationRequester
            ?? SystemBackgroundHelperNotificationAuthorizationRequester()
        self.quarantineManager = QuarantineManager(configManager: configManager)
        self.scanScheduler = scanScheduler
        self.fileWatcher = fileWatcher ?? FileWatcher(
            batchIntervalMinutes: loadedSettings.batchScanIntervalMinutes,
            batchThreshold: loadedSettings.batchScanFileThreshold
        )
        self.scanCoordinator = scanCoordinator ?? ScanCoordinator(clamAVRunner: runner)
        self.externalScanRequestStore = externalScanRequestStore
        self.backgroundRouteRequestStore = backgroundRouteRequestStore
        self.scanHistoryManager = scanHistoryManager
        self.launchAtLoginManager = launchAtLoginManager
        self.signatureUpdateScheduler = signatureUpdateScheduler
        self.allowsSignatureScheduleStartupReconciliation = settingsLoadState.allowsStartupReconciliationPersistence
        self.launchAtLoginStatus = initialLaunchAtLoginStatus
        self.signatureUpdateScheduleState = .configured(enabled: loadedSettings.autoUpdateSignatures)
        let scoreManager = ProtectionScoreManager(configManager: configManager)
        self.protectionScoreManager = scoreManager
        self.protectionScore = scoreManager.calculateScore(
            lastScanDate: nil,
            monitoringEnabled: false,
            finderExtensionEnabled: FinderExtensionManager.isEnabled
        )
        self.notificationPermissionStatus = resolvedNotificationManager.permissionStatus
        self.notificationPermissionError = resolvedNotificationManager.permissionError

        if let loginItemMigrationError {
            launchAtLoginError = loginItemMigrationError
            addLog(.warning, loginItemMigrationError)
        }

        loadQuarantinedFiles()
        resolvedNotificationManager.setupNotificationCategories()
        if startsInteractiveBackgroundServices {
            setupNotifications()
            setupFileWatcherAutoScan()
            configureMonitoring()
        }

        if shouldPersistLaunchAtLoginStatus, settingsLoadState.allowsStartupReconciliationPersistence {
            persistLaunchAtLoginReconciliation()
        } else if shouldPersistLaunchAtLoginStatus {
            settingsSaveError = "Your settings could not be loaded. SafeMac AV is using default settings until you save changes."
            addLog(.error, "Skipped launch-at-login reconciliation because settings could not be loaded safely")
        }

        Task { [weak self] in
            await self?.refreshNotificationPermissionStatus()
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .startQuickScan)
            .sink { [weak self] _ in
                Task { await self?.startQuickScan() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .startCustomScan)
            .sink { [weak self] _ in
                self?.selectedTab = .scan
                self?.shouldOpenCustomScanPicker = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .updateSignatures)
            .sink { [weak self] _ in
                Task { await self?.updateSignatures() }
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default().addObserver(
            forName: ExternalScanRequestStore.scanRequestNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let requestID = notification.userInfo?["requestID"] as? String,
                   let id = UUID(uuidString: requestID) {
                    await self.drainExternalScanRequest(id: id)
                } else {
                    await self.drainExternalScanRequests()
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: ExternalScanRequestStore.scanRequestFailedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleFinderHandoffFailure(notification)
            }
        }

        for route in BackgroundRoute.allCases {
            DistributedNotificationCenter.default().addObserver(
                forName: route.distributedNotificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.drainBackgroundRouteRequests()
                }
            }
        }
    }

    private func handleBackgroundRoute(_ route: BackgroundRoute) -> Bool {
        switch route {
        case .open:
            return MainWindowControllerRegistry.shared.showMainWindow(selecting: .dashboard)
        case .settings:
            return MainWindowControllerRegistry.shared.showMainWindow(selecting: .settings)
        case .checkForUpdates:
            NotificationCenter.default.post(name: .checkForAppUpdates, object: nil)
            return true
        }
    }

    @discardableResult
    func drainBackgroundRouteRequests() -> Int {
        guard MainWindowControllerRegistry.shared.isRouterAvailable else { return 0 }
        var count = 0
        while let route = backgroundRouteRequestStore.consume() {
            guard handleBackgroundRoute(route) else {
                _ = backgroundRouteRequestStore.enqueue(route)
                break
            }
            count += 1
        }
        return count
    }

    func handleFinderHandoffFailure(_: Notification) {
        selectedTab = .scan
        scanError = FinderScanRequestHandoff.genericFailureMessage
        addLog(.warning, FinderScanRequestHandoff.genericFailureMessage)
    }

    func startQuickScan() async {
        let quickScanPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        ]
        await startScan(paths: quickScanPaths, options: ScanOptions.default, scanType: .quick, source: .quick)
    }

    @discardableResult
    func startScan(
        paths: [URL],
        options: ScanOptions,
        scanType: ScanType = .custom,
        source: ScanSource = .custom,
        jobID: UUID? = nil,
        onAdmitted: (() async throws -> Void)? = nil
    ) async -> ScanOutcome {
        guard !paths.isEmpty else {
            scanError = "No scan paths selected."
            addLog(.warning, "Skipped scan: no paths selected")
            return .failed("No scan paths selected.")
        }

        let status = configManager.validateClamAVInstallation(using: settings)
        if !status.isReady {
            scanError = status.message
            addLog(.error, "Cannot scan: \(status.message)")
            return .failed(status.message)
        }

        guard scanLifecycleSource == nil, !scanCoordinator.isScanning else {
            let outcome = ScanOutcome.skippedAlreadyRunning(active: scanLifecycleSource ?? scanCoordinator.activeScanSource)
            scanError = outcome.errorMessage
            addLog(.warning, outcome.errorMessage ?? "Skipped scan because another scan is running")
            return outcome
        }

        scanLifecycleSource = source
        defer {
            scanLifecycleSource = nil
            let waiters = scanLifecycleWaiters
            scanLifecycleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let generation = UUID()
        activeScanGeneration = generation
        scanError = nil
        isScanning = true
        isScanPaused = false
        currentScanProgress = ScanProgress(status: .preparing, currentFile: nil, filesScanned: 0, infectedCount: 0, startTime: Date())

        let request = ScanRequest(source: source, paths: paths, options: options, jobID: jobID)
        let admissionFailureMessage = source == .finder
            ? FinderScanRequestHandoff.genericFailureMessage
            : "SafeMac AV couldn’t start this scan. Try again."
        var outcome = await scanCoordinator.run(
            request,
            onAdmitted: onAdmitted,
            admissionFailureMessage: admissionFailureMessage
        ) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activeScanGeneration == generation else { return }
                self.currentScanProgress = progress
            }
        }
        if activeScanGeneration == generation {
            activeScanGeneration = nil
        }

        switch outcome {
        case .completed(let report):
            if isScanning {
                currentScanProgress = ScanProgress(
                    status: .completing, currentFile: nil, filesScanned: report.filesScanned,
                    infectedCount: report.infectedFiles.count, startTime: report.startTime
                )
            }
            var results = report.infectedFiles
            var errors = report.errors
            if options.quarantineInfected {
                for index in results.indices {
                    let result = results[index]
                    do {
                        try await quarantineManager.quarantine(file: result.path, threat: result.threatName)
                        results[index].actionTaken = .quarantined
                    } catch {
                        errors.append("\((result.path as NSString).lastPathComponent) could not be quarantined. The detected threat may remain at its original location. Review the logs before retrying.")
                        addLog(.error, "Failed to quarantine \(result.path): \(error.localizedDescription)")
                    }
                }
                loadQuarantinedFiles()
            }
            let finalReport = ScanReport(
                startTime: report.startTime, endTime: report.endTime,
                filesScanned: report.filesScanned, infectedFiles: results,
                errors: errors, scanPaths: report.scanPaths,
                exitCode: report.exitCode, completionState: report.completionState
            )
            lastScanResult = finalReport
            outcome = .completed(finalReport)
            scanHistoryManager.addEntry(ScanHistoryEntry(from: finalReport, scanType: scanType))
            addLog(.info, "Scan completed: \(report.filesScanned) files scanned, \(report.infectedFiles.count) threats found")
            await sendScanNotification(report: finalReport, source: source, requestedPaths: paths)
        case .failed(let message):
            scanError = message
            addLog(.error, "Scan failed: \(message)")
        case .cancelled:
            scanError = "Scan was cancelled."
            addLog(.info, "Scan cancelled")
        case .skippedAlreadyRunning:
            scanError = outcome.errorMessage
            addLog(.warning, outcome.errorMessage ?? "Skipped scan")
        }

        isScanning = scanCoordinator.isScanning
        if !scanCoordinator.isScanning {
            isScanPaused = false
            currentScanProgress = nil
        }
        refreshProtectionScore()
        return outcome
    }

    func cancelScan() {
        guard scanCoordinator.isScanning else { return }
        activeScanGeneration = nil
        scanCoordinator.cancelCurrentScan()
        isScanning = false
        isScanPaused = false
        currentScanProgress = nil
        addLog(.info, "Scan cancelled by user")
    }

    func pauseScan() {
        guard scanCoordinator.isScanning, scanCoordinator.currentProcessPID != nil else { return }
        scanCoordinator.pauseScan()
        isScanPaused = scanCoordinator.scanIsPaused
        guard isScanPaused else { return }
        if var progress = currentScanProgress {
            progress.status = .paused
            currentScanProgress = progress
        }
        addLog(.info, "Scan paused")
    }

    func resumeScan() {
        guard scanCoordinator.isScanning, scanCoordinator.currentProcessPID != nil else { return }
        scanCoordinator.resumeScan()
        isScanPaused = scanCoordinator.scanIsPaused
        guard !isScanPaused else { return }
        if var progress = currentScanProgress {
            progress.status = .scanning
            currentScanProgress = progress
        }
        addLog(.info, "Scan resumed")
    }

    func updateSignatures() async {
        await updateSignatures(using: nil)
    }

    private func updateSignatures(using settingsSnapshot: AppSettings?) async {
        guard !isUpdatingSignatures else {
            addLog(.info, "Signature update already in progress")
            return
        }

        isUpdatingSignatures = true
        lastUpdateResult = .inProgress()
        addLog(.info, "Starting signature update...")
        defer { isUpdatingSignatures = false }

        do {
            let result: UpdateResult
            if let settingsSnapshot {
                result = try await freshclamRunner.update(using: settingsSnapshot)
            } else {
                result = try await freshclamRunner.update()
            }
            lastUpdateResult = result
            addLog(.info, "Signature update completed: \(result.status.rawValue)")
        } catch {
            lastUpdateResult = .failed(error: error.localizedDescription)
            addLog(.error, "Signature update failed: \(error.localizedDescription)")
        }
        if settings.showNotifications, let result = lastUpdateResult {
            await notificationManager.sendSignaturesUpdated(result: result, settings: settings)
            updateNotificationPermissionState()
        }
        refreshProtectionScore()
    }

    func loadQuarantinedFiles() {
        do {
            quarantinedFiles = try quarantineManager.readQuarantinedFiles()
            quarantineLoadError = nil
        } catch {
            quarantineLoadError = "Quarantine could not be read. Existing files were left unchanged. Check the quarantine folder and try again."
            addLog(.error, "Could not load quarantine: \(error.localizedDescription)")
        }
    }

    func restoreFromQuarantine(_ file: QuarantinedFile) async throws {
        try await quarantineManager.restore(file: file)
        loadQuarantinedFiles()
        addLog(.info, "Restored file from quarantine: \(file.originalPath)")
    }

    func deleteFromQuarantine(_ file: QuarantinedFile) throws {
        try quarantineManager.delete(file: file)
        loadQuarantinedFiles()
        addLog(.info, "Deleted file from quarantine: \(file.originalPath)")
    }

    func saveSettings() {
        do {
            try configManager.saveSettings(settings)
            settingsSaveError = nil
        } catch {
            settingsSaveError = "Your settings could not be saved. Check that the app can write to Application Support, then try again."
            addLog(.error, "Failed to save settings: \(error.localizedDescription)")
        }
        if !settings.autoScanDownloads {
            pendingAutomaticDownloadPaths.removeAll()
        }
        if !settings.monitoringEnabled {
            pendingAutomaticMonitoringPaths.removeAll()
        }
        configureMonitoring()
        refreshProtectionScore()
    }

    func setAutomaticSignatureUpdates(enabled: Bool, schedule: ScanSchedule) {
        let previousSettings = settings
        var updatedSettings = settings
        updatedSettings.autoUpdateSignatures = enabled
        updatedSettings.updateSchedule = schedule
        signatureUpdateScheduleError = nil

        do {
            try signatureUpdateScheduler.reconcile(enabled: enabled, schedule: schedule)
        } catch {
            if Self.requiresIndeterminateScheduleState(after: error) {
                signatureUpdateScheduleState = .indeterminate
            } else {
                signatureUpdateScheduleState = .configured(
                    enabled: previousSettings.autoUpdateSignatures
                )
            }
            signatureUpdateScheduleError = "SafeMac AV could not update the automatic signature schedule. Try again."
            addLog(.error, "Failed to update automatic signature schedule")
            return
        }

        do {
            try configManager.saveSettings(updatedSettings)
            settings = updatedSettings
            signatureUpdateScheduleState = .configured(enabled: enabled)
            settingsSaveError = nil
            addLog(.info, enabled ? "Enabled automatic signature updates" : "Disabled automatic signature updates")
        } catch {
            settingsSaveError = "Your settings could not be saved. Check that the app can write to Application Support, then try again."
            do {
                try signatureUpdateScheduler.reconcile(
                    enabled: previousSettings.autoUpdateSignatures,
                    schedule: previousSettings.updateSchedule ?? .daily9am
                )
                signatureUpdateScheduleState = .configured(
                    enabled: previousSettings.autoUpdateSignatures
                )
                signatureUpdateScheduleError = "The automatic signature schedule was not changed because your settings could not be saved."
            } catch {
                signatureUpdateScheduleState = .indeterminate
                signatureUpdateScheduleError = "SafeMac AV could not save or roll back the automatic signature schedule. Review the schedule and try again."
                addLog(.error, "Failed to roll back automatic signature schedule")
            }
            settings = previousSettings
            addLog(.error, "Failed to save automatic signature schedule")
        }
    }

    func reconcileSignatureUpdateSchedule() {
        guard allowsSignatureScheduleStartupReconciliation else {
            signatureUpdateScheduleState = .indeterminate
            signatureUpdateScheduleError = "SafeMac AV could not load your saved automatic signature schedule. Review and save it again."
            addLog(.error, "Skipped automatic signature schedule reconciliation because settings could not be loaded safely")
            return
        }

        do {
            try signatureUpdateScheduler.reconcile(
                enabled: settings.autoUpdateSignatures,
                schedule: settings.updateSchedule ?? .daily9am
            )
            signatureUpdateScheduleState = .configured(enabled: settings.autoUpdateSignatures)
            signatureUpdateScheduleError = nil
        } catch {
            signatureUpdateScheduleState = .indeterminate
            signatureUpdateScheduleError = "SafeMac AV could not activate the automatic signature schedule. Open Updates and try again."
            addLog(.error, "Failed to reconcile automatic signature schedule")
        }
    }

    func reconcileScheduledScanStorage() {
        do {
            try scanScheduler.migrateLegacyState()
            scheduledScanMigrationError = nil
        } catch {
            scheduledScanMigrationError = "SafeMac AV could not migrate scheduled scans. Open Schedules and review them."
            addLog(.error, "Failed to migrate legacy scheduled scans")
        }
    }

    func runScheduledSignatureUpdate() async {
        guard allowsSignatureScheduleStartupReconciliation else {
            addLog(.error, "Skipped scheduled signature update because settings could not be loaded safely")
            return
        }
        guard settings.autoUpdateSignatures else {
            addLog(.info, "Skipped scheduled signature update because automatic updates are disabled")
            return
        }
        let lease = BackgroundWorkLease(name: "signature-update")
        guard lease.acquire() else {
            addLog(.info, "Skipped scheduled signature update because another SafeMac AV process is already updating signatures")
            return
        }
        defer { lease.release() }
        await updateSignatures(using: settings)
    }

    private static func requiresIndeterminateScheduleState(after error: Error) -> Bool {
        switch error {
        case SignatureUpdateSchedulerError.reconciliationAndRollbackFailed:
            return true
        case SignatureUpdateSchedulerError.launchctlFailed(let command, _):
            return command == "print"
        default:
            return false
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let previousSettings = settings
        let previousStatus = launchAtLoginStatus
        launchAtLoginError = nil

        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLoginStatus = launchAtLoginManager.status
            guard launchAtLoginStatus.isRequested == enabled else {
                throw LaunchAtLoginUpdateError.unexpectedStatus(launchAtLoginStatus)
            }

            var updatedSettings = settings
            updatedSettings.launchAtLogin = launchAtLoginStatus.isRequested

            do {
                try configManager.saveSettings(updatedSettings)
                settings = updatedSettings
                settingsSaveError = nil
                addLog(.info, enabled ? "Enabled launch at login" : "Disabled launch at login")
            } catch {
                rollbackLaunchAtLogin(
                    to: previousStatus,
                    previousSettings: previousSettings,
                    persistenceError: error
                )
            }
        } catch {
            launchAtLoginStatus = launchAtLoginManager.status
            var reconciledSettings = settings
            reconciledSettings.launchAtLogin = launchAtLoginStatus.isRequested
            settings = reconciledSettings
            launchAtLoginError = "SafeMac AV could not update launch at login. \(error.localizedDescription)"
            addLog(.error, "Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    func refreshLaunchAtLoginStatus() {
        let currentStatus = launchAtLoginManager.status
        guard currentStatus != launchAtLoginStatus || settings.launchAtLogin != currentStatus.isRequested else {
            return
        }

        launchAtLoginStatus = currentStatus
        var reconciledSettings = settings
        reconciledSettings.launchAtLogin = currentStatus.isRequested
        settings = reconciledSettings
        launchAtLoginError = nil
        persistLaunchAtLoginReconciliation()
    }

    private func rollbackLaunchAtLogin(
        to previousStatus: LaunchAtLoginStatus,
        previousSettings: AppSettings,
        persistenceError: Error
    ) {
        settingsSaveError = "Your settings could not be saved. Check that the app can write to Application Support, then try again."

        do {
            try launchAtLoginManager.setEnabled(previousStatus.isRequested)
            launchAtLoginStatus = launchAtLoginManager.status
            var restoredSettings = previousSettings
            restoredSettings.launchAtLogin = launchAtLoginStatus.isRequested
            settings = restoredSettings
            launchAtLoginError = "Launch at login was not changed because your settings could not be saved."
        } catch {
            launchAtLoginStatus = launchAtLoginManager.status
            var reconciledSettings = previousSettings
            reconciledSettings.launchAtLogin = launchAtLoginStatus.isRequested
            settings = reconciledSettings
            launchAtLoginError = "SafeMac AV changed the login item, but could not save or roll back the setting. Review Login Items in System Settings."
            addLog(.error, "Failed to roll back launch at login: \(error.localizedDescription)")
        }

        addLog(.error, "Failed to save launch-at-login setting: \(persistenceError.localizedDescription)")
    }

    private func persistLaunchAtLoginReconciliation() {
        do {
            try configManager.saveSettings(settings)
            settingsSaveError = nil
        } catch {
            settingsSaveError = "Your settings could not be saved. Check that the app can write to Application Support, then try again."
            addLog(.error, "Failed to reconcile launch-at-login setting: \(error.localizedDescription)")
        }
    }

    func refreshProtectionScore() {
        protectionScore = protectionScoreManager.calculateScore(
            lastScanDate: lastScanResult.flatMap { $0.completedWithoutErrors ? $0.endTime : nil },
            monitoringEnabled: isMonitoringActive,
            finderExtensionEnabled: FinderExtensionManager.isEnabled
        )
    }

    private func addLog(_ level: LogLevel, _ message: String) {
        logManager.add(level, message)
        logs = logManager.entries
    }

    @discardableResult
    func drainExternalScanRequests() async -> Int {
        shouldLoadAllExternalScanRequests = true
        return await consumeExternalScanRequests()
    }

    @discardableResult
    func drainExternalScanRequest(id: UUID) async -> Int {
        pendingExternalScanRequestIDs.insert(id)
        return await consumeExternalScanRequests()
    }

    private func consumeExternalScanRequests() async -> Int {
        guard !isConsumingExternalScanRequests else { return 0 }

        isConsumingExternalScanRequests = true
        defer { isConsumingExternalScanRequests = false }
        var admittedCount = 0

        while shouldLoadAllExternalScanRequests || !pendingExternalScanRequestIDs.isEmpty {
            let loadAll = shouldLoadAllExternalScanRequests
            let requestIDs = pendingExternalScanRequestIDs
            shouldLoadAllExternalScanRequests = false
            pendingExternalScanRequestIDs.removeAll()

            let requests: [ExternalScanRequest]
            do {
                if loadAll {
                    requests = try externalScanRequestStore.claimRequests()
                } else {
                    requests = try requestIDs.flatMap { try externalScanRequestStore.claimRequest(id: $0) }
                        .sorted { $0.createdAt < $1.createdAt }
                }
            } catch {
                addLog(.error, "SafeMac AV could not read the Finder scan request queue.")
                continue
            }

            for request in requests {
                await waitUntilScanLifecycleIdle()
                var didAcknowledge = false
                let outcome = await startScan(
                    paths: request.paths.map { URL(fileURLWithPath: $0) },
                    options: .default,
                    scanType: .custom,
                    source: .finder
                ) { [weak self] in
                    guard let self else { return }
                    do {
                        try self.externalScanRequestStore.acknowledgeClaim(id: request.id)
                        didAcknowledge = true
                    } catch {
                        self.addLog(.error, "SafeMac AV could not acknowledge a Finder scan request.")
                        throw error
                    }
                }

                if didAcknowledge {
                    admittedCount += 1
                } else if case .skippedAlreadyRunning = outcome {
                    pendingExternalScanRequestIDs.insert(request.id)
                }
            }
        }

        return admittedCount
    }

    func runScheduledScan(jobID: UUID?, paths: [URL]) async {
        let job = jobID.flatMap { scanScheduler.scheduledScan(jobID: $0) }
        let scanPaths = job?.paths.map { URL(fileURLWithPath: $0) } ?? paths
        let options = job?.options ?? .default
        let jobName = job?.name ?? "Scheduled scan"
        let outcome = await startScan(
            paths: scanPaths,
            options: options,
            scanType: .scheduled,
            source: .scheduled,
            jobID: jobID
        ) { [weak self] in
            guard let self, self.settings.showNotifications else { return }
            await self.notificationManager.sendScheduledScanStarting(
                jobName: jobName,
                settings: self.settings
            )
            self.updateNotificationPermissionState()
        }

        if let jobID {
            scanScheduler.markScheduledScanRun(jobID: jobID, result: outcome.scheduledResultMessage, at: Date())
        }
    }

    /// Scanning remains exclusive while quarantine and result publication finish.
    private func waitUntilScanLifecycleIdle() async {
        while scanLifecycleSource != nil || scanCoordinator.isScanning {
            if scanLifecycleSource != nil {
                await withCheckedContinuation { scanLifecycleWaiters.append($0) }
            } else {
                await scanCoordinator.waitUntilIdle()
            }
        }
    }

    private func setupFileWatcherAutoScan() {
        fileWatcher.onNewFileDetected = { [weak self] url in
            guard let self, self.settings.autoScanDownloads else { return }
            Task { @MainActor in
                self.enqueueAutomaticDownloadScan(url)
            }
        }
    }

    private func enqueueAutomaticDownloadScan(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard !pendingAutomaticDownloadPaths.contains(standardizedURL) else { return }

        pendingAutomaticDownloadPaths.append(standardizedURL)
        guard !isProcessingAutomaticDownloads else { return }

        isProcessingAutomaticDownloads = true
        Task { @MainActor [weak self] in
            await self?.processAutomaticDownloadScans()
        }
    }

    private func processAutomaticDownloadScans() async {
        defer { isProcessingAutomaticDownloads = false }

        while !pendingAutomaticDownloadPaths.isEmpty {
            await waitUntilScanLifecycleIdle()

            guard settings.autoScanDownloads else {
                pendingAutomaticDownloadPaths.removeAll()
                break
            }

            guard !pendingAutomaticDownloadPaths.isEmpty else { break }

            guard scanLifecycleSource == nil, !scanCoordinator.isScanning else { continue }

            let paths = pendingAutomaticDownloadPaths
            pendingAutomaticDownloadPaths.removeAll()
            let outcome = await startScan(
                paths: paths,
                options: realtimeOptions(),
                scanType: .realtime,
                source: .download
            )

            if case .skippedAlreadyRunning = outcome {
                pendingAutomaticDownloadPaths = uniqueDirectories(paths + pendingAutomaticDownloadPaths)
            }
        }
    }

    private func enqueueAutomaticMonitoringScan(_ urls: [URL]) {
        guard settings.monitoringEnabled else { return }
        pendingAutomaticMonitoringPaths = uniqueDirectories(
            pendingAutomaticMonitoringPaths + urls.map(\.standardizedFileURL)
        )
        guard !isProcessingAutomaticMonitoring else { return }
        isProcessingAutomaticMonitoring = true
        Task { @MainActor [weak self] in
            await self?.processAutomaticMonitoringScans()
        }
    }

    private func processAutomaticMonitoringScans() async {
        defer { isProcessingAutomaticMonitoring = false }
        while !pendingAutomaticMonitoringPaths.isEmpty {
            await waitUntilScanLifecycleIdle()
            guard settings.monitoringEnabled else {
                pendingAutomaticMonitoringPaths.removeAll()
                break
            }
            guard !pendingAutomaticMonitoringPaths.isEmpty else { break }
            guard scanLifecycleSource == nil, !scanCoordinator.isScanning else { continue }
            let paths = pendingAutomaticMonitoringPaths
            pendingAutomaticMonitoringPaths.removeAll()
            let outcome = await startScan(
                paths: paths, options: realtimeOptions(), scanType: .realtime, source: .realtime
            )
            if case .skippedAlreadyRunning = outcome {
                pendingAutomaticMonitoringPaths = uniqueDirectories(paths + pendingAutomaticMonitoringPaths)
            }
        }
    }

    private func configureMonitoring() {
        defer {
            isMonitoringActive = settings.monitoringEnabled && fileWatcher.isWatching
                && settings.monitoredDirectories.contains { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
            refreshProtectionScore()
        }
        fileWatcher.updateConfiguration(
            batchIntervalMinutes: settings.batchScanIntervalMinutes,
            batchThreshold: settings.batchScanFileThreshold
        )

        let downloadsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .standardizedFileURL
        let immediateDirectories = settings.autoScanDownloads ? [downloadsDirectory] : []
        fileWatcher.configureImmediateScanDirectories(immediateDirectories)

        let monitoredDirectories = settings.monitoringEnabled
            ? settings.monitoredDirectories.map { URL(fileURLWithPath: $0).standardizedFileURL }
            : []
        let directories = uniqueDirectories(monitoredDirectories + immediateDirectories)

        guard !directories.isEmpty else {
            fileWatcher.stopWatching()
            return
        }

        fileWatcher.startWatching(directories: directories) { [weak self] files in
            guard let self else { return }
            Task { @MainActor in
                self.enqueueAutomaticMonitoringScan(files)
            }
        }
    }

    private func uniqueDirectories(_ directories: [URL]) -> [URL] {
        directories.reduce(into: [URL]()) { result, directory in
            if !result.contains(directory) {
                result.append(directory)
            }
        }
    }

    private func realtimeOptions() -> ScanOptions {
        var options = ScanOptions.default
        options.recursive = false
        options.excludedPaths = settings.allExclusions
        return options
    }

    func refreshNotificationPermissionStatus() async {
        await notificationManager.refreshPermissionStatus()
        updateNotificationPermissionState()
    }

    func requestNotificationPermission() async {
        await notificationManager.requestPermission()
        updateNotificationPermissionState()
    }

    /// The login helper has a separate bundle notification identity. Request
    /// it only from a deliberate foreground Settings tap.
    func requestBackgroundHelperNotificationPermission() async {
        let didLaunchRequest = await backgroundHelperNotificationAuthorizationRequester.requestAuthorization()
        backgroundHelperNotificationPermissionError = didLaunchRequest
            ? nil
            : "SafeMac AV could not open its background helper to request notification permission."
    }

    private func sendScanNotification(
        report: ScanReport,
        source: ScanSource,
        requestedPaths: [URL]
    ) async {
        guard settings.showNotifications else { return }

        if !report.infectedFiles.isEmpty {
            await notificationManager.sendThreatDetected(
                threats: report.infectedFiles,
                settings: settings
            )
        } else if source == .download {
            if !report.completedWithoutErrors {
                await notificationManager.sendScanComplete(report: report, settings: settings)
            } else if settings.notifyOnCleanFiles {
                if requestedPaths.count == 1, report.filesScanned == 1, let path = requestedPaths.first {
                    await notificationManager.sendFileClean(url: path, settings: settings)
                } else {
                    // A batch count cannot establish which individual download was scanned.
                    await notificationManager.sendScanComplete(report: report, settings: settings)
                }
            }
        } else {
            await notificationManager.sendScanComplete(report: report, settings: settings)
        }
        updateNotificationPermissionState()
    }

    private func updateNotificationPermissionState() {
        notificationPermissionStatus = notificationManager.permissionStatus
        notificationPermissionError = notificationManager.permissionError
    }
}

@MainActor
protocol BackgroundHelperNotificationAuthorizationRequesting: AnyObject {
    func requestAuthorization() async -> Bool
}

@MainActor
final class SystemBackgroundHelperNotificationAuthorizationRequester: BackgroundHelperNotificationAuthorizationRequesting {
    private let mainBundleURL: URL
    private let isEmbeddedHelper: (URL, URL) -> Bool
    private let openApplication: (URL, NSWorkspace.OpenConfiguration, @escaping (Error?) -> Void) -> Void

    init(
        mainBundleURL: URL = Bundle.main.bundleURL,
        isEmbeddedHelper: @escaping (URL, URL) -> Bool = { executable, mainBundle in
            BackgroundHelperBundle.isEmbeddedHelper(at: executable, in: mainBundle)
        },
        openApplication: @escaping (URL, NSWorkspace.OpenConfiguration, @escaping (Error?) -> Void) -> Void = { url, configuration, completion in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                completion(error)
            }
        }
    ) {
        self.mainBundleURL = mainBundleURL
        self.isEmbeddedHelper = isEmbeddedHelper
        self.openApplication = openApplication
    }

    func requestAuthorization() async -> Bool {
        let executable = BackgroundHelperBundle.executableURL(in: mainBundleURL)
        guard isEmbeddedHelper(executable, mainBundleURL) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        // The normal login helper can already be running and retains its own
        // launch arguments. Permission therefore uses a dedicated one-shot
        // helper instance, which exits after completing this fixed action.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--request-notification-authorization"]
        return await withCheckedContinuation { continuation in
            openApplication(BackgroundHelperBundle.bundleURL(in: mainBundleURL), configuration) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

private enum LaunchAtLoginUpdateError: LocalizedError {
    case unexpectedStatus(LaunchAtLoginStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "The system reported launch at login as \(status.title.lowercased())."
        }
    }
}

enum NavigationTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case scan = "Scan"
    case quarantine = "Quarantine"
    case history = "History"
    case updates = "Updates"
    case scheduler = "Scheduler"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .scan: return "magnifyingglass"
        case .quarantine: return "lock.shield"
        case .history: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        case .scheduler: return "calendar.badge.clock"
        case .logs: return "doc.text"
        case .settings: return "gear"
        }
    }

    var accessibilitySlug: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    var sidebarAccessibilityIdentifier: String {
        "sidebar-\(accessibilitySlug)"
    }
}
