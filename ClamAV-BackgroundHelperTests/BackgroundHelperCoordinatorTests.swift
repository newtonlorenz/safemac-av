import XCTest
@testable import SafeMacAVBackground

@MainActor
final class BackgroundHelperCoordinatorTests: XCTestCase {
    func testLoginSessionIsVisibleAndDoesNotRunScheduledUpdate() {
        var installedMenuBar = 0
        var acquiredLease = 0
        var scheduledUpdates = 0
        var terminations = 0
        let coordinator = BackgroundHelperCoordinator(
            installStatusItem: { installedMenuBar += 1 },
            acquireMonitoringLease: { acquiredLease += 1; return true },
            runScheduledSignatureUpdate: { completion in scheduledUpdates += 1; completion() },
            terminate: { terminations += 1 }
        )

        coordinator.start(arguments: ["SafeMacAVBackground"])

        XCTAssertEqual(coordinator.presentation, .visibleMenuBar)
        XCTAssertEqual(acquiredLease, 1)
        XCTAssertEqual(installedMenuBar, 1)
        XCTAssertEqual(scheduledUpdates, 0)
        XCTAssertEqual(terminations, 0)
    }

    func testLoginSessionExitsWithoutMenuWhenMonitoringLeaseIsAlreadyHeld() {
        var installedMenuBar = 0
        var terminations = 0
        let coordinator = BackgroundHelperCoordinator(
            installStatusItem: { installedMenuBar += 1 },
            acquireMonitoringLease: { false },
            runScheduledSignatureUpdate: { _ in XCTFail("scheduled update must not run") },
            terminate: { terminations += 1 }
        )

        coordinator.start(arguments: ["SafeMacAVBackground"])

        XCTAssertEqual(coordinator.presentation, .hidden)
        XCTAssertEqual(installedMenuBar, 0)
        XCTAssertEqual(terminations, 1)
    }

    func testScheduledSignatureUpdateStaysHiddenRunsOnceAndTerminates() {
        var installedMenuBar = 0
        var acquiredLease = 0
        var scheduledUpdates = 0
        var completion: (() -> Void)?
        var terminations = 0
        let coordinator = BackgroundHelperCoordinator(
            installStatusItem: { installedMenuBar += 1 },
            acquireMonitoringLease: { acquiredLease += 1; return true },
            runScheduledSignatureUpdate: { callback in scheduledUpdates += 1; completion = callback },
            terminate: { terminations += 1 }
        )

        coordinator.start(arguments: ["SafeMacAVBackground", "--scheduled-signature-update"])
        coordinator.start(arguments: ["SafeMacAVBackground", "--scheduled-signature-update"])
        completion?()
        completion?()

        XCTAssertEqual(coordinator.presentation, .hidden)
        XCTAssertEqual(installedMenuBar, 0)
        XCTAssertEqual(acquiredLease, 0)
        XCTAssertEqual(scheduledUpdates, 1)
        XCTAssertEqual(terminations, 1)
    }

    func testInvalidLaunchTerminatesWithoutPresentingAnything() {
        var installedMenuBar = 0
        var scheduledUpdates = 0
        var terminations = 0
        let coordinator = BackgroundHelperCoordinator(
            installStatusItem: { installedMenuBar += 1 },
            acquireMonitoringLease: { true },
            runScheduledSignatureUpdate: { _ in scheduledUpdates += 1 },
            terminate: { terminations += 1 }
        )

        coordinator.start(arguments: ["SafeMacAVBackground", "--finder-request"])

        XCTAssertEqual(coordinator.presentation, .hidden)
        XCTAssertEqual(installedMenuBar, 0)
        XCTAssertEqual(scheduledUpdates, 0)
        XCTAssertEqual(terminations, 1)
    }

