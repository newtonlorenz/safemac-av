import SwiftUI
import Combine

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
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .unknown
    @Published private(set) var notificationPermissionError: String?
    @Published var shouldOpenCustomScanPicker = false
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
        notificationManager: NotificationManaging = NotificationManager.shared,
        externalScanRequestStore: ExternalScanRequestStore = ExternalScanRequestStore(),
        scanHistoryManager: ScanHistoryManager = ScanHistoryManager()
    ) {
        let loadedSettings = configManager.loadSettings()
        let runner = ClamAVRunner(configManager: configManager)

        self.configManager = configManager
        self.settings = loadedSettings
        self.clamAVRunner = runner
        self.freshclamRunner = freshclamRunner ?? FreshclamRunner(configManager: configManager)
        self.notificationManager = notificationManager
        self.quarantineManager = QuarantineManager(configManager: configManager)
        self.scanScheduler = scanScheduler
        self.fileWatcher = fileWatcher ?? FileWatcher(
            batchIntervalMinutes: loadedSettings.batchScanIntervalMinutes,
            batchThreshold: loadedSettings.batchScanFileThreshold
        )
        self.scanCoordinator = scanCoordinator ?? ScanCoordinator(clamAVRunner: runner)
        self.externalScanRequestStore = externalScanRequestStore
        self.scanHistoryManager = scanHistoryManager
        let scoreManager = ProtectionScoreManager(configManager: configManager)
        self.protectionScoreManager = scoreManager
        self.protectionScore = scoreManager.calculateScore(
            lastScanDate: nil,
            monitoringEnabled: loadedSettings.monitoringEnabled,
            finderExtensionEnabled: FinderExtensionManager.isEnabled
        )
        self.notificationPermissionStatus = notificationManager.permissionStatus
        self.notificationPermissionError = notificationManager.permissionError

        loadQuarantinedFiles()
        notificationManager.setupNotificationCategories()
        setupNotifications()
        setupFileWatcherAutoScan()
        configureMonitoring()
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
        jobID: UUID? = nil
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
        let outcome = await scanCoordinator.run(request) { [weak self] progress in
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
        guard !isUpdatingSignatures else {
            addLog(.info, "Signature update already in progress")
            return
        }

        isUpdatingSignatures = true
        lastUpdateResult = .inProgress()
        addLog(.info, "Starting signature update...")
        defer { isUpdatingSignatures = false }

        do {
            let result = try await freshclamRunner.update()
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
        if settings.showNotifications {
            await notificationManager.sendScheduledScanStarting(
                jobName: job?.name ?? "Scheduled scan",
                settings: settings
            )
            updateNotificationPermissionState()
        }
        let outcome = await startScan(paths: scanPaths, options: options, scanType: .scheduled, source: .scheduled, jobID: jobID)

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
