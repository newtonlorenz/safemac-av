import XCTest
@testable import ClamAV_GUI

final class ConfigManagerTests: XCTestCase {

    var configManager: ConfigManager!
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        configManager = ConfigManager(appSupportURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Settings Tests

    func testLoadDefaultSettings() {
        let settings = configManager.loadSettings()

        XCTAssertFalse(settings.clamScanPath.isEmpty)
        XCTAssertFalse(settings.freshclamPath.isEmpty)
        XCTAssertFalse(settings.quarantineDirectory.isEmpty)
        XCTAssertFalse(settings.defaultExclusions.isEmpty)
    }

    func testDefaultExclusionsContainCommonPaths() {
        let settings = configManager.loadSettings()

        XCTAssertTrue(settings.defaultExclusions.contains("node_modules"))
        XCTAssertTrue(settings.defaultExclusions.contains(".git"))
        XCTAssertTrue(settings.defaultExclusions.contains("DerivedData"))
    }

    func testSaveAndLoadSettings() throws {
        var settings = AppSettings.default
        settings.customExclusions = ["test_exclusion"]
        settings.batchScanIntervalMinutes = 10

        try configManager.saveSettings(settings)
        let loadedSettings = configManager.loadSettings()

        XCTAssertEqual(loadedSettings.customExclusions, ["test_exclusion"])
        XCTAssertEqual(loadedSettings.batchScanIntervalMinutes, 10)
    }

    func testLoadCorruptedSettingsReturnsDefaultsWithoutOverwritingFile() throws {
        let appDirectory = tempDirectory.appendingPathComponent("ClamAV-GUI", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: false)
        let settingsURL = appDirectory.appendingPathComponent("settings.json")
        let corruptedData = Data("{not valid settings".utf8)
        try corruptedData.write(to: settingsURL)

        let loadedSettings = configManager.loadSettings()

        XCTAssertEqual(loadedSettings, .default)
        XCTAssertEqual(try Data(contentsOf: settingsURL), corruptedData)
    }

    func testSaveSettingsThrowsWhenDestinationCannotBeWritten() throws {
        let appDirectory = tempDirectory.appendingPathComponent("ClamAV-GUI", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: false)
        let settingsURL = appDirectory.appendingPathComponent("settings.json", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try configManager.saveSettings(.default)) { error in
            guard case ConfigManagerError.settingsSaveFailed(let path, let reason) = error else {
                return XCTFail("Expected a settingsSaveFailed error, got \(error)")
            }
            XCTAssertEqual(path, settingsURL.path)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: - Path Detection Tests

    func testDetectClamAVPaths() {
        let paths = configManager.detectClamAVPaths()

        // These may or may not be installed, so we just check the function runs
        // and returns sensible values (nil or valid paths)
        if let clamscan = paths.clamscan {
            XCTAssertTrue(clamscan.contains("clamscan"))
        }
        if let freshclam = paths.freshclam {
            XCTAssertTrue(freshclam.contains("freshclam"))
        }
    }

    // MARK: - Installation Validation Tests

    func testValidateInstallationReturnsStatus() {
        let status = configManager.validateClamAVInstallation()

        // The status should be one of the valid cases
        switch status {
        case .notInstalled, .partialInstall, .missingSignatures, .outdatedSignatures, .clamdUnavailable, .ready:
            // All valid cases
            break
        }
    }

    func testInstalledStatusIsIndependentFromSignatureFreshness() {
        XCTAssertTrue(ClamAVInstallationStatus.missingSignatures.isInstalled)
        XCTAssertTrue(ClamAVInstallationStatus.outdatedSignatures(daysSinceUpdate: 30).isInstalled)
        XCTAssertTrue(ClamAVInstallationStatus.ready(clamscanPath: "/tmp/clamscan").isInstalled)
        XCTAssertFalse(ClamAVInstallationStatus.notInstalled.isInstalled)
        XCTAssertFalse(ClamAVInstallationStatus.partialInstall(missing: ["freshclam"]).isInstalled)
        XCTAssertFalse(ClamAVInstallationStatus.clamdUnavailable.isInstalled)
    }

    func testLegacySettingsDecodeKeepsNewDefaults() throws {
        let legacyJSON = """
        {
          "clamScanPath": "/tmp/clamscan",
          "freshclamPath": "/tmp/freshclam",
          "configDirectory": "/tmp/config",
          "signatureDirectory": "/tmp/signatures",
          "quarantineDirectory": "/tmp/quarantine",
          "defaultExclusions": ["node_modules"],
          "customExclusions": [],
          "autoUpdateSignatures": true,
          "monitoredDirectories": [],
          "monitoringEnabled": false,
          "batchScanIntervalMinutes": 5,
          "batchScanFileThreshold": 10,
          "showNotifications": true,
          "playSoundOnDetection": true,
          "showPerformanceStats": true,
          "pauseOnBattery": true,
          "lowImpactMode": false,
          "autoScanDownloads": true,
          "notifyOnCleanFiles": false,
          "scanWhenIdle": true,
          "idleTimeoutMinutes": 30,
          "launchAtLogin": false,
          "hideFromDock": false
        }
        """

        let data = Data(legacyJSON.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.scannerBackend, .clamscan)
        XCTAssertFalse(settings.clamdSettings.clamdScanPath.isEmpty)
    }

    func testValidateInstallationUsesConfiguredPaths() throws {
        let testRoot = tempDirectory.appendingPathComponent("clamav-configured")
        let signatureDir = testRoot.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: signatureDir, withIntermediateDirectories: true)

        let clamscan = testRoot.appendingPathComponent("clamscan")
        let freshclam = testRoot.appendingPathComponent("freshclam")

        try "#!/bin/sh\nexit 0\n".write(to: clamscan, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: freshclam, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clamscan.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: freshclam.path)

        let mainCvd = signatureDir.appendingPathComponent("main.cvd")
        try "ClamAV:main:123:meta".write(to: mainCvd, atomically: true, encoding: .ascii)

        var settings = AppSettings.default
        settings.clamScanPath = clamscan.path
        settings.freshclamPath = freshclam.path
        settings.signatureDirectory = signatureDir.path

        let status = configManager.validateClamAVInstallation(using: settings)

        if case .ready(let path) = status {
            XCTAssertEqual(path, clamscan.path)
        } else {
            XCTFail("Expected configured installation to be ready, got: \(status)")
        }
    }

    func testValidateInstallationDoesNotFallbackWhenConfiguredPathIsInvalid() {
        var settings = AppSettings.default
        settings.clamScanPath = "/path/that/does/not/exist/clamscan"
        settings.freshclamPath = "/path/that/does/not/exist/freshclam"

        let status = configManager.validateClamAVInstallation(using: settings)

        if case .ready = status {
            XCTFail("Expected invalid configured paths to fail validation, but got ready")
        }
    }

    func testValidateInstallationUsesSelectedClamdscanBackend() throws {
        let testRoot = tempDirectory.appendingPathComponent("clamav-clamd")
        let signatureDir = testRoot.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: signatureDir, withIntermediateDirectories: true)

        let freshclam = testRoot.appendingPathComponent("freshclam")
        let clamdscan = testRoot.appendingPathComponent("clamdscan")

        try "#!/bin/sh\nexit 0\n".write(to: freshclam, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: clamdscan, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: freshclam.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clamdscan.path)
        try "ClamAV:main:123:meta".write(
            to: signatureDir.appendingPathComponent("main.cvd"),
            atomically: true,
            encoding: .ascii
        )

        var settings = AppSettings.default
        settings.clamScanPath = "/path/that/does/not/exist/clamscan"
        settings.freshclamPath = freshclam.path
        settings.signatureDirectory = signatureDir.path
        settings.scannerBackend = .clamdscan
        settings.clamdSettings = ClamdSettings(
            clamdScanPath: clamdscan.path,
            socketPath: "/tmp/clamd.sock",
            isEnabled: true
        )

        let status = configManager.validateClamAVInstallation(using: settings)

        if case .ready(let path) = status {
            XCTAssertEqual(path, clamdscan.path)
        } else {
            XCTFail("Expected clamdscan backend to validate independently, got: \(status)")
        }
    }

    // MARK: - Default Exclusions Tests

    func testDefaultExclusionsAreReasonable() {
        let exclusions = DefaultExclusions.paths

        XCTAssertGreaterThan(exclusions.count, 5, "Should have reasonable number of default exclusions")
        XCTAssertTrue(exclusions.contains("node_modules"), "Should exclude node_modules")
        XCTAssertTrue(exclusions.contains(".git"), "Should exclude .git")
        XCTAssertTrue(exclusions.contains("__pycache__"), "Should exclude Python cache")
    }

    // MARK: - Settings Merge Tests

    func testAllExclusionsCombinesDefaultAndCustom() {
        var settings = AppSettings.default
        settings.customExclusions = ["custom1", "custom2"]

        let allExclusions = settings.allExclusions

        XCTAssertTrue(allExclusions.contains("node_modules"))
        XCTAssertTrue(allExclusions.contains("custom1"))
        XCTAssertTrue(allExclusions.contains("custom2"))
    }

    // MARK: - Platform Detection Tests

    func testMachineHardwareNameReturnsValue() {
        let hardware = ProcessInfo.processInfo.machineHardwareName

        XCTAssertFalse(hardware.isEmpty)
        // Should be either arm64 or x86_64 on macOS
        XCTAssertTrue(hardware.contains("arm64") || hardware.contains("x86_64") || hardware.contains("i386"),
                      "Should return valid architecture")
    }
}
