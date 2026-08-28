import XCTest
@testable import ClamAV_GUI

final class ClamAVRunnerTests: XCTestCase {

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

final class ScanProgressEstimateTests: XCTestCase {
    func testFractionCompleteUsesEstimatedBytes() {
        let progress = ScanProgress(
            status: .scanning,
            currentFile: "/tmp/example",
            filesScanned: 1,
            infectedCount: 0,
            startTime: Date(),
            bytesScanned: 250,
            estimatedTotalFiles: 4,
            estimatedTotalBytes: 1_000
        )

        XCTAssertEqual(progress.fractionComplete, 0.25)
        XCTAssertEqual(progress.percentComplete, 25)
    }

    func testFractionCompleteIsUnavailableWithoutPositiveEstimate() {
        let progress = ScanProgress(
            status: .scanning,
            currentFile: nil,
            filesScanned: 0,
            infectedCount: 0,
            startTime: Date()
        )

        XCTAssertNil(progress.fractionComplete)
        XCTAssertNil(progress.percentComplete)
    }

    func testFractionCompleteClampsWhenFilesystemChangesDuringScan() {
        let progress = ScanProgress(
            status: .scanning,
            currentFile: nil,
            filesScanned: 3,
            infectedCount: 0,
            startTime: Date(),
            bytesScanned: 1_500,
            estimatedTotalFiles: 2,
            estimatedTotalBytes: 1_000
        )

        XCTAssertEqual(progress.fractionComplete, 1)
        XCTAssertEqual(progress.percentComplete, 100)
    }

    func testEstimatedTimeRemainingUsesObservedByteThroughput() {
        XCTAssertEqual(
            ScanProgressEstimate.estimatedTimeRemaining(
                bytesScanned: 250,
                totalBytes: 1_000,
                elapsedTime: 10
            ),
            30
        )
    }

    func testEstimatedTimeRemainingRequiresProgressAndElapsedTime() {
        XCTAssertNil(
            ScanProgressEstimate.estimatedTimeRemaining(
                bytesScanned: 0,
                totalBytes: 1_000,
                elapsedTime: 10
            )
        )
        XCTAssertNil(
            ScanProgressEstimate.estimatedTimeRemaining(
                bytesScanned: 250,
                totalBytes: 1_000,
                elapsedTime: 0
            )
        )
    }

    func testEstimatorSumsRecursiveRegularFilesAndTracksTheirSizes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.bin")
        let second = nested.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 128).write(to: first)
        try Data(repeating: 2, count: 384).write(to: second)

        var options = ScanOptions.default
        options.excludedPaths = []
        let estimate = await ScanSizeEstimator.estimate(paths: [root], options: options)

        XCTAssertEqual(estimate.totalFiles, 2)
        XCTAssertEqual(estimate.totalBytes, 512)
        XCTAssertEqual(estimate.fileSize(atPath: first.path), 128)
        XCTAssertEqual(estimate.fileSize(atPath: second.path), 384)
    }

    func testEstimatorHonorsExclusionsAndDoesNotFollowSymlinksByDefault() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ignored = root.appendingPathComponent("ignored", isDirectory: true)
        let linkedTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedTarget, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: linkedTarget)
        }

        let includedFile = root.appendingPathComponent("included.bin")
        try Data(repeating: 1, count: 64).write(to: includedFile)
        try Data(repeating: 2, count: 128).write(to: ignored.appendingPathComponent("ignored.bin"))
        try Data(repeating: 3, count: 256).write(to: linkedTarget.appendingPathComponent("linked.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-folder"),
            withDestinationURL: linkedTarget
        )

        var options = ScanOptions.default
        options.followSymlinks = false
        options.excludedPaths = ["ignored"]
        let estimate = await ScanSizeEstimator.estimate(paths: [root], options: options)

        XCTAssertEqual(estimate.totalFiles, 1)
        XCTAssertEqual(estimate.totalBytes, 64)
        XCTAssertEqual(estimate.fileSize(atPath: includedFile.path), 64)
    }

    func testEstimatorUsesIndeterminateProgressWhenOnlyInfectedFilesAreReported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 64).write(to: root.appendingPathComponent("included.bin"))

        var options = ScanOptions.default
        options.reportOnlyInfected = true
        let estimate = await ScanSizeEstimator.estimate(paths: [root], options: options)

        XCTAssertEqual(estimate.totalFiles, 0)
        XCTAssertEqual(estimate.totalBytes, 0)
    }

    func testEstimatorUsesIndeterminateProgressWhenFollowingSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 64).write(to: root.appendingPathComponent("included.bin"))

        var options = ScanOptions.default
        options.followSymlinks = true
        let estimate = await ScanSizeEstimator.estimate(paths: [root], options: options)

        XCTAssertEqual(estimate.totalFiles, 0)
        XCTAssertEqual(estimate.totalBytes, 0)
    }

    func testEstimatorHonorsRegexExclusionPatterns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let includedFile = root.appendingPathComponent("included.txt")
        try Data(repeating: 1, count: 64).write(to: includedFile)
        try Data(repeating: 2, count: 128).write(to: root.appendingPathComponent("ignored.tmp"))

        var options = ScanOptions.default
        options.excludedPaths = [#"\.tmp$"#]
        let estimate = await ScanSizeEstimator.estimate(paths: [root], options: options)

        XCTAssertEqual(estimate.totalFiles, 1)
        XCTAssertEqual(estimate.totalBytes, 64)
        XCTAssertEqual(estimate.fileSize(atPath: includedFile.path), 64)
    }
}

final class FreshclamRunnerTests: XCTestCase {
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