    func testHelperTargetContainsNoSparkleOrFinderImport() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClamAV-BackgroundHelper/SafeMacAVBackgroundApp.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("import Sparkle"))
        XCTAssertFalse(source.contains("import FinderSync"))
    }

    func testAppAdapterCreatesStatusItemOnlyForVisibleBackgroundSession() {
        let app = SafeMacAVBackgroundApp()

        app.start(arguments: ["SafeMacAVBackground"])

        XCTAssertTrue(app.hasStatusItem)
    }

    func testSharedHelperSupportCoversFixedModesRoutesAndSecureLease() throws {
        XCTAssertEqual(BackgroundHelperLaunchModeParser.parse(arguments: ["helper"]), .backgroundSession)
        XCTAssertEqual(BackgroundHelperLaunchModeParser.parse(arguments: ["helper", "--scheduled-signature-update"]), .scheduledSignatureUpdate)
        XCTAssertEqual(BackgroundHelperLaunchModeParser.parse(arguments: ["helper", "--scheduled-scan"]), .invalid)
        for mode in [BackgroundHelperLaunchMode.backgroundSession, .scheduledSignatureUpdate, .invalid] {
            XCTAssertFalse(mode.presentsUserInterface)
            XCTAssertFalse(mode.startsSoftwareUpdateSubsystem)
            XCTAssertFalse(mode.consumesFinderRequests)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BackgroundWorkLease(name: "signature-update", baseURL: root)
        let second = BackgroundWorkLease(name: "signature-update", baseURL: root)
        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())
        first.release()
        XCTAssertTrue(second.acquire())
        second.release()

        let lockLink = root.appendingPathComponent("unsafe.lock")
        try FileManager.default.createSymbolicLink(at: lockLink, withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(BackgroundWorkLease(name: "unsafe", baseURL: root).acquire())

        let routeStore = BackgroundRouteRequestStore(baseURL: root)
        XCTAssertTrue(routeStore.enqueue(.settings))
        XCTAssertEqual(routeStore.consume(), .settings)
        XCTAssertNil(routeStore.consume())
        XCTAssertNil(BackgroundRoute.parse("--finder-request"))

        XCTAssertTrue(BackgroundMenuBarOwnership.mainShouldPresentMenuBar(helperIsEnabled: false))
        XCTAssertTrue(BackgroundMenuBarOwnership.mainShouldPresentMenuBar(helperIsEnabled: true))
        let ownershipLease = BackgroundWorkLease(name: "background-monitoring", baseURL: root)
        XCTAssertTrue(ownershipLease.acquire())
        XCTAssertFalse(BackgroundMenuBarOwnership.mainShouldPresentMenuBar(
            helperIsEnabled: true,
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: root) }
        ))
        ownershipLease.release()

        let helperExecutable = root
            .appendingPathComponent("Contents/Library/LoginItems/SafeMacAVBackground.app/Contents/MacOS", isDirectory: true)
            .appendingPathComponent("SafeMacAVBackground")
        try FileManager.default.createDirectory(at: helperExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helperExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperExecutable.path)
        XCTAssertTrue(BackgroundHelperBundle.isEmbeddedHelper(at: helperExecutable))
    }

    func testScheduledUpdaterRequiresEnabledSettingAndRunsOnlyConfiguredExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        let updater = BackgroundSignatureUpdater(settingsURL: settingsURL)

        let disabled = try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": false,
            "freshclamPath": "/usr/bin/true"
        ])
        try disabled.write(to: settingsURL)
        updater.runIfAvailable()

        let enabled = try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ])
        try enabled.write(to: settingsURL)
        updater.runIfAvailable()
    }

    func testSettingsReloadKeepsLastKnownGoodAfterAtomicCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        let store = BackgroundHelperSettingsStore(settingsURL: settingsURL)

        XCTAssertEqual(store.reload(), .safeDefaults)
        try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ]).write(to: settingsURL, options: .atomic)
        XCTAssertEqual(store.reload().freshclamPath, "/usr/bin/true")

        try Data("not-json".utf8).write(to: settingsURL, options: .atomic)
        XCTAssertEqual(store.reload().freshclamPath, "/usr/bin/true")
        XCTAssertTrue(store.reload().autoUpdateSignatures)
    }

    func testSettingsDirectoryWatcherObservesAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        let store = BackgroundHelperSettingsStore(settingsURL: settingsURL)
        let observed = expectation(description: "atomic replacement observed")
        observed.assertForOverFulfill = false
        store.startWatching { settings in
            if settings.freshclamPath == "/usr/bin/true" { observed.fulfill() }
        }

        try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ]).write(to: settingsURL, options: .atomic)

        wait(for: [observed], timeout: 2)
    }

    func testAppAdapterRoutesOnlyThroughFixedMainActions() {
        let app = SafeMacAVBackgroundApp()
        app.openMain()
        app.openSettings()
        app.checkForUpdates()
    }
}
