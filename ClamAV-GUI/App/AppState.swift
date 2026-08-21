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
    @Published var settings: AppSettings
    @Published var logs: [LogEntry] = []
    @Published var scanError: String?
    @Published var settingsSaveError: String?
    @Published var launchAtLoginError: String?
    @Published var signatureUpdateScheduleError: String?
    @Published private(set) var signatureUpdateScheduleState: SignatureUpdateScheduleState
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .unknown
    @Published private(set) var notificationPermissionError: String?
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
    let scanHistoryManager: ScanHistoryManager
    let protectionScoreManager: ProtectionScoreManager
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let signatureUpdateScheduler: any SignatureUpdateScheduling
    private let allowsSignatureScheduleStartupReconciliation: Bool
    let notificationManager: NotificationManaging

    private let logManager = LogManager()
    private var cancellables = Set<AnyCancellable>()
    private var pendingAutomaticDownloadPaths: [URL] = []
    private var isProcessingAutomaticDownloads = false

    init(
        configManager: ConfigManagerProtocol = ConfigManager(),
        scanScheduler: ScanScheduler = ScanScheduler(),
        fileWatcher: FileWatcherProtocol? = nil,
        scanCoordinator: ScanCoordinator? = nil,
        freshclamRunner: FreshclamRunnerProtocol? = nil,
        notificationManager: NotificationManaging? = nil,
        externalScanRequestStore: ExternalScanRequestStore = ExternalScanRequestStore(),
        scanHistoryManager: ScanHistoryManager = ScanHistoryManager(),
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginManager(),
        signatureUpdateScheduler: any SignatureUpdateScheduling = SignatureUpdateScheduler()
    ) {
        var loadedSettings = configManager.loadSettings()
        let settingsLoadState = configManager.lastSettingsLoadState
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
        self.quarantineManager = QuarantineManager(configManager: configManager)
        self.scanScheduler = scanScheduler
        self.fileWatcher = fileWatcher ?? FileWatcher(
            batchIntervalMinutes: loadedSettings.batchScanIntervalMinutes,
            batchThreshold: loadedSettings.batchScanFileThreshold
        )
        self.scanCoordinator = scanCoordinator ?? ScanCoordinator(clamAVRunner: runner)
        self.externalScanRequestStore = externalScanRequestStore
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
            monitoringEnabled: loadedSettings.monitoringEnabled,
            finderExtensionEnabled: FinderExtensionManager.isEnabled
        )
        self.notificationPermissionStatus = resolvedNotificationManager.permissionStatus
        self.notificationPermissionError = resolvedNotificationManager.permissionError

        loadQuarantinedFiles()
        resolvedNotificationManager.setupNotificationCategories()
        setupNotifications()
        setupFileWatcherAutoScan()
        configureMonitoring()

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
            forName: NSNotification.Name("com.newtonlorenz.ClamAV-GUI.scanRequest"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                let drainedCount = await self.drainExternalScanRequests()
                guard drainedCount == 0,
                      let data = notification.userInfo?["paths"] as? Data,
                      let paths = try? JSONDecoder().decode([String].self, from: data) else {
                    return
                }
                await self.startScan(paths: paths.map { URL(fileURLWithPath: $0) }, options: .default, scanType: .custom, source: .finder)
            }
        }
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
        onAdmitted: (() async -> Void)? = nil
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

        guard !scanCoordinator.isScanning else {
            let outcome = ScanOutcome.skippedAlreadyRunning(active: scanCoordinator.activeScanSource)
            scanError = outcome.errorMessage
            addLog(.warning, outcome.errorMessage ?? "Skipped scan because another scan is running")
            return outcome
        }

        scanError = nil
        isScanning = true
        isScanPaused = false
        currentScanProgress = ScanProgress(status: .preparing, currentFile: nil, filesScanned: 0, infectedCount: 0, startTime: Date())

        let request = ScanRequest(source: source, paths: paths, options: options, jobID: jobID)
        let outcome = await scanCoordinator.run(request, onAdmitted: onAdmitted) { [weak self] progress in
            Task { @MainActor in
                self?.currentScanProgress = progress
            }
        }

        switch outcome {
        case .completed(let report):
            lastScanResult = report

            if options.quarantineInfected {
                for result in report.infectedFiles {
                    do {
                        try await quarantineManager.quarantine(file: result.path, threat: result.threatName)
                    } catch {
                        addLog(.error, "Failed to quarantine \(result.path): \(error.localizedDescription)")
                    }
                }
                loadQuarantinedFiles()
            }

            scanHistoryManager.addEntry(ScanHistoryEntry(from: report, scanType: scanType))
            addLog(.info, "Scan completed: \(report.filesScanned) files scanned, \(report.infectedFiles.count) threats found")
            await sendScanNotification(report: report, source: source, requestedPaths: paths)
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
        scanCoordinator.cancelCurrentScan()
        isScanning = false
        isScanPaused = false
        currentScanProgress = nil
        addLog(.info, "Scan cancelled by user")
    }

    func pauseScan() {
        scanCoordinator.pauseScan()
        isScanPaused = scanCoordinator.scanIsPaused
        if var progress = currentScanProgress {
            progress.status = .paused
            currentScanProgress = progress
        }
        addLog(.info, "Scan paused")
    }

    func resumeScan() {
        scanCoordinator.resumeScan()
        isScanPaused = scanCoordinator.scanIsPaused
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
        quarantinedFiles = quarantineManager.listQuarantinedFiles()
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
            if case SignatureUpdateSchedulerError.reconciliationAndRollbackFailed = error {
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

    func runScheduledSignatureUpdate() async {
        guard allowsSignatureScheduleStartupReconciliation else {
            addLog(.error, "Skipped scheduled signature update because settings could not be loaded safely")
            return
        }
        guard settings.autoUpdateSignatures else {
            addLog(.info, "Skipped scheduled signature update because automatic updates are disabled")
            return
        }
        await updateSignatures(using: settings)
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
            lastScanDate: lastScanResult?.endTime,
            monitoringEnabled: settings.monitoringEnabled,
            finderExtensionEnabled: FinderExtensionManager.isEnabled
        )
    }

    private func addLog(_ level: LogLevel, _ message: String) {
        logManager.add(level, message)
        logs = logManager.entries
    }

    @discardableResult
    func drainExternalScanRequests() async -> Int {
        do {
            let requests = try externalScanRequestStore.drainRequests()
            for request in requests {
                await startScan(
                    paths: request.paths.map { URL(fileURLWithPath: $0) },
                    options: .default,
                    scanType: .custom,
                    source: ScanSource(rawValue: request.source) ?? .finder
                )
            }
            return requests.count
        } catch {
            addLog(.error, "Failed to load external scan requests: \(error.localizedDescription)")
            return 0
        }
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
            await scanCoordinator.waitUntilIdle()

            guard settings.autoScanDownloads else {
                pendingAutomaticDownloadPaths.removeAll()
                break
            }

            guard !pendingAutomaticDownloadPaths.isEmpty else { break }

            guard !scanCoordinator.isScanning else { continue }

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

    private func configureMonitoring() {
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
                await self.startScan(paths: files, options: self.realtimeOptions(), scanType: .realtime, source: .realtime)
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
        } else if source == .download, settings.notifyOnCleanFiles, let firstPath = requestedPaths.first {
            await notificationManager.sendFileClean(url: firstPath, settings: settings)
        } else if source != .download {
            await notificationManager.sendScanComplete(report: report, settings: settings)
        }
        updateNotificationPermissionState()
    }

    private func updateNotificationPermissionState() {
        notificationPermissionStatus = notificationManager.permissionStatus
        notificationPermissionError = notificationManager.permissionError
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
