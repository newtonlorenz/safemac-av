import XCTest
@testable import ClamAV_GUI

@MainActor
final class AppStateTests: XCTestCase {
    func testRestoreCannotMoveAQuarantinedFileDuringAnActiveScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("harmless.txt")
        try Data("harmless fixture".utf8).write(to: source)
        var settings = AppSettings.default
        settings.quarantineDirectory = root.appendingPathComponent("quarantine").path
        let state = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        try await state.quarantineManager.quarantine(file: source.path, threat: "Test.Fixture")
        state.loadQuarantinedFiles()
        let file = try XCTUnwrap(state.quarantinedFiles.first)
        state.isScanning = true
        do {
            try await state.restoreFromQuarantine(file)
            XCTFail("A scan must finish before a quarantined file can be restored")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.quarantinePath))
    }

    func testDeleteCannotRemoveAQuarantinedFileDuringAnActiveScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("harmless.txt")
        try Data("harmless fixture".utf8).write(to: source)
        var settings = AppSettings.default
        settings.quarantineDirectory = root.appendingPathComponent("quarantine").path
        let state = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        try await state.quarantineManager.quarantine(file: source.path, threat: "Test.Fixture")
        state.loadQuarantinedFiles()
        let file = try XCTUnwrap(state.quarantinedFiles.first)
        state.isScanning = true
        do {
            try state.deleteFromQuarantine(file)
            XCTFail("A scan must finish before a quarantined file can be deleted")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.quarantinePath))
        XCTAssertEqual(try state.quarantineManager.readQuarantinedFiles().count, 1)
    }

    func testRestoreFailureIsRetainedAfterNavigatingAway() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("harmless.txt")
        try Data("harmless fixture".utf8).write(to: source)
        var settings = AppSettings.default
        settings.quarantineDirectory = root.appendingPathComponent("quarantine").path
        let state = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        try await state.quarantineManager.quarantine(file: source.path, threat: "Test.Fixture")
        state.loadQuarantinedFiles()
        let file = try XCTUnwrap(state.quarantinedFiles.first)
        try FileManager.default.removeItem(atPath: file.quarantinePath)
        let restore = Task {
            do { try await state.restoreFromQuarantine(file); XCTFail("Missing payload must fail") }
            catch { }
        }
        state.selectedTab = .settings
        await restore.value
        XCTAssertEqual(state.selectedTab, .settings)
        XCTAssertTrue(state.quarantineActionError?.message.contains("harmless.txt") == true)
        XCTAssertTrue(state.logs.contains { $0.message.contains("Failed to restore") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testManualQuarantineFailureRemainsAvailableOutsideResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings.default
        settings.quarantineDirectory = root.appendingPathComponent("quarantine").path
        let state = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let detection = ScanResult(path: root.appendingPathComponent("missing.txt").path, threatName: "Test.Fixture")
        state.lastScanResult = ScanReport(startTime: Date(), endTime: Date(), filesScanned: 1, infectedFiles: [detection], errors: [], scanPaths: [root])
        do { try await state.quarantineDetection(detection); XCTFail("Missing source must fail") }
        catch { }
        state.selectedTab = .dashboard
        XCTAssertTrue(state.quarantineActionError?.message.contains("missing.txt") == true)
        XCTAssertEqual(state.lastScanResult?.infectedFiles.first?.actionTaken, .reported)
        XCTAssertFalse(state.isManagingQuarantine)
    }

    func testScanDraftDeduplicatesFilesAndSurvivesNavigation() {
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        state.addScanDraftPaths([URL(fileURLWithPath: "/tmp/scan/../file"), URL(fileURLWithPath: "/tmp/file")])
        state.scanDraftOptions.quarantineInfected = false
        state.requestCustomScan()
        state.selectedTab = .settings
        state.selectedTab = .scan
        XCTAssertEqual(state.scanDraftPaths, [URL(fileURLWithPath: "/tmp/file")])
        XCTAssertFalse(state.scanDraftOptions.quarantineInfected)
        XCTAssertTrue(state.isPreparingNewScan)
    }

    func testPresentLastScanResultPreservesDraftAndShowsReport() {
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let paths = [URL(fileURLWithPath: "/tmp/unsent-draft")]
        state.scanDraftPaths = paths
        state.scanDraftOptions.quarantineInfected = false
        let options = state.scanDraftOptions
        state.isPreparingNewScan = true
        state.selectedTab = .dashboard
        state.lastScanResult = ScanReport(startTime: Date(), endTime: Date(), filesScanned: 1, infectedFiles: [], errors: [], scanPaths: [])
        state.presentLastScanResult()
        XCTAssertEqual(state.selectedTab, .scan)
        XCTAssertFalse(state.isPreparingNewScan)
        XCTAssertEqual(state.scanDraftPaths, paths)
        XCTAssertEqual(state.scanDraftOptions, options)
        XCTAssertNotNil(state.lastScanResult)
    }

    func testManualScanDoesNotWaitUncancellablyBehindQuarantine() async {
        let runner = AppStateControlledRunner()
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        state.isManagingQuarantine = true
        let outcome = await state.startScan(paths: [URL(fileURLWithPath: "/tmp/fixture")], options: .default)
        XCTAssertEqual(outcome, .skippedAlreadyRunning(active: nil))
        XCTAssertTrue(runner.scanPaths.isEmpty)
        XCTAssertFalse(state.isScanning)
        XCTAssertTrue(state.scanError?.localizedCaseInsensitiveContains("quarantine") == true)
        state.isManagingQuarantine = false
    }

    func testAutomaticMonitoringRetainsQueuedFilesUntilQuarantineFinishes() async throws {
        var settings = AppSettings.default
        settings.monitoringEnabled = true
        settings.autoScanDownloads = false
        let watcher = MockFileWatcher()
        let runner = AppStateControlledRunner()
        let state = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: watcher, scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager())
        state.isManagingQuarantine = true
        let changed = URL(fileURLWithPath: "/tmp/queued-fixture")
        watcher.detectBatch([changed])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(runner.scanPaths.isEmpty)
        state.isManagingQuarantine = false
        try await waitUntil { runner.scanPaths.count == 1 }
        XCTAssertEqual(runner.scanPaths, [[changed]])
        runner.resumeNextScan()
        try await waitUntil { !state.isScanning }
    }

    func testFailedAdvancedSettingsApplyDoesNotChangeActiveSettings() {
        let config = AppStateMockConfigManager(settings: .default)
        let state = AppState(configManager: config, fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let original = state.settings
        var edited = original
        edited.clamScanPath = "/different/scanner"
        config.saveError = AppStateTestError.settingsFailure
        XCTAssertFalse(state.applySettings(edited))
        XCTAssertEqual(state.settings.clamScanPath, original.clamScanPath)
        XCTAssertEqual(config.settings.clamScanPath, original.clamScanPath)
        XCTAssertNotNil(state.settingsSaveError)
    }

    func testForegroundScanNavigatesToProgressAndAutomaticScanDoesNot() async throws {
        let runner = AppStateControlledRunner()
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let path = URL(fileURLWithPath: "/tmp/ux-fixture")
        let manual = Task { await state.startScan(paths: [path], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        XCTAssertEqual(state.selectedTab, .scan)
        runner.resumeNextScan()
        _ = await manual.value
        state.selectedTab = .settings
        let automatic = Task { await state.startScan(paths: [path], options: .default, source: .realtime) }
        try await waitUntil { runner.scanPaths.count == 2 }
        XCTAssertEqual(state.selectedTab, .settings)
        runner.resumeNextScan()
        _ = await automatic.value
    }

    func testCancellationKeepsProgressVisibleUntilTheProcessFinishes() async throws {
        let runner = AppStateControlledRunner()
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let scan = Task { await state.startScan(paths: [URL(fileURLWithPath: "/tmp/ux-fixture")], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        state.cancelScan()
        XCTAssertTrue(state.isScanning, "Do not jump back to an older result while termination is pending")
        XCTAssertNotNil(state.currentScanProgress)
        runner.resumeNextScan(completionState: .cancelled)
        _ = await scan.value
        XCTAssertFalse(state.isScanning)
        XCTAssertEqual(state.lastScanResult?.completionState, .cancelled)
    }

    func testCancelledScanPreservesActualPartialDetectionsAndHistory() async throws {
        let runner = AppStateControlledRunner()
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let path = URL(fileURLWithPath: "/tmp/partial-fixture")
        let detection = ScanResult(path: path.path, threatName: "Test.Signature")
        let scan = Task { await state.startScan(paths: [path], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.interruptedReport = ScanReport(startTime: Date(), endTime: Date(), filesScanned: 4, infectedFiles: [detection], errors: ["Stopped"], scanPaths: [path], exitCode: -1, completionState: .cancelled)
        state.cancelScan()
        runner.failNextScan(ClamAVError.cancelled)
        _ = await scan.value
        XCTAssertEqual(state.lastScanResult?.infectedFiles, [detection])
        XCTAssertEqual(state.scanHistoryManager.entries.first?.threatsFound, 1)
        XCTAssertEqual(state.scanHistoryManager.entries.first?.report.infectedFiles.first?.actionTaken, .reported)
        XCTAssertEqual(state.lastScanResult?.filesScanned, 4)
    }

    func testCancelledScanPreservesObservedCountWhenDetectionDetailsAreUnavailable() async throws {
        let runner = AppStateControlledRunner()
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let scan = Task { await state.startScan(paths: [URL(fileURLWithPath: "/tmp/partial-fixture")], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        state.currentScanProgress = ScanProgress(status: .scanning, filesScanned: 8, infectedCount: 3, startTime: Date())
        state.cancelScan()
        runner.failNextScan(ClamAVError.cancelled)
        _ = await scan.value
        let report = try XCTUnwrap(state.lastScanResult)
        XCTAssertTrue(report.infectedFiles.isEmpty, "Do not invent paths for missing detection details")
        XCTAssertEqual(state.scanHistoryManager.entries.first?.threatsFound, 3)
        XCTAssertTrue(report.errors.joined().localizedCaseInsensitiveContains("unavailable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.exportJSONData()) as? [String: Any])
        XCTAssertEqual(json["observedThreatCount"] as? Int, 3)
        XCTAssertTrue(String(decoding: report.exportCSVData(), as: UTF8.self).contains("\"8\",\"3\""))
    }

    func testManualQuarantineUpdatesHistoricalReportAndKeepsEntryIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.txt")
        try Data("harmless fixture".utf8).write(to: source)
        var settings = AppSettings.default
        settings.quarantineDirectory = directory.appendingPathComponent("quarantine").path
        let state = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: MockFileWatcher(), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let detection = ScanResult(path: source.path, threatName: "Test.Signature")
        let report = ScanReport(startTime: Date(), endTime: Date(), filesScanned: 1, infectedFiles: [detection], errors: [], scanPaths: [source], completionState: .infectedFound)
        state.lastScanResult = report
        let entry = ScanHistoryEntry(from: report, scanType: .custom)
        state.scanHistoryManager.addEntry(entry)
        try await state.quarantineDetection(detection)
        let updated = try XCTUnwrap(state.scanHistoryManager.entries.first)
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.report.infectedFiles.first?.actionTaken, .quarantined)
        XCTAssertTrue(String(decoding: try updated.report.exportJSONData(), as: UTF8.self).contains("Quarantined"))
        XCTAssertTrue(String(decoding: updated.report.exportCSVData(), as: UTF8.self).contains("Quarantined"))
    }

    func testPauseCannotReenterPausedStateWhileCancellationIsPending() async throws {
        let runner = AppStateControlledRunner()
        runner.currentProcessPID = 123
        let state = AppState(configManager: AppStateMockConfigManager(settings: .default), fileWatcher: MockFileWatcher(), scanCoordinator: ScanCoordinator(clamAVRunner: runner), notificationManager: AppStateMockNotificationManager(), startsInteractiveBackgroundServices: false)
        let scan = Task { await state.startScan(paths: [URL(fileURLWithPath: "/tmp/fixture")], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        state.cancelScan()
        state.pauseScan()
        state.resumeScan()
        XCTAssertFalse(runner.scanIsPaused)
        XCTAssertEqual(state.currentScanProgress?.status, .cancelling)
        runner.failNextScan(ClamAVError.cancelled)
        _ = await scan.value
    }

    func testPauseAndResumeDoNotChangePreparingScanBeforeProcessLaunch() async throws {
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        notifications.blockScheduledNotification = true
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications,
            startsInteractiveBackgroundServices: false
        )
        let scan = Task {
            await appState.runScheduledScan(jobID: nil, paths: [URL(fileURLWithPath: "/tmp/fixture")])
        }
        try await waitUntil { notifications.scheduledJobNames.count == 1 }
        XCTAssertTrue(runner.scanPaths.isEmpty)
        appState.pauseScan()
        XCTAssertFalse(appState.isScanPaused)
        XCTAssertEqual(appState.currentScanProgress?.status, .preparing)
        appState.resumeScan()
        XCTAssertEqual(appState.currentScanProgress?.status, .preparing)
        notifications.resumeScheduledNotification()
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        await scan.value
    }

    func testScanControlsCannotInterruptResultFinalisation() async throws {
        var settings = AppSettings.default
        settings.showNotifications = true
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        notifications.blockCompletionNotification = true
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications,
            startsInteractiveBackgroundServices: false
        )
        let scan = Task {
            await appState.startScan(paths: [URL(fileURLWithPath: "/tmp/fixture")], options: .default)
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        try await waitUntil { notifications.scanCompleteReports.count == 1 }
        XCTAssertEqual(appState.currentScanProgress?.status, .completing)
        appState.pauseScan()
        XCTAssertFalse(appState.isScanPaused)
        XCTAssertEqual(appState.currentScanProgress?.status, .completing)
        appState.resumeScan()
        XCTAssertEqual(appState.currentScanProgress?.status, .completing)
        appState.cancelScan()
        XCTAssertTrue(appState.isScanning)
        XCTAssertEqual(appState.currentScanProgress?.status, .completing)
        notifications.resumeCompletionNotification()
        _ = await scan.value
        XCTAssertFalse(appState.isScanning)
        XCTAssertNotNil(appState.lastScanResult)
    }

    func testAutomaticScanWaitsUntilPreviousScanFinalisationCompletes() async throws {
        var settings = AppSettings.default
        settings.monitoringEnabled = true
        settings.autoScanDownloads = false
        settings.showNotifications = true
        let watcher = MockFileWatcher()
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        notifications.blockCompletionNotification = true
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: watcher,
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications
        )
        let firstPath = URL(fileURLWithPath: "/tmp/first-fixture")
        let changedPath = URL(fileURLWithPath: "/tmp/changed-fixture")
        let first = Task { await appState.startScan(paths: [firstPath], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        try await waitUntil { notifications.scanCompleteReports.count == 1 }
        watcher.detectBatch([changedPath])
        for _ in 0..<30 { await Task.yield() }
        let prematureScan = runner.scanPaths.count > 1
        XCTAssertFalse(prematureScan, "The previous scan must finish publishing its result before admitting queued work")
        if prematureScan { runner.resumeNextScan() }
        notifications.resumeCompletionNotification()
        _ = await first.value
        if !prematureScan {
            try await waitUntil { runner.scanPaths.count == 2 }
            runner.resumeNextScan()
        }
        try await waitUntil { !appState.isScanning }
        XCTAssertEqual(runner.scanPaths, [[firstPath], [changedPath]])
    }

    func testIncompleteOrEmptyDownloadNeverReceivesCleanNotificationOrRecentScanCredit() async throws {
        var settings = AppSettings.default
        settings.showNotifications = true
        settings.notifyOnCleanFiles = true
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications,
            startsInteractiveBackgroundServices: false
        )
        let cases: [(Int, [String], ScanCompletionState)] = [
            (0, [], .success), (1, ["Skipped unreadable file"], .success),
            (1, [], .scanError), (1, [], .cancelled), (1, [], .infectedFound)
        ]
        for (index, value) in cases.enumerated() {
            let scan = Task {
                await appState.startScan(paths: [URL(fileURLWithPath: "/tmp/download-fixture")], options: .default, source: .download)
            }
            try await waitUntil { runner.scanPaths.count == index + 1 }
            runner.resumeNextScan(filesScanned: value.0, errors: value.1, completionState: value.2)
            _ = await scan.value
            XCTAssertTrue(notifications.cleanFileURLs.isEmpty)
            XCTAssertFalse(appState.protectionScore.components.first { $0.title == "Recent Scan" }?.isComplete ?? true)
        }
    }

    func testScheduledOutcomeDoesNotCallIncompleteReportSuccessful() {
        let now = Date()
        let threat = ScanResult(path: "/tmp/fixture", threatName: "Test.Fixture")
        for report in [
            ScanReport(startTime: now, endTime: now, filesScanned: 0, infectedFiles: [], errors: [], scanPaths: []),
            ScanReport(startTime: now, endTime: now, filesScanned: 1, infectedFiles: [], errors: ["Unreadable file"], scanPaths: []),
            ScanReport(startTime: now, endTime: now, filesScanned: 1, infectedFiles: [threat], errors: ["Quarantine failed"], scanPaths: [])
        ] {
            XCTAssertTrue(ScanOutcome.completed(report).scheduledResultMessage.hasPrefix("incomplete:"))
        }
        let cancelled = ScanReport(startTime: now, endTime: now, filesScanned: 1, infectedFiles: [], errors: [], scanPaths: [], completionState: .cancelled)
        XCTAssertEqual(ScanOutcome.completed(cancelled).scheduledResultMessage, "cancelled")
        let completed = ScanReport(startTime: now, endTime: now, filesScanned: 1, infectedFiles: [], errors: [], scanPaths: [])
        XCTAssertEqual(ScanOutcome.completed(completed).scheduledResultMessage, "success")
    }

    func testIncompleteReportsAreNotClean() {
        for (files, errors, completion) in [(0, [String](), ScanCompletionState.success), (1, ["Unreadable file"], .success), (1, [], .scanError), (1, [], .cancelled), (1, [], .infectedFound)] {
            let report = ScanReport(startTime: Date(), endTime: Date(), filesScanned: files, infectedFiles: [], errors: errors, scanPaths: [], completionState: completion)
            XCTAssertFalse(report.isClean)
        }
    }

    func testBatchedDownloadsDoNotAttributeCleanResultToAnUnverifiedFirstFile() async throws {
        var settings = AppSettings.default
        settings.showNotifications = true
        settings.notifyOnCleanFiles = true
        let runner = AppStateControlledRunner()
        let notifications = AppStateMockNotificationManager()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: notifications,
            startsInteractiveBackgroundServices: false
        )
        let scan = Task {
            await appState.startScan(paths: [URL(fileURLWithPath: "/tmp/excluded-download"), URL(fileURLWithPath: "/tmp/scanned-download")], options: .default, source: .download)
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan(filesScanned: 1)
        _ = await scan.value
        XCTAssertTrue(notifications.cleanFileURLs.isEmpty)
    }

    func testQuarantineResultRecordsSuccessfulActionAndPreservesIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.txt")
        try Data("Harmless test fixture".utf8).write(to: fixture)
        var settings = AppSettings.default
        settings.quarantineDirectory = directory.appendingPathComponent("quarantine").path
        let runner = AppStateControlledRunner()
        let detected = ScanResult(path: fixture.path, threatName: "Test.Fixture")
        runner.nextScanReportInfectedFiles = [detected]
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: AppStateMockNotificationManager(),
            startsInteractiveBackgroundServices: false
        )
        let scan = Task { await appState.startScan(paths: [fixture], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        let outcome = await scan.value

        XCTAssertEqual(appState.lastScanResult?.infectedFiles.first?.actionTaken, .quarantined)
        XCTAssertEqual(outcome.report?.infectedFiles.first?.actionTaken, .quarantined)
        XCTAssertEqual(appState.lastScanResult?.infectedFiles.first?.id, detected.id)
        XCTAssertEqual(appState.lastScanResult?.infectedFiles.first?.timestamp, detected.timestamp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testQuarantineFailureRemainsReportedAndIsIncludedInResultErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.txt")
        var settings = AppSettings.default
        settings.quarantineDirectory = directory.appendingPathComponent("quarantine").path
        let runner = AppStateControlledRunner()
        runner.nextScanReportInfectedFiles = [ScanResult(path: missing.path, threatName: "Test.Fixture")]
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: AppStateMockNotificationManager(),
            startsInteractiveBackgroundServices: false
        )
        let scan = Task { await appState.startScan(paths: [missing], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        let outcome = await scan.value

        XCTAssertEqual(appState.lastScanResult?.infectedFiles.first?.actionTaken, .reported)
        XCTAssertEqual(appState.lastScanResult?.errors.count, 1)
        XCTAssertTrue(appState.lastScanResult?.errors.first?.contains("could not be quarantined") == true)
        XCTAssertEqual(outcome.report?.errors, appState.lastScanResult?.errors)
    }

    func testMonitoringScoreDoesNotClaimProtectionWhenWatcherDidNotStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.default
        settings.monitoringEnabled = true
        settings.monitoredDirectories = [directory.path]
        let watcher = MockFileWatcher()
        watcher.startsSuccessfully = false
        let appState = AppState(configManager: AppStateMockConfigManager(settings: settings), fileWatcher: watcher)
        appState.refreshProtectionScore()
        XCTAssertFalse(appState.protectionScore.components.first { $0.title == "Folder Monitoring" }?.isComplete ?? true)

        watcher.startsSuccessfully = true
        appState.saveSettings()
        XCTAssertTrue(appState.protectionScore.components.first { $0.title == "Folder Monitoring" }?.isComplete ?? false)
    }

    func testMonitoredBatchDetectedDuringManualScanRunsAfterwards() async throws {
        var settings = AppSettings.default
        settings.monitoringEnabled = true
        settings.autoScanDownloads = false
        let watcher = MockFileWatcher()
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: watcher,
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: AppStateMockNotificationManager()
        )
        let manual = URL(fileURLWithPath: "/tmp/manual-fixture")
        let changed = URL(fileURLWithPath: "/tmp/changed-fixture")
        let scan = Task { await appState.startScan(paths: [manual], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        watcher.detectBatch([changed, changed])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner.scanPaths, [[manual]])
        runner.resumeNextScan()
        _ = await scan.value
        try await waitUntil { runner.scanPaths.count == 2 }
        XCTAssertEqual(runner.scanPaths[1], [changed])
        runner.resumeNextScan()
        try await waitUntil { !appState.isScanning }
    }

    func testThreatListOrdersCriticalThreatsBeforeLowerSeverities() {
        let files = ThreatSeverity.allCases.map {
            ScanResult(path: "/tmp/fixture", threatName: $0.rawValue, severity: $0)
        }
        XCTAssertEqual(InfectedFilesList(files: files).sortedFiles.map(\.severity), [.critical, .high, .medium, .low])
    }

    func testUnreadableQuarantineSurfacesFailureAndAllowsRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.default
        settings.quarantineDirectory = directory.path
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: settings),
            fileWatcher: MockFileWatcher(),
            notificationManager: AppStateMockNotificationManager(),
            startsInteractiveBackgroundServices: false
        )
        XCTAssertNil(appState.quarantineLoadError)
        try Data("invalid metadata".utf8).write(to: directory.appendingPathComponent("metadata.json"))
        appState.loadQuarantinedFiles()
        XCTAssertNotNil(appState.quarantineLoadError)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("metadata.json"))
        appState.loadQuarantinedFiles()
        XCTAssertNil(appState.quarantineLoadError)
    }

    func testProgressFromCompletedScanCannotOverwriteCurrentScan() async throws {
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            notificationManager: AppStateMockNotificationManager(),
            startsInteractiveBackgroundServices: false
        )
        let first = Task { await appState.startScan(paths: [URL(fileURLWithPath: "/tmp/first")], options: .default) }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        _ = await first.value
        let second = Task { await appState.startScan(paths: [URL(fileURLWithPath: "/tmp/second")], options: .default) }
        try await waitUntil { runner.scanPaths.count == 2 }
        runner.progressHandlers[0](ScanProgress(status: .scanning, currentFile: "stale", filesScanned: 99, infectedCount: 0, startTime: Date()))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(appState.currentScanProgress?.filesScanned, 0)
        runner.resumeNextScan()
        _ = await second.value
        runner.progressHandlers[1](ScanProgress(status: .scanning, currentFile: "stale", filesScanned: 99, infectedCount: 0, startTime: Date()))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(appState.currentScanProgress)
    }

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

    func testCanonicalLegacyLoginRegistrationMigratesToEmbeddedHelperTransactionally() throws {
        let helper = AppStateMockLoginItemService(status: .notRegistered)
        helper.statusAfterRegister = .enabled
        let legacy = AppStateMockLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        try manager.migrateLegacyRegistrationIfNeeded()

        XCTAssertEqual(helper.registerCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .enabled)
    }

    func testNoncanonicalBundleNeverMigratesLegacyLoginRegistration() throws {
        let helper = AppStateMockLoginItemService(status: .notRegistered)
        let legacy = AppStateMockLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { false }
        )

        try manager.migrateLegacyRegistrationIfNeeded()

        XCTAssertEqual(helper.registerCalls, 0)
        XCTAssertEqual(legacy.unregisterCalls, 0)
        XCTAssertEqual(manager.status, .enabled)
    }

    func testLegacyMigrationKeepsLegacyRegistrationWhileHelperAwaitsApproval() throws {
        let helper = AppStateMockLoginItemService(status: .notRegistered)
        helper.statusAfterRegister = .requiresApproval
        let legacy = AppStateMockLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        try manager.migrateLegacyRegistrationIfNeeded()

        XCTAssertEqual(helper.registerCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 0)
        XCTAssertEqual(manager.status, .requiresApproval)
    }

    func testLegacyMigrationRollsBackHelperWhenLegacyRemovalFails() {
        let helper = AppStateMockLoginItemService(status: .notRegistered)
        helper.statusAfterRegister = .enabled
        let legacy = AppStateMockLoginItemService(status: .enabled)
        legacy.unregisterError = AppStateTestError.loginItemFailure
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        XCTAssertThrowsError(try manager.migrateLegacyRegistrationIfNeeded())
        XCTAssertEqual(helper.registerCalls, 1)
        XCTAssertEqual(helper.unregisterCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .enabled)
    }

    func testLegacyRegistrationKeepsCombinedStatusEnabledWhenHelperMigrationFails() {
        let helper = AppStateMockLoginItemService(status: .notRegistered)
        helper.registerError = AppStateTestError.loginItemFailure
        let legacy = AppStateMockLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        XCTAssertThrowsError(try manager.migrateLegacyRegistrationIfNeeded())
        XCTAssertEqual(manager.status, .enabled)
    }

    func testDisablingMigrationPendingApprovalUnregistersBothLoginItemServices() throws {
        let helper = AppStateMockLoginItemService(status: .requiresApproval)
        let legacy = AppStateMockLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        try manager.setEnabled(false)

        XCTAssertEqual(helper.unregisterCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .disabled)
    }

    func testDisablingLegacyOnlyMigrationStateUnregistersLegacyService() throws {
        let helper = AppStateMockLoginItemService(status: .notRegistered)
        let legacy = AppStateMockLoginItemService(status: .requiresApproval)
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        try manager.setEnabled(false)

        XCTAssertEqual(helper.unregisterCalls, 0)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .disabled)
    }

    func testDisablingBothServicesRollsHelperBackWhenLegacyUnregistrationFails() {
        let helper = AppStateMockLoginItemService(status: .enabled)
        let legacy = AppStateMockLoginItemService(status: .enabled)
        legacy.unregisterError = AppStateTestError.loginItemFailure
        let manager = LaunchAtLoginManager(
            service: helper,
            legacyService: legacy,
            shouldMigrateLegacyRegistration: { true }
        )

        XCTAssertThrowsError(try manager.setEnabled(false))
        XCTAssertEqual(helper.unregisterCalls, 1)
        XCTAssertEqual(helper.registerCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .enabled)
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

    func testLaunchAtLoginStartupAttemptsHelperMigrationBeforePersistingStatus() {
        let manager = AppStateMigrationTrackingLoginItemManager(status: .enabled)
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: manager,
            startsInteractiveBackgroundServices: false
        )

        XCTAssertEqual(manager.migrationCalls, 1)
        XCTAssertEqual(appState.launchAtLoginStatus, .enabled)
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
            .appendingPathComponent("SafeMac AV", isDirectory: true)
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

    func testDashboardRecentScanReviewNavigatesWithoutStartingScan() async throws {
        let mockConfig = AppStateMockConfigManager(settings: .default)
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: mockConfig,
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner)
        )
        let component = ScoreComponent(
            title: "Recent Scan",
            isComplete: false,
            points: 25,
            action: .reviewScan
        )

        DashboardScoreActionHandler.handle(component, appState: appState)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(appState.selectedTab, .scan)
        XCTAssertTrue(runner.scanPaths.isEmpty)

        if !runner.scanPaths.isEmpty {
            runner.resumeNextScan()
            try await waitUntil { !appState.isScanning }
        }
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

    func testOverlappingFinderRequestsAreAdmittedOnceWithoutOverlapping() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let first = try store.enqueue(
            paths: ["/tmp/finder-first"],
            source: ExternalScanRequestStore.finderSource
        )
        let second = try store.enqueue(
            paths: ["/tmp/finder-second"],
            source: ExternalScanRequestStore.finderSource
        )
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            externalScanRequestStore: store,
            startsInteractiveBackgroundServices: false
        )

        let firstWake = Task { @MainActor in
            await appState.drainExternalScanRequest(id: first.id)
        }
        try await waitUntil { runner.scanPaths.count == 1 }

        let secondWake = Task { @MainActor in
            await appState.drainExternalScanRequest(id: second.id)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(runner.scanPaths, [[URL(fileURLWithPath: "/tmp/finder-first")]])

        runner.resumeNextScan()
        try await waitUntil { runner.scanPaths.count == 2 }
        runner.resumeNextScan()
        _ = await (firstWake.value, secondWake.value)

        XCTAssertEqual(
            runner.scanPaths,
            [
                [URL(fileURLWithPath: "/tmp/finder-first")],
                [URL(fileURLWithPath: "/tmp/finder-second")]
            ]
        )
        XCTAssertTrue(try store.loadRequests().isEmpty)
        XCTAssertTrue(try store.claimRequests().isEmpty)
    }

    func testInitialLaunchDrainConsumesFinderRequestQueuedBeforeAppStateExists() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let request = try store.enqueue(
            paths: ["/tmp/finder-cold-start"],
            source: ExternalScanRequestStore.finderSource
        )
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            externalScanRequestStore: store,
            startsInteractiveBackgroundServices: false
        )

        let initialLaunch = Task { @MainActor in
            await appState.drainExternalScanRequests()
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        runner.resumeNextScan()
        let drainedRequestCount = await initialLaunch.value

        XCTAssertEqual(drainedRequestCount, 1)
        XCTAssertEqual(runner.scanPaths, [[URL(fileURLWithPath: "/tmp/finder-cold-start")]])
        XCTAssertTrue(try store.claimRequests().isEmpty)
        XCTAssertTrue(try store.loadRequest(id: request.id).isEmpty)
    }

    func testFinderRequestIsNotScannedWhenAcknowledgmentFails() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = ExternalScanRequestStore(baseURL: tempDirectory)
        let request = try store.enqueue(
            paths: ["/tmp/finder-pending"],
            source: ExternalScanRequestStore.finderSource
        )
        let queueURL = tempDirectory.appendingPathComponent("external-scan-requests", isDirectory: true)
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            externalScanRequestStore: store,
            startsInteractiveBackgroundServices: false
        )
        let manualPath = URL(fileURLWithPath: "/tmp/manual")

        let manualScan = Task {
            await appState.startScan(paths: [manualPath], options: .default, source: .manual)
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        let finderWake = Task { @MainActor in
            await appState.drainExternalScanRequest(id: request.id)
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: queueURL.path)
        runner.resumeNextScan()
        for _ in 0..<100 {
            if runner.scanPaths.count > 1 {
                runner.resumeNextScan()
                break
            }
            await Task.yield()
        }

        _ = await (manualScan.value, finderWake.value)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: queueURL.path)

        XCTAssertEqual(runner.scanPaths, [[manualPath]])
        XCTAssertEqual(try store.claimRequest(id: request.id).map(\.id), [request.id])
    }

    func testFinderAcknowledgementRemovalFailureAbortsBeforeScan() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fileManager = AppStateFailingRemoveFileManager()
        let store = ExternalScanRequestStore(baseURL: tempDirectory, fileManager: fileManager)
        let request = try store.enqueue(
            paths: ["/tmp/finder-replay"],
            source: ExternalScanRequestStore.finderSource
        )
        fileManager.failsRemoveItem = true
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            externalScanRequestStore: store,
            startsInteractiveBackgroundServices: false
        )

        let admittedCount = await appState.drainExternalScanRequest(id: request.id)

        XCTAssertEqual(admittedCount, 0)
        XCTAssertTrue(runner.scanPaths.isEmpty)
        XCTAssertEqual(appState.scanError, FinderScanRequestHandoff.genericFailureMessage)
        XCTAssertEqual(try store.claimRequest(id: request.id).map(\.id), [request.id])
    }

    func testFinderRequestClaimSurvivesAgingWhileWaitingForActiveScan() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var currentDate = Date()
        let store = ExternalScanRequestStore(baseURL: tempDirectory, now: { currentDate })
        let request = try store.enqueue(
            paths: ["/tmp/finder-claimed"],
            source: ExternalScanRequestStore.finderSource
        )
        let runner = AppStateControlledRunner()
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            scanCoordinator: ScanCoordinator(clamAVRunner: runner),
            externalScanRequestStore: store,
            startsInteractiveBackgroundServices: false
        )
        let manualPath = URL(fileURLWithPath: "/tmp/manual")
        let finderPath = URL(fileURLWithPath: "/tmp/finder-claimed")

        let manualScan = Task {
            await appState.startScan(paths: [manualPath], options: .default, source: .manual)
        }
        try await waitUntil { runner.scanPaths.count == 1 }
        let finderWake = Task { @MainActor in
            await appState.drainExternalScanRequest(id: request.id)
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        currentDate = currentDate.addingTimeInterval(10 * 60)
        _ = try store.enqueue(
            paths: ["/tmp/new-finder-request"],
            source: ExternalScanRequestStore.finderSource
        )
        runner.resumeNextScan()
        if (try? await waitUntil({ runner.scanPaths.count > 1 })) != nil {
            runner.resumeNextScan()
        }

        _ = await (manualScan.value, finderWake.value)

        XCTAssertEqual(runner.scanPaths, [[manualPath], [finderPath]])
    }

    func testFinderHandoffFailureIgnoresUntrustedNotificationMessage() {
        let appState = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            startsInteractiveBackgroundServices: false
        )
        let untrustedMessage = "/Users/alice/private.txt: raw filesystem failure"

        appState.handleFinderHandoffFailure(
            Notification(
                name: ExternalScanRequestStore.scanRequestFailedNotificationName,
                userInfo: ["message": untrustedMessage]
            )
        )

        XCTAssertEqual(appState.selectedTab, .scan)
        XCTAssertEqual(appState.scanError, FinderScanRequestHandoff.genericFailureMessage)
        XCTAssertFalse(try XCTUnwrap(appState.scanError).contains("alice"))
        XCTAssertFalse(try XCTUnwrap(appState.scanError).contains("raw filesystem failure"))
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

    func testBackgroundHelperNotificationPermissionRequiresOnlyExplicitTap() async {
        let requester = AppStateMockBackgroundHelperNotificationRequester()
        let disabled = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: AppStateMockLoginItemService(status: .notRegistered)),
            backgroundHelperNotificationAuthorizationRequester: requester,
            startsInteractiveBackgroundServices: false
        )

        await disabled.requestBackgroundHelperNotificationPermission()
        XCTAssertEqual(requester.requests, 1)
        XCTAssertNil(disabled.backgroundHelperNotificationPermissionError)

        let enabledRequester = AppStateMockBackgroundHelperNotificationRequester()
        let enabled = AppState(
            configManager: AppStateMockConfigManager(settings: .default),
            fileWatcher: MockFileWatcher(),
            launchAtLoginManager: LaunchAtLoginManager(service: AppStateMockLoginItemService(status: .enabled)),
            backgroundHelperNotificationAuthorizationRequester: enabledRequester,
            startsInteractiveBackgroundServices: false
        )
        XCTAssertEqual(enabledRequester.requests, 0)

        await enabled.requestBackgroundHelperNotificationPermission()
        XCTAssertEqual(enabledRequester.requests, 1)
        XCTAssertNil(enabled.backgroundHelperNotificationPermissionError)
    }

    func testBackgroundHelperPermissionRequestStartsNewOneShotInstanceWhenLoginHelperAlreadyRuns() async {
        let mainBundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var receivedArguments: [String] = []
        var createsNewInstance = false
        let requester = SystemBackgroundHelperNotificationAuthorizationRequester(
            mainBundleURL: mainBundle,
            isEmbeddedHelper: { _, _ in true },
            openApplication: { _, configuration, completion in
                receivedArguments = configuration.arguments
                createsNewInstance = configuration.createsNewApplicationInstance
                completion(nil)
            }
        )

        let didLaunch = await requester.requestAuthorization()
        XCTAssertTrue(didLaunch)
        XCTAssertEqual(receivedArguments, ["--request-notification-authorization"])
        XCTAssertTrue(createsNewInstance)
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
        settings.monitoredDirectories = [FileManager.default.temporaryDirectory.path]
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

private final class AppStateFailingRemoveFileManager: FileManager {
    var failsRemoveItem = false

    override func removeItem(at URL: URL) throws {
        if failsRemoveItem {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
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

private final class AppStateMigrationTrackingLoginItemManager: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus
    private(set) var migrationCalls = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) throws {
        status = enabled ? .enabled : .disabled
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        migrationCalls += 1
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

    func update(using settings: AppSettings) async throws -> UpdateResult {
        try await update()
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
    var startsSuccessfully = true
    var onNewFileDetected: ((URL) -> Void)?

    func startWatching(directories: [URL], handler: @escaping ([URL]) -> Void) {
        startCalls += 1
        isWatching = startsSuccessfully
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

    func detectBatch(_ urls: [URL]) {
        batchHandler?(urls)
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
    private let lock = NSLock()
    private var storedScanPaths: [[URL]] = []
    private var storedProgressHandlers: [(ScanProgress) -> Void] = []
    private var continuations: [(CheckedContinuation<ScanReport, Error>, [URL])] = []
    var nextScanReportInfectedFiles: [ScanResult] = []
    var interruptedReport: ScanReport?

    var scanPaths: [[URL]] { lock.withLock { storedScanPaths } }
    var progressHandlers: [(ScanProgress) -> Void] { lock.withLock { storedProgressHandlers } }
    var currentProcessPID: Int32?
    var scanIsPaused = false

    func scan(paths: [URL], options: ScanOptions, progressHandler: @escaping (ScanProgress) -> Void) async throws -> ScanReport {
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                // Publish readiness only after the continuation can be resumed.
                continuations.append((continuation, paths))
                storedProgressHandlers.append(progressHandler)
                storedScanPaths.append(paths)
            }
        }
    }

    func resumeNextScan(filesScanned: Int = 1, errors: [String] = [], completionState: ScanCompletionState = .success) {
        let pending = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        guard let (continuation, paths) = pending else { return }
        let infectedFiles = nextScanReportInfectedFiles
        nextScanReportInfectedFiles = []
        continuation.resume(returning: ScanReport(
            startTime: Date(),
            endTime: Date(),
            filesScanned: filesScanned,
            infectedFiles: infectedFiles,
            errors: errors,
            scanPaths: paths,
            exitCode: 0,
            completionState: completionState
        ))
    }

    func failNextScan(_ error: Error) {
        let pending = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        pending?.0.resume(throwing: error)
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
    var blockCompletionNotification = false
    private var completionContinuation: CheckedContinuation<Void, Never>?
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
        if blockCompletionNotification {
            blockCompletionNotification = false
            await withCheckedContinuation { completionContinuation = $0 }
        }
    }

    func resumeCompletionNotification() {
        completionContinuation?.resume()
        completionContinuation = nil
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

@MainActor
private final class AppStateMockBackgroundHelperNotificationRequester: BackgroundHelperNotificationAuthorizationRequesting {
    private(set) var requests = 0
    var result = true

    func requestAuthorization() async -> Bool {
        requests += 1
        return result
    }
}
