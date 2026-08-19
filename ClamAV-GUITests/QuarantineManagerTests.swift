import XCTest
@testable import ClamAV_GUI

final class QuarantineManagerTests: XCTestCase {

    var quarantineManager: QuarantineManager!
    var configManager: MockConfigManager!
    var tempDirectory: URL!
    var quarantineDirectory: URL!

    override func setUp() {
        super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        quarantineDirectory = tempDirectory.appendingPathComponent("quarantine")

        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        configManager = MockConfigManager(quarantineDirectory: quarantineDirectory.path)
        quarantineManager = QuarantineManager(configManager: configManager)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Quarantine Tests

    func testQuarantineFile() async throws {
        // Create a test file
        let testFile = tempDirectory.appendingPathComponent("infected.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)

        // Quarantine the file
        try await quarantineManager.quarantine(file: testFile.path, threat: "Test.Virus")

        // Original file should be moved
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))

        // Should appear in quarantine list
        let quarantined = quarantineManager.listQuarantinedFiles()
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined.first?.originalPath, testFile.path)
        XCTAssertEqual(quarantined.first?.threatName, "Test.Virus")
    }

    func testQuarantineRecordsMetadata() async throws {
        let testFile = tempDirectory.appendingPathComponent("malware.exe")
        let content = "malicious content"
        try content.write(to: testFile, atomically: true, encoding: .utf8)

        try await quarantineManager.quarantine(file: testFile.path, threat: "Win.Trojan.Test")

        let quarantined = quarantineManager.listQuarantinedFiles().first

        XCTAssertNotNil(quarantined)
        XCTAssertEqual(quarantined?.originalFileName, "malware.exe")
        XCTAssertFalse(quarantined?.sha256Hash.isEmpty ?? true)
        XCTAssertGreaterThan(quarantined?.fileSize ?? 0, 0)
    }

    func testQuarantineNonexistentFile() async {
        do {
            try await quarantineManager.quarantine(file: "/nonexistent/file.txt", threat: "Test")
            XCTFail("Should throw error for nonexistent file")
        } catch {
            XCTAssertTrue(error is QuarantineError)
        }
    }

    func testQuarantineRestoresSourceWhenMetadataCannotBeWritten() async throws {
        let testFile = tempDirectory.appendingPathComponent("metadata_failure.txt")
        try "must survive".write(to: testFile, atomically: true, encoding: .utf8)
        try replaceMetadataFileWithDirectory()

        do {
            try await quarantineManager.quarantine(file: testFile.path, threat: "Test")
            XCTFail("Expected quarantine to fail when metadata cannot be written")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("metadata"))
        }

        XCTAssertEqual(try String(contentsOf: testFile, encoding: .utf8), "must survive")
        XCTAssertTrue(try quarantinePayloads().isEmpty)
    }

    func testQuarantineRejectsCorruptExistingMetadata() async throws {
        let testFile = tempDirectory.appendingPathComponent("corrupt_metadata.txt")
        try "must remain visible".write(to: testFile, atomically: true, encoding: .utf8)
        try Data("not json".utf8).write(to: metadataURL)

        do {
            try await quarantineManager.quarantine(file: testFile.path, threat: "Test")
            XCTFail("Expected quarantine to reject corrupt metadata")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("metadata"))
        }

        XCTAssertEqual(try String(contentsOf: testFile, encoding: .utf8), "must remain visible")
        XCTAssertEqual(try Data(contentsOf: metadataURL), Data("not json".utf8))
        XCTAssertTrue(try quarantinePayloads().isEmpty)
    }

    // MARK: - Restore Tests

    func testRestoreFile() async throws {
        // Create and quarantine a file
        let testFile = tempDirectory.appendingPathComponent("restore_test.txt")
        let content = "restore me"
        try content.write(to: testFile, atomically: true, encoding: .utf8)

        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        // Get the quarantined file
        let quarantined = quarantineManager.listQuarantinedFiles().first!

        // Restore it
        try await quarantineManager.restore(file: quarantined)

        // Original file should exist again
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path))

        // Should be removed from quarantine list
        XCTAssertTrue(quarantineManager.listQuarantinedFiles().isEmpty)

        // Content should be preserved
        let restoredContent = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertEqual(restoredContent, content)
    }

    func testRestoreRefusesTamperedQuarantineFile() async throws {
        let testFile = tempDirectory.appendingPathComponent("tampered_restore.txt")
        try "restore me".write(to: testFile, atomically: true, encoding: .utf8)
        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        let quarantined = quarantineManager.listQuarantinedFiles().first!
        try "changed payload".write(
            to: URL(fileURLWithPath: quarantined.quarantinePath),
            atomically: true,
            encoding: .utf8
        )

        do {
            try await quarantineManager.restore(file: quarantined)
            XCTFail("Expected restore to fail when quarantine hash changes")
        } catch QuarantineError.hashMismatch(_, _) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.quarantinePath))
        } catch {
            XCTFail("Expected hash mismatch, got \(error)")
        }
    }

    func testRestoreCreatesCollisionSafeBackup() async throws {
        let testFile = tempDirectory.appendingPathComponent("restore_collision.txt")
        try "original malware".write(to: testFile, atomically: true, encoding: .utf8)
        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        let quarantined = quarantineManager.listQuarantinedFiles().first!
        try "new clean file".write(to: testFile, atomically: true, encoding: .utf8)
        let existingBackup = testFile.appendingPathExtension("backup")
        try "existing backup".write(to: existingBackup, atomically: true, encoding: .utf8)

        try await quarantineManager.restore(file: quarantined)

        XCTAssertEqual(try String(contentsOf: testFile, encoding: .utf8), "original malware")
        XCTAssertEqual(try String(contentsOf: existingBackup, encoding: .utf8), "existing backup")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: "\(testFile.path).backup.1"), encoding: .utf8),
            "new clean file"
        )
    }

    func testRestoreRollsBackPayloadAndCollisionWhenMetadataCannotBeWritten() async throws {
        let testFile = tempDirectory.appendingPathComponent("restore_metadata_failure.txt")
        try "quarantined payload".write(to: testFile, atomically: true, encoding: .utf8)
        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        let quarantined = try XCTUnwrap(quarantineManager.listQuarantinedFiles().first)
        try "current clean file".write(to: testFile, atomically: true, encoding: .utf8)
        try replaceMetadataFileWithDirectory()

        do {
            try await quarantineManager.restore(file: quarantined)
            XCTFail("Expected restore to fail when metadata cannot be written")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("metadata"))
        }

        XCTAssertEqual(try String(contentsOf: testFile, encoding: .utf8), "current clean file")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: quarantined.quarantinePath), encoding: .utf8),
            "quarantined payload"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.appendingPathExtension("backup").path))
    }

    // MARK: - Delete Tests

    func testDeleteFromQuarantine() async throws {
        let testFile = tempDirectory.appendingPathComponent("delete_test.txt")
        try "delete me".write(to: testFile, atomically: true, encoding: .utf8)

        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        let quarantined = quarantineManager.listQuarantinedFiles().first!

        try quarantineManager.delete(file: quarantined)

        // Should be removed from list
        XCTAssertTrue(quarantineManager.listQuarantinedFiles().isEmpty)

        // Quarantine file should be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantined.quarantinePath))

        // Original should still not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
    }

    func testDeletePreservesPayloadWhenMetadataCannotBeWritten() async throws {
        let testFile = tempDirectory.appendingPathComponent("delete_metadata_failure.txt")
        try "keep quarantined".write(to: testFile, atomically: true, encoding: .utf8)
        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        let quarantined = try XCTUnwrap(quarantineManager.listQuarantinedFiles().first)
        try replaceMetadataFileWithDirectory()

        XCTAssertThrowsError(try quarantineManager.delete(file: quarantined)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("metadata"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.quarantinePath))
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: quarantined.quarantinePath), encoding: .utf8),
            "keep quarantined"
        )
    }

    // MARK: - List Tests

    func testListEmptyQuarantine() {
        let files = quarantineManager.listQuarantinedFiles()
        XCTAssertTrue(files.isEmpty)
    }

    func testListMultipleFiles() async throws {
        for i in 1...3 {
            let testFile = tempDirectory.appendingPathComponent("file\(i).txt")
            try "content \(i)".write(to: testFile, atomically: true, encoding: .utf8)
            try await quarantineManager.quarantine(file: testFile.path, threat: "Threat\(i)")
        }

        let files = quarantineManager.listQuarantinedFiles()
        XCTAssertEqual(files.count, 3)
    }

    // MARK: - Hash Tests

    func testSHA256HashIsValid() async throws {
        let testFile = tempDirectory.appendingPathComponent("hash_test.txt")
        try "test content for hashing".write(to: testFile, atomically: true, encoding: .utf8)

        try await quarantineManager.quarantine(file: testFile.path, threat: "Test")

        let quarantined = quarantineManager.listQuarantinedFiles().first!

        // SHA256 hash should be 64 hex characters
        XCTAssertEqual(quarantined.sha256Hash.count, 64)
        XCTAssertTrue(quarantined.sha256Hash.allSatisfy { $0.isHexDigit })
    }

    private var metadataURL: URL {
        quarantineDirectory.appendingPathComponent("metadata.json")
    }

    private func replaceMetadataFileWithDirectory() throws {
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)
    }

    private func quarantinePayloads() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "quarantine" }
    }
}

// MARK: - Mock ConfigManager

class MockConfigManager: ConfigManagerProtocol {
    private let mockQuarantineDirectory: String

    init(quarantineDirectory: String) {
        self.mockQuarantineDirectory = quarantineDirectory
    }

    func loadSettings() -> AppSettings {
        var settings = AppSettings.default
        settings.quarantineDirectory = mockQuarantineDirectory
        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {}

    func detectClamAVPaths() -> (clamscan: String?, freshclam: String?, configDir: String?) {
        return (nil, nil, nil)
    }

    func validateClamAVInstallation() -> ClamAVInstallationStatus {
        return .notInstalled
    }

    func validateClamAVInstallation(using settings: AppSettings) -> ClamAVInstallationStatus {
        return .notInstalled
    }

    func getSignatureInfo() -> SignatureInfo {
        return .unknown
    }
}
