import Darwin
import XCTest
@testable import ClamAV_GUI

final class ClamAVRunnerTests: XCTestCase {

    @MainActor
    func testCancellingPausedProcessCompletesAndAllowsAnotherScan() async throws {
        let fixture = try makeRunner(script: "exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let started = expectation(description: "Scanner started")
        let completed = expectation(description: "Paused scanner cancelled")
        let task = Task {
            do {
                _ = try await fixture.runner.scan(paths: [], options: .default) { _ in started.fulfill() }
                XCTFail("Cancelled scan must not complete successfully")
            } catch ClamAVError.cancelled {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        let pid = try XCTUnwrap(fixture.runner.currentProcessPID)
        fixture.runner.pauseScan()
        try await Task.sleep(nanoseconds: 50_000_000)
        fixture.runner.cancelCurrentScan()

        await fulfillment(of: [completed], timeout: 2)
        // Preserve cleanup even when the regression fails on a stopped process.
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        await task.value
        XCTAssertNil(fixture.runner.currentProcessPID)
        XCTAssertFalse(fixture.runner.scanIsPaused)

        try Data("#!/bin/sh\nprintf '/tmp/clean: OK\\n'\n".utf8).write(to: fixture.executable)
        let report = try await fixture.runner.scan(paths: [], options: .default) { _ in }
        XCTAssertEqual(report.filesScanned, 1)
    }

    @MainActor
    func testCancellationRetainsDetectedFilesAndClearsPartialReportOnNextRun() async throws {
        let fixture = try makeRunner(script: "printf '/tmp/partial-fixture: Test.Signature FOUND\\n'; exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let detected = expectation(description: "Partial detection received")
        let task = Task {
            do {
                _ = try await fixture.runner.scan(paths: [], options: .default) { progress in
                    if progress.infectedCount == 1 { detected.fulfill() }
                }
                XCTFail("Cancelled scan must throw cancellation")
            } catch ClamAVError.cancelled {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [detected], timeout: 3)
        fixture.runner.cancelCurrentScan()
        await task.value
        let partial = try XCTUnwrap(fixture.runner.interruptedReport)
        XCTAssertEqual(partial.completionState, .cancelled)
        XCTAssertEqual(partial.infectedFiles.map(\.path), ["/tmp/partial-fixture"])
        XCTAssertEqual(partial.threatsFound, 1)
        XCTAssertFalse(partial.isClean)
        try Data("#!/bin/sh\nprintf '/tmp/clean: OK\\n'\n".utf8).write(to: fixture.executable)
        _ = try await fixture.runner.scan(paths: [], options: .default) { _ in }
        XCTAssertNil(fixture.runner.interruptedReport)
    }

    func testScannerFailureRetainsFinalUnterminatedDetection() async throws {
        let fixture = try makeRunner(script: "printf '/tmp/final-fixture: Test.Signature FOUND'; exit 2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.runner.scan(paths: [], options: .default) { _ in }
            XCTFail("Exit 2 must remain an error")
        } catch ClamAVError.scanFailed {
        }
        let partial = try XCTUnwrap(fixture.runner.interruptedReport)
        XCTAssertEqual(partial.completionState, .scanError)
        XCTAssertEqual(partial.infectedFiles.map(\.path), ["/tmp/final-fixture"])
        XCTAssertEqual(partial.exitCode, 2)
    }

    func testSignalTerminationIsAnErrorRatherThanAnInfection() async throws {
        let fixture = try makeRunner(script: "kill -HUP $$")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.runner.scan(paths: [], options: .default) { _ in }
            XCTFail("A scanner terminated by a signal must not report a completed scan")
        } catch ClamAVError.scanFailed(let code, let message) {
            XCTAssertEqual(code, SIGHUP)
            XCTAssertTrue(message.contains("signal"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testScanPreservesUTF8AcrossPipeReadsAndFinalOutput() async throws {
        let fixture = try makeRunner(script: """
        printf '/tmp/caf\\303'
        /bin/sleep 0.1
        printf '\\251.txt: Test-Signature FOUND\\n'
        printf '/tmp/final: Other-Signature FOUND'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let report = try await fixture.runner.scan(paths: [], options: .default) { _ in }

        XCTAssertEqual(report.infectedFiles.map(\.path), ["/tmp/café.txt", "/tmp/final"])
        XCTAssertEqual(report.filesScanned, 2)
        XCTAssertEqual(report.completionState, .infectedFound)
    }

    func testScanUsesConfiguredDatabaseAndCombinesExclusionsWithoutDuplicates() async throws {
        let fixture = try makeRunner(script: "printf '%s\\n' \"$@\" > \"$0.arguments\"")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let config = ConfigManager(appSupportURL: fixture.directory)
        var settings = config.loadSettings()
        settings.signatureDirectory = "/tmp/configured-signatures"
        settings.defaultExclusions = ["global-default", "shared"]
        settings.customExclusions = ["global-custom", "shared"]
        try config.saveSettings(settings)
        var options = ScanOptions.default
        options.databasePath = nil
        options.excludedPaths = ["scan-only", "shared", "scan-only"]

        _ = try await fixture.runner.scan(paths: [], options: options) { _ in }

        let arguments = try String(contentsOf: fixture.executable.appendingPathExtension("arguments"), encoding: .utf8)
            .components(separatedBy: "\n")
        XCTAssertTrue(arguments.contains("--database=/tmp/configured-signatures"))
        for exclusion in ["global-default", "global-custom", "shared", "scan-only"] {
            XCTAssertEqual(arguments.filter { $0 == "--exclude=\(exclusion)" }.count, 1)
            XCTAssertEqual(arguments.filter { $0 == "--exclude-dir=\(exclusion)" }.count, 1)
        }
    }

    func testScanDatabaseOverrideTakesPrecedenceOverConfiguredDirectory() async throws {
        let fixture = try makeRunner(script: "printf '%s\\n' \"$@\" > \"$0.arguments\"")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let config = ConfigManager(appSupportURL: fixture.directory)
        var settings = config.loadSettings()
        settings.signatureDirectory = "/tmp/configured-signatures"
        try config.saveSettings(settings)
        var options = ScanOptions.default
        options.databasePath = "/tmp/scan-signatures"

        _ = try await fixture.runner.scan(paths: [], options: options) { _ in }

        let arguments = try String(contentsOf: fixture.executable.appendingPathExtension("arguments"), encoding: .utf8)
            .components(separatedBy: "\n")
        XCTAssertEqual(arguments.filter { $0.hasPrefix("--database=") }, ["--database=/tmp/scan-signatures"])
    }

    func testInfectedOnlyScanUsesSummaryForTotalFilesScanned() async throws {
        let fixture = try makeRunner(script: """
        printf '/tmp/detected: Harmless-Test FOUND\nScanned files: 12\n'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var options = ScanOptions.default
        options.reportOnlyInfected = true

        let report = try await fixture.runner.scan(paths: [], options: options) { _ in }

        XCTAssertEqual(report.filesScanned, 12)
        XCTAssertEqual(report.infectedFiles.count, 1)
    }

    func testStdoutErrorPreservesDiagnosticAndDoesNotCountFilenameAsClean() async throws {
        let fixture = try makeRunner(script: "printf '/tmp/name: OK.txt: Access denied ERROR\\n'")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let report = try await fixture.runner.scan(paths: [], options: .default) { _ in }

        XCTAssertEqual(report.filesScanned, 0)
        XCTAssertEqual(report.errors, ["/tmp/name: OK.txt: Access denied ERROR"])
    }

    func testFailedScanIncludesErrorPrintedToStdout() async throws {
        let fixture = try makeRunner(script: "printf '/tmp/unreadable: Access denied ERROR\\n'; exit 2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.runner.scan(paths: [], options: .default) { _ in }
            XCTFail("Expected scan failure")
        } catch ClamAVError.scanFailed(_, let message) {
            XCTAssertEqual(message, "/tmp/unreadable: Access denied ERROR")
        }
    }

    private func makeRunner(script: String) throws -> (runner: ClamAVRunner, directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("scanner")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = ConfigManager(appSupportURL: directory)
        var settings = AppSettings.default
        settings.clamScanPath = executable.path
        settings.lowImpactMode = false
        try config.saveSettings(settings)
        return (ClamAVRunner(configManager: config), directory, executable)
    }

    /// Opt-in real-engine coverage; ordinary CI requires no external ClamAV installation.
    /// Signature format: https://docs.clamav.net/manual/Signatures/ExtendedSignatures.html
    func testInstalledEngineDetectsHarmlessFixtureAndQuarantineRoundTrips() async throws {
        guard let executable = ProcessInfo.processInfo.environment["SAFEMAC_CLAMSCAN_PATH"] else {
            throw XCTSkip("Set TEST_RUNNER_SAFEMAC_CLAMSCAN_PATH to a local clamscan executable for the real-engine smoke test.")
        }
        XCTAssertTrue(FreshclamInvocation.isTrustedExecutable(at: executable))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        let database = root.appendingPathComponent("database")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        // This harmless text matches only our temporary test signature; no malware is used.
        let bytes = Data("SafeMac harmless integration fixture 2026".utf8)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try Data("SafeMac.Test.Harmless:0:*:\(hex)\n".utf8).write(to: database.appendingPathComponent("fixture.ndb"))
        let detected = files.appendingPathComponent("sample : draft.txt")
        let clean = files.appendingPathComponent("clean.txt")
        try bytes.write(to: detected)
        try Data("Ordinary clean fixture".utf8).write(to: clean)
        let config = ConfigManager(appSupportURL: root.appendingPathComponent("config"))
        var settings = AppSettings.default
        settings.clamScanPath = executable
        settings.signatureDirectory = database.path
        settings.quarantineDirectory = root.appendingPathComponent("quarantine").path
        settings.lowImpactMode = false
        try config.saveSettings(settings)
        let runner = ClamAVRunner(configManager: config)
        let report = try await runner.scan(paths: [files], options: .default) { _ in }
        XCTAssertEqual(report.filesScanned, 2)
        XCTAssertEqual(report.completionState, .infectedFound)
        XCTAssertTrue(report.completedWithoutErrors)
        XCTAssertEqual(report.infectedFiles.count, 1)
        let finding = try XCTUnwrap(report.infectedFiles.first)
        // ClamAV reports POSIX canonical paths; Foundation may retain the /var alias.
        let canonicalPath = try XCTUnwrap(realpath(detected.path, nil))
        defer { free(canonicalPath) }
        XCTAssertEqual(finding.path, String(cString: canonicalPath))
        XCTAssertTrue(finding.threatName.hasPrefix("SafeMac.Test.Harmless"))
        let quarantine = QuarantineManager(configManager: config)
        try await quarantine.quarantine(file: finding.path, threat: finding.threatName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: detected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clean.path))
        let isolated = try XCTUnwrap(try quarantine.readQuarantinedFiles().first)
        try await quarantine.restore(file: isolated)
        XCTAssertEqual(try Data(contentsOf: detected), bytes)
        XCTAssertTrue(try quarantine.readQuarantinedFiles().isEmpty)
        let cleanReport = try await runner.scan(paths: [clean], options: .default) { _ in }
        XCTAssertTrue(cleanReport.isClean)
        XCTAssertEqual(cleanReport.filesScanned, 1)
    }

    // MARK: - Output Parsing Tests

    func testParseCleanFile() {
        let output = "/Users/test/file.txt: OK"
        let result = ClamAVRunner.parseInfectedLine(output)
        XCTAssertNil(result, "Clean file should not produce a scan result")
    }

    func testParseInfectedFile() {
        let output = "/Users/test/malware.exe: Win.Trojan.Agent-123456 FOUND"
        let result = ClamAVRunner.parseInfectedLine(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.path, "/Users/test/malware.exe")
        XCTAssertEqual(result?.threatName, "Win.Trojan.Agent-123456")
    }

    func testParsePathWithSpaces() {
        let output = "/Users/test/My Documents/file.txt: Eicar-Test-Signature FOUND"
        let result = ClamAVRunner.parseInfectedLine(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.path, "/Users/test/My Documents/file.txt")
        XCTAssertEqual(result?.threatName, "Eicar-Test-Signature")
    }

    func testParseEmptyFile() {
        let output = "/Users/test/empty.txt: Empty file"
        let result = ClamAVRunner.parseInfectedLine(output)
        XCTAssertNil(result, "Empty file should not produce a scan result")
    }

    func testParsePathContainingColonAndSpace() {
        let output = "/tmp/folder: name/eicar.txt: Eicar-Test-Signature FOUND"

        let result = ClamAVRunner.parseInfectedLine(output)

        XCTAssertEqual(result?.path, "/tmp/folder: name/eicar.txt")
        XCTAssertEqual(result?.threatName, "Eicar-Test-Signature")
    }

    func testCurrentFilePathPreservesColonAndSpace() {
        let output = "/tmp/folder: name/eicar.txt: Eicar-Test-Signature FOUND"

        XCTAssertEqual(
            ClamAVRunner.currentFilePath(from: output),
            "/tmp/folder: name/eicar.txt"
        )
    }

    // MARK: - Threat Classification Tests

    func testClassifyTrojan() {
        let severity = ClamAVRunner.classifyThreat("Win.Trojan.Agent-123456")
        XCTAssertEqual(severity, .critical)
    }

    func testClassifyVirus() {
        let severity = ClamAVRunner.classifyThreat("Win.Virus.Sality-1234")
        XCTAssertEqual(severity, .high)
    }

    func testClassifyAdware() {
        let severity = ClamAVRunner.classifyThreat("Adware.Generic-5678")
        XCTAssertEqual(severity, .medium)
    }

    func testClassifyPUA() {
        let severity = ClamAVRunner.classifyThreat("PUA.Win.Tool.Packed-123")
        XCTAssertEqual(severity, .low)
    }

    func testClassifyUnknown() {
        let severity = ClamAVRunner.classifyThreat("Unknown.Malware-999")
        XCTAssertEqual(severity, .medium, "Unknown threats should default to medium")
    }

    // MARK: - Argument Building Tests

    func testDisablingArchiveScanningOverridesClamAVDefault() {
        var options = ScanOptions.default
        options.scanArchives = false

        let arguments = ClamAVRunner.buildClamscanArguments(paths: [], options: options)

        XCTAssertTrue(arguments.contains("--scan-archive=no"))
        XCTAssertFalse(arguments.contains("--scan-archive=yes"))
    }

    func testBuildDefaultArguments() {
        let options = ScanOptions.default
        let paths = [URL(fileURLWithPath: "/Users/test")]
        let args = ClamAVRunner.buildClamscanArguments(paths: paths, options: options)

        XCTAssertTrue(args.contains("-r"), "Should include recursive flag")
        XCTAssertFalse(args.contains("--infected"), "Should not suppress clean-file output because progress depends on it")
        XCTAssertTrue(args.contains("/Users/test"), "Should include scan path")
    }

    func testBuildArgumentsWithSymlinks() {
        var options = ScanOptions.default
        options.followSymlinks = true
        let paths = [URL(fileURLWithPath: "/test")]
        let args = ClamAVRunner.buildClamscanArguments(paths: paths, options: options)

        XCTAssertTrue(args.contains("--follow-dir-symlinks=1"))
        XCTAssertTrue(args.contains("--follow-file-symlinks=1"))
    }

    func testBuildArgumentsWithoutSymlinks() {
        var options = ScanOptions.default
        options.followSymlinks = false
        let paths = [URL(fileURLWithPath: "/test")]
        let args = ClamAVRunner.buildClamscanArguments(paths: paths, options: options)

        XCTAssertTrue(args.contains("--follow-dir-symlinks=0"))
        XCTAssertTrue(args.contains("--follow-file-symlinks=0"))
    }

    func testBuildArgumentsWithExclusions() {
        var options = ScanOptions.default
        options.excludedPaths = ["node_modules", ".git"]
        let paths = [URL(fileURLWithPath: "/test")]
        let args = ClamAVRunner.buildClamscanArguments(paths: paths, options: options)

        XCTAssertTrue(args.contains("--exclude=node_modules"))
        XCTAssertTrue(args.contains("--exclude-dir=node_modules"))
        XCTAssertTrue(args.contains("--exclude=.git"))
        XCTAssertTrue(args.contains("--exclude-dir=.git"))
    }

    func testBuildArgumentsWithPUA() {
        var options = ScanOptions.default
        options.detectPUA = true
        let paths = [URL(fileURLWithPath: "/test")]
        let args = ClamAVRunner.buildClamscanArguments(paths: paths, options: options)

        XCTAssertTrue(args.contains("--detect-pua=yes"))
    }

    // MARK: - Exit Code Handling Tests

    func testCompletionStateSuccessForExitCodeZero() {
        XCTAssertEqual(ClamAVRunner.completionState(forExitCode: 0, infectedCount: 0), .success)
    }

    func testCompletionStateInfectedForExitCodeOne() {
        XCTAssertEqual(ClamAVRunner.completionState(forExitCode: 1, infectedCount: 1), .infectedFound)
    }

    func testCompletionStateErrorForExitCodeTwo() {
        XCTAssertEqual(ClamAVRunner.completionState(forExitCode: 2, infectedCount: 0), .scanError)
    }

}

final class FreshclamRunnerTests: XCTestCase {
    func testConfigurationInspectionDistinguishesMissingSampleAndActiveConfigWithoutWriting() throws {
        let fixture = try makeUpdater(script: "exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let config = fixture.directory.appendingPathComponent("freshclam.conf")
        let sample = fixture.directory.appendingPathComponent("freshclam.conf.sample")
        try "Example\n".write(to: sample, atomically: true, encoding: .utf8)
        XCTAssertEqual(FreshclamConfigurationStatus.inspect(directory: fixture.directory.path), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))

        let example = "# Sample configuration\n  Example  \nDatabaseMirror database.clamav.net\n"
        try example.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(FreshclamConfigurationStatus.inspect(directory: fixture.directory.path), .example)
        XCTAssertEqual(try String(contentsOf: config), example)

        let custom = "# Example\nDatabaseMirror example.internal\n"
        try custom.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(FreshclamConfigurationStatus.inspect(directory: fixture.directory.path), .ready)
        XCTAssertEqual(try String(contentsOf: config), custom)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        XCTAssertEqual(FreshclamConfigurationStatus.inspect(directory: fixture.directory.path), .unreadable)
    }

    func testMissingSelectedConfigurationPreservesInstallationDefaultFallback() throws {
        let fixture = try makeUpdater(script: "exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let invocation = try FreshclamInvocation.make(executablePath: fixture.settings.freshclamPath,
            configDirectory: fixture.settings.configDirectory, signatureDirectory: fixture.settings.signatureDirectory)
        XCTAssertFalse(invocation.arguments.contains { $0.hasPrefix("--config-file=") })
    }

    func testConfigurationFailuresExplainTheRequiredRecovery() {
        let example = FreshclamRunner.parseUpdateOutput(
            "ERROR: Please edit the example config file /tmp/freshclam.conf\nERROR: Can't open/parse the config file /tmp/freshclam.conf", exitCode: 56)
        XCTAssertTrue(example.message.contains("standalone Example line"))
        let missing = FreshclamRunner.parseUpdateOutput(
            "ERROR: Can't open/parse the config file /tmp/freshclam.conf", exitCode: 56)
        XCTAssertTrue(missing.message.contains("freshclam.conf.sample"))
        XCTAssertTrue(missing.message.contains("existing configuration"))
    }

    func testUpdatePreservesDiagnosticSplitAcrossUTF8PipeReads() async throws {
        let fixture = try makeUpdater(script: """
        printf 'ERROR: cannot update caf\\303'
        /bin/sleep 0.1
        printf '\\251 database\\n'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await fixture.runner.update(using: fixture.settings)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "ERROR: cannot update café database")
    }

    func testInvalidConfigurationPathIsNotReportedAsMissingExecutable() async throws {
        let fixture = try makeUpdater(script: "exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var settings = fixture.settings
        settings.configDirectory = "relative/config"

        do {
            _ = try await fixture.runner.update(using: settings)
            XCTFail("Expected invalid configuration to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("configuration"))
            XCTAssertFalse(error.localizedDescription.contains("executable not found"))
        }
    }

    func testUnwritableSignatureDirectoryIsReportedAccurately() async throws {
        let fixture = try makeUpdater(script: "exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let blockingFile = fixture.directory.appendingPathComponent("regular-file")
        try Data("fixture".utf8).write(to: blockingFile)
        var settings = fixture.settings
        settings.signatureDirectory = blockingFile.appendingPathComponent("database").path

        do {
            _ = try await fixture.runner.update(using: settings)
            XCTFail("Expected signature directory creation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("signature directory"))
            XCTAssertFalse(error.localizedDescription.contains("executable not found"))
        }
    }

    private func makeUpdater(script: String) throws -> (runner: FreshclamRunner, directory: URL, settings: AppSettings) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("updater")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = ConfigManager(appSupportURL: directory)
        var settings = AppSettings.default
        settings.freshclamPath = executable.path
        settings.configDirectory = directory.path
        settings.signatureDirectory = directory.appendingPathComponent("db").path
        return (FreshclamRunner(configManager: config), directory, settings)
    }

    func testParseAlreadyUpToDateOutput() {
        let output = """
        daily.cld database is up-to-date (version: 28021, sigs: 2075174, f-level: 90, builder: raynman)
        main.cvd database is up-to-date (version: 63, sigs: 6646647, f-level: 90, builder: sigmgr)
        bytecode.cvd database is up-to-date (version: 339, sigs: 80, f-level: 90, builder: anvilleg)
        """

        let result = FreshclamRunner.parseUpdateOutput(output, exitCode: 0)

        XCTAssertEqual(result.status, .upToDate)
        XCTAssertEqual(result.message, "Signatures are already up to date")
    }

    func testParseUpdatedOutputCapturesVersions() {
        let output = """
        daily.cld updated (version: 28022, sigs: 2076000, f-level: 90, builder: raynman)
        main.cvd database is up-to-date (version: 63, sigs: 6646647, f-level: 90, builder: sigmgr)
        bytecode.cvd database is up-to-date (version: 339, sigs: 80, f-level: 90, builder: anvilleg)
        """

        let result = FreshclamRunner.parseUpdateOutput(output, exitCode: 0)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.dailyVersion, "28022")
        XCTAssertEqual(result.mainVersion, "63")
        XCTAssertEqual(result.bytecodeVersion, "339")
    }

    func testParseFailedOutputDoesNotReportSuccess() {
        let output = "ERROR: Can't connect to database.clamav.net"

        let result = FreshclamRunner.parseUpdateOutput(output, exitCode: 1)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("ERROR"))
    }
}

final class ScanOptionsTests: XCTestCase {
    func testLegacyScanOptionsDecodeKeepsNewDefaults() throws {
        let legacyJSON = """
        {
          "recursive": true,
          "followSymlinks": false,
          "scanArchives": true,
          "maxFileSize": 50,
          "maxRecursionDepth": 8,
          "detectPUA": true,
          "quarantineInfected": false,
          "excludedPaths": ["node_modules"]
        }
        """

        let options = try JSONDecoder().decode(ScanOptions.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(options.maxFileSize, 50)
        XCTAssertEqual(options.maxScanSize, ScanOptions.default.maxScanSize)
        XCTAssertEqual(options.heuristicAlerts, ScanOptions.default.heuristicAlerts)
        XCTAssertEqual(options.crossFileSystem, ScanOptions.default.crossFileSystem)
        XCTAssertEqual(options.databasePath, ScanOptions.default.databasePath)
        XCTAssertEqual(options.excludedPaths, ["node_modules"])
    }
}
