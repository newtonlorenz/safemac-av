import AppKit
import Security
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
        var completion: (@MainActor @Sendable () -> Void)?
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
        XCTAssertEqual(BackgroundHelperLaunchModeParser.parse(arguments: ["helper", "--request-notification-authorization"]), .requestNotificationAuthorization)
        XCTAssertEqual(BackgroundHelperLaunchModeParser.parse(arguments: ["helper", "--scheduled-scan"]), .invalid)
        XCTAssertEqual(
            BackgroundHelperBundle.bundleURL(in: URL(fileURLWithPath: "/Applications/SafeMac AV.app")),
            URL(fileURLWithPath: "/Applications/SafeMac AV.app/Contents/Library/LoginItems/SafeMacAVBackground.app", isDirectory: true)
        )
        for mode in [BackgroundHelperLaunchMode.backgroundSession, .scheduledSignatureUpdate, .requestNotificationAuthorization, .invalid] {
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
        let helperBundle = helperExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": BackgroundHelperBundle.bundleIdentifier],
            format: .xml,
            options: 0
        ).write(to: helperBundle.appendingPathComponent("Info.plist"))
        XCTAssertFalse(BackgroundHelperBundle.isEmbeddedHelper(at: helperExecutable, in: root))

        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.impostor"],
            format: .xml,
            options: 0
        ).write(to: helperBundle.appendingPathComponent("Info.plist"))
        XCTAssertFalse(BackgroundHelperBundle.isEmbeddedHelper(at: helperExecutable, in: root))

        let lookalikeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lookalikeRoot) }
        let lookalike = lookalikeRoot
            .appendingPathComponent("Contents/Library/LoginItems/SafeMacAVBackground.app/Contents/MacOS/SafeMacAVBackground")
        try FileManager.default.createDirectory(at: lookalike.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lookalike)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lookalike.path)
        XCTAssertFalse(BackgroundHelperBundle.isEmbeddedHelper(at: lookalike, in: root))
    }

    func testScheduledUpdaterRequiresEnabledSettingAndRunsOnlyConfiguredExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let settingsURL = root.appendingPathComponent("settings.json")
        let updater = BackgroundSignatureUpdater(settingsURL: settingsURL)

        let disabled = try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": false,
            "freshclamPath": "/usr/bin/true"
        ])
        try writeSecureSettings(disabled, to: settingsURL)
        updater.runIfAvailable()

        let enabled = try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ])
        try writeSecureSettings(enabled, to: settingsURL)
        updater.runIfAvailable()
    }

    func testScheduledUpdaterUsesSharedFreshclamInvocationAndBoundedExecution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let signatureDirectory = root.appendingPathComponent("signatures", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data().write(to: configDirectory.appendingPathComponent("freshclam.conf"))
        let settingsURL = root.appendingPathComponent("settings.json")
        try writeSecureSettings(JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true",
            "configDirectory": configDirectory.path,
            "signatureDirectory": signatureDirectory.path
        ]), to: settingsURL)
        var captured: (FreshclamInvocation, TimeInterval)?
        let updater = BackgroundSignatureUpdater(settingsURL: settingsURL) { invocation, timeout in
            captured = (invocation, timeout)
            return .upToDate
        }

        updater.runIfAvailable()

        XCTAssertEqual(captured?.0.arguments, [
            "--config-file=\(configDirectory.appendingPathComponent("freshclam.conf").path)",
            "--stdout",
            "--datadir=\(signatureDirectory.path)",
            "--verbose"
        ])
        XCTAssertEqual(captured?.1, 300)
    }

    func testScheduledUpdaterSupportsTheInjectableSettingsStoreContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let settingsURL = root.appendingPathComponent("settings.json")
        try writeSecureSettings(JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true",
            "configDirectory": root.path,
            "signatureDirectory": root.appendingPathComponent("signatures").path
        ]), to: settingsURL)
        var invoked = false
        let updater = BackgroundSignatureUpdater(
            settingsStore: BackgroundHelperSettingsStore(settingsURL: settingsURL),
            execute: { _, _ in
                invoked = true
                return .upToDate
            }
        )

        XCTAssertEqual(updater.runIfAvailable(), .upToDate)
        XCTAssertTrue(invoked)
    }

    func testDefaultHelperNotificationDeliverySuppressesWithoutPromptInDebug() async {
        await BackgroundHelperNotificationCoordinator()
            .deliverIfAuthorized(outcome: .upToDate, notificationsEnabled: true)
    }

    func testFreshclamInvocationRejectsGroupWritableExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("freshclam")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path)

        XCTAssertFalse(FreshclamInvocation.isTrustedExecutable(at: executable.path))
    }

    func testFreshclamInvocationRunsResolvedTrustedExecutableInsteadOfInputSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("freshclam")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let symlink = root.appendingPathComponent("freshclam-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)

        let invocation = try FreshclamInvocation.make(
            executablePath: symlink.path,
            configDirectory: root.path,
            signatureDirectory: root.appendingPathComponent("signatures").path
        )

        XCTAssertEqual(invocation.executablePath, executable.path)
    }

    func testHelperPathGuardRejectsIntermediateSymlinkComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Contents"),
            withDestinationURL: outside
        )
        let executable = root.appendingPathComponent(
            "Contents/Library/LoginItems/SafeMacAVBackground.app/Contents/MacOS/SafeMacAVBackground"
        )

        XCTAssertFalse(BackgroundHelperBundle.hasNoSymlinkComponents(
            from: root,
            through: executable
        ))
    }

    func testScheduledUpdaterDefaultProcessExecutionCompletesWithinBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try FreshclamInvocation.make(
            executablePath: "/usr/bin/true",
            configDirectory: root.path,
            signatureDirectory: root.appendingPathComponent("signatures").path
        )

        XCTAssertEqual(BackgroundSignatureUpdater.executeProcess(invocation, timeout: 1), .updated(main: nil, daily: nil, bytecode: nil))
    }

    func testScheduledUpdaterTerminatesProcessThatExceedsBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("slow-freshclam")
        try Data("#!/bin/sh\nsleep 2\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let invocation = try FreshclamInvocation.make(
            executablePath: executable.path,
            configDirectory: root.path,
            signatureDirectory: root.appendingPathComponent("signatures").path
        )

        XCTAssertEqual(
            BackgroundSignatureUpdater.executeProcess(invocation, timeout: 0, terminationGrace: 0.05),
            .failed(message: "Signature update timed out")
        )
    }

    func testSettingsReloadKeepsLastKnownGoodAfterAtomicCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let settingsURL = root.appendingPathComponent("settings.json")
        let store = BackgroundHelperSettingsStore(settingsURL: settingsURL)

        XCTAssertEqual(store.reload(), .safeDefaults)
        try writeSecureSettings(JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ]), to: settingsURL)
        XCTAssertEqual(store.reload().freshclamPath, "/usr/bin/true")

        try Data("not-json".utf8).write(to: settingsURL, options: .atomic)
        XCTAssertEqual(store.reload().freshclamPath, "/usr/bin/true")
        XCTAssertTrue(store.reload().autoUpdateSignatures)
    }

    func testFreshStoreRecoversPersistedLastKnownGoodAfterCorruptAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let settingsURL = root.appendingPathComponent("settings.json")

        try writeSecureSettings(JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ]), to: settingsURL)
        XCTAssertEqual(BackgroundHelperSettingsStore(settingsURL: settingsURL).reload().freshclamPath, "/usr/bin/true")

        try Data("not-json".utf8).write(to: settingsURL, options: .atomic)
        XCTAssertEqual(BackgroundHelperSettingsStore(settingsURL: settingsURL).reload(), BackgroundHelperSettings(
            autoUpdateSignatures: true,
            freshclamPath: "/usr/bin/true",
            configDirectory: nil,
            signatureDirectory: nil,
            showNotifications: false
        ))
    }

    func testSettingsStoreRejectsUnsafePrimaryFileAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let settingsURL = root.appendingPathComponent("settings.json")
        let valid = try JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ])
        try valid.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsURL.path)
        XCTAssertEqual(BackgroundHelperSettingsStore(settingsURL: settingsURL).reload(), .safeDefaults)

        try FileManager.default.removeItem(at: settingsURL)
        let target = root.appendingPathComponent("settings-target.json")
        try valid.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: target)
        XCTAssertEqual(BackgroundHelperSettingsStore(settingsURL: settingsURL).reload(), .safeDefaults)
    }

    func testSettingsStoreRejectsUnsafeContainingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        try writeSecureSettings(JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ]), to: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)

        XCTAssertEqual(BackgroundHelperSettingsStore(settingsURL: settingsURL).reload(), .safeDefaults)
    }

    func testRouteHandoffRemovesDurableRequestWhenOpeningMainFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundRouteRequestStore(baseURL: root)
        let handoff = BackgroundRouteHandoff(
            requestStore: store,
            validateMainApplication: { true },
            openMainApplication: { completion in completion(false) },
            postWakeHint: { _ in XCTFail("must not notify after failed open") }
        )

        handoff.send(.settings)

        XCTAssertNil(store.consume())
    }

    func testSettingsDirectoryWatcherObservesAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let settingsURL = root.appendingPathComponent("settings.json")
        let store = BackgroundHelperSettingsStore(settingsURL: settingsURL)
        let observed = expectation(description: "atomic replacement observed")
        observed.assertForOverFulfill = false
        store.startWatching { settings in
            if settings.freshclamPath == "/usr/bin/true" { observed.fulfill() }
        }

        try writeSecureSettings(JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": true,
            "freshclamPath": "/usr/bin/true"
        ]), to: settingsURL)

        wait(for: [observed], timeout: 2)
    }

    func testSettingsWatcherCreatesOwnerOnlyMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundHelperSettingsStore(settingsURL: root.appendingPathComponent("settings.json"))

        store.startWatching()

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testHelperNotificationsDeliverOnlyAuthorizedPrivacySafeOutcome() async {
        let delivery = BackgroundHelperNotificationMock(status: .authorized)
        let coordinator = BackgroundHelperNotificationCoordinator(delivery: delivery)

        await coordinator.deliverIfAuthorized(
            outcome: .failed(message: "ERROR: /private/secret-path"),
            notificationsEnabled: true
        )

        XCTAssertEqual(delivery.deliveries.count, 1)
        XCTAssertEqual(delivery.deliveries[0].0, "Signature update failed")
        XCTAssertFalse(delivery.deliveries[0].1.contains("secret-path"))
    }

    func testExplicitHelperNotificationAuthorizationCanOnlyBeRequestedByUserAction() async {
        let delivery = BackgroundHelperNotificationMock(status: .notDetermined)
        let coordinator = BackgroundHelperNotificationCoordinator(delivery: delivery)

        await coordinator.requestAuthorizationFromUserAction()

        XCTAssertEqual(delivery.requestCalls, 1)
        XCTAssertEqual(delivery.statusCalls, 0)
        XCTAssertTrue(delivery.deliveries.isEmpty)
    }

    func testHelperNotificationsSuppressDeniedAndNotDeterminedWithoutPrompt() async {
        for status in [BackgroundHelperNotificationAuthorization.denied, .notDetermined] {
            let delivery = BackgroundHelperNotificationMock(status: status)
            let coordinator = BackgroundHelperNotificationCoordinator(delivery: delivery)
            await coordinator.deliverIfAuthorized(outcome: .upToDate, notificationsEnabled: true)
            XCTAssertTrue(delivery.deliveries.isEmpty)
            XCTAssertEqual(delivery.statusCalls, 1)
        }
    }

    func testExplicitHelperNotificationAuthorizationOnlyRunsFromItsDedicatedLaunchMode() {
        var authorizationRequests = 0
        var installedMenuBar = 0
        var scheduledUpdates = 0
        var terminations = 0
        let coordinator = BackgroundHelperCoordinator(
            installStatusItem: { installedMenuBar += 1 },
            acquireMonitoringLease: { true },
            runScheduledSignatureUpdate: { _ in scheduledUpdates += 1 },
            requestNotificationAuthorization: { completion in
                authorizationRequests += 1
                completion()
            },
            terminate: { terminations += 1 }
        )

        coordinator.start(arguments: ["SafeMacAVBackground"])
        coordinator.start(arguments: ["SafeMacAVBackground", "--scheduled-signature-update"])
        coordinator.start(arguments: ["SafeMacAVBackground", "--request-notification-authorization"])

        XCTAssertEqual(authorizationRequests, 1)
        XCTAssertEqual(installedMenuBar, 1)
        XCTAssertEqual(scheduledUpdates, 1)
        XCTAssertEqual(terminations, 1)
    }

    func testFreshclamOutputFailsClosedForEveryNonzeroExitCode() {
        let mixedOutputs = [
            "daily.cld database is up-to-date (version: 123)\nERROR: network failed",
            "daily.cld updated (version: 123)\nERROR: verification failed"
        ]

        for output in mixedOutputs {
            guard case .failed = FreshclamUpdateOutcome.parse(output: output, exitCode: 1) else {
                return XCTFail("A nonzero freshclam exit must fail closed")
            }
        }
    }

    func testTrustedCodeRequirementsAnchorAppleGenericAndConstrainIdentifierAndTeam() {
        XCTAssertEqual(
            BackgroundHelperBundle.staticCodeRequirement,
            "anchor apple generic and identifier \"com.newtonlorenz.ClamAV-GUI.Background\" and certificate leaf[subject.OU] = \"CQPH8YR62A\""
        )
        XCTAssertEqual(
            TrustedCodeRequirement.developerIDApplication(
                identifier: "com.newtonlorenz.ClamAV-GUI",
                teamIdentifier: "CQPH8YR62A"
            ),
            "anchor apple generic and identifier \"com.newtonlorenz.ClamAV-GUI\" and certificate leaf[subject.OU] = \"CQPH8YR62A\""
        )

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClamAV-BackgroundHelper/SafeMacAVBackgroundApp.swift")
        let source = try? String(contentsOf: sourceURL)
        XCTAssertTrue(source?.contains("SecRequirementCreateWithString(staticCodeRequirement") == true)
    }

    func testGeneratedHelperAndMainCodeRequirementsParseWithSecurityFramework() {
        for requirementText in [
            BackgroundHelperBundle.staticCodeRequirement,
            MainAppHandoff.staticCodeRequirement
        ] {
            var requirement: SecRequirement?
            XCTAssertEqual(
                SecRequirementCreateWithString(requirementText as CFString, [], &requirement),
                errSecSuccess,
                "Generated requirement must be accepted by Security.framework: \(requirementText)"
            )
            XCTAssertNotNil(requirement)
        }
    }

    func testCodeRequirementRejectsUnsafeDynamicAtomsBeforeSecurityParsing() {
        let requirementText = TrustedCodeRequirement.developerIDApplication(
            identifier: "com.example.\\\"helper",
            teamIdentifier: "TEAM\\\" or identifier \\\"unexpected"
        )
        var requirement: SecRequirement?

        XCTAssertEqual(
            SecRequirementCreateWithString(requirementText as CFString, [], &requirement),
            errSecSuccess
        )
        XCTAssertNotNil(requirement)
        XCTAssertFalse(requirementText.contains("or identifier"))
        XCTAssertTrue(requirementText.contains("\"__invalid_trusted_code_atom__\""))
    }

    func testCanonicalMainValidationIsReadOnlyBeforeAnyRouteDispatch() {
        _ = MainAppHandoff.canonicalMainApplicationIsTrusted()
    }

    func testHelperNotificationsUseSafeSuccessAndCurrentSummaries() async {
        for outcome in [
            FreshclamUpdateOutcome.updated(main: "1", daily: "2", bytecode: "3"),
            .upToDate
        ] {
            let delivery = BackgroundHelperNotificationMock(status: .authorized)
            await BackgroundHelperNotificationCoordinator(delivery: delivery)
                .deliverIfAuthorized(outcome: outcome, notificationsEnabled: true)
            XCTAssertEqual(delivery.deliveries.count, 1)
            XCTAssertFalse(delivery.deliveries[0].1.contains("1"))
        }
    }

    func testHelperNotificationsRespectForegroundPreference() async {
        let delivery = BackgroundHelperNotificationMock(status: .authorized)
        await BackgroundHelperNotificationCoordinator(delivery: delivery)
            .deliverIfAuthorized(outcome: .upToDate, notificationsEnabled: false)
        XCTAssertTrue(delivery.deliveries.isEmpty)
        XCTAssertEqual(delivery.statusCalls, 0)
    }

    func testAppAdapterExposesOnlyTheFixedMainActions() {
        let app = SafeMacAVBackgroundApp()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(app)
    }

    func testMenuOwnershipKeepsLifetimeLeaseAcrossBothLaunchOrders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var currentTime = Date()
        let coordinator = BackgroundMenuBarOwnershipCoordinator(
            makeLease: { BackgroundWorkLease(name: "background-monitoring", baseURL: root) },
            now: { currentTime },
            startupGrace: 5,
            startsRecoveryTimer: false
        )

        // Main first, helper disabled: the main owns the lease for as long as
        // its fallback menu is visible.
        coordinator.reconcile(helperEnabled: false)
        XCTAssertTrue(coordinator.mainShouldPresentMenuBar)
        XCTAssertFalse(BackgroundWorkLease(name: "background-monitoring", baseURL: root).acquire())

        // A later helper startup makes main release before it claims the lease.
        coordinator.prepareForHelperOwnership()
        let helperLease = BackgroundWorkLease(name: "background-monitoring", baseURL: root)
        XCTAssertTrue(helperLease.acquire())
        XCTAssertFalse(coordinator.mainShouldPresentMenuBar)
        helperLease.release()

        // Helper first: main waits through grace, then recovers its fallback
        // only after it can own the lease itself.
        coordinator.reconcile(helperEnabled: true)
        currentTime = currentTime.addingTimeInterval(6)
        coordinator.recoverIfHelperIsAbsent()
        XCTAssertTrue(coordinator.mainShouldPresentMenuBar)
    }

    private func writeSecureSettings(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private final class BackgroundHelperNotificationMock: BackgroundHelperNotificationDelivering {
    let status: BackgroundHelperNotificationAuthorization
    var statusCalls = 0
    var requestCalls = 0
    var deliveries: [(String, String)] = []

    init(status: BackgroundHelperNotificationAuthorization) {
        self.status = status
    }

    func authorizationStatus() async -> BackgroundHelperNotificationAuthorization {
        statusCalls += 1
        return status
    }

    func requestAuthorization() async { requestCalls += 1 }

    func deliver(title: String, body: String) async {
        deliveries.append((title, body))
    }
}
