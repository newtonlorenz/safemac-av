import Foundation
import CryptoKit

protocol QuarantineManagerProtocol {
    func quarantine(file: String, threat: String) async throws
    func restore(file: QuarantinedFile) async throws
    func delete(file: QuarantinedFile) throws
    func listQuarantinedFiles() -> [QuarantinedFile]
}

final class QuarantineManager: QuarantineManagerProtocol {
    private let configManager: ConfigManagerProtocol
    private let fileManager = FileManager.default

    private var quarantineDirectory: String {
        configManager.loadSettings().quarantineDirectory
    }

    init(configManager: ConfigManagerProtocol) {
        self.configManager = configManager
    }

    func quarantine(file: String, threat: String) async throws {
        let sourceURL = URL(fileURLWithPath: file)
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)

        guard fileManager.fileExists(atPath: file) else {
            throw QuarantineError.fileNotFound(file)
        }

        try ensureQuarantineDirectoryExists(at: directoryURL)
        var metadata = try loadMetadata(at: metadataURL(in: directoryURL))
        let attrs = try fileManager.attributesOfItem(atPath: file)
        let fileSize = attrs[.size] as? Int64 ?? 0
        let hash = try await calculateSHA256(url: sourceURL)

        let quarantineName = "\(UUID().uuidString).quarantine"
        let destinationURL = directoryURL.appendingPathComponent(quarantineName)

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw QuarantineError.moveFailed(error.localizedDescription)
        }

        let quarantinedFile = QuarantinedFile(
            id: UUID(),
            originalPath: file,
            quarantinePath: destinationURL.path,
            threatName: threat,
            quarantineDate: Date(),
            fileSize: fileSize,
            sha256Hash: hash
        )

        metadata.files.append(quarantinedFile)
        do {
            try saveMetadata(metadata, at: metadataURL(in: directoryURL))
        } catch {
            throw rollbackFailedQuarantine(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                metadataError: error
            )
        }
    }

    func restore(file: QuarantinedFile) async throws {
        let quarantineURL = URL(fileURLWithPath: file.quarantinePath)
        let originalURL = URL(fileURLWithPath: file.originalPath)
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)

        guard fileManager.fileExists(atPath: file.quarantinePath) else {
            throw QuarantineError.fileNotFound(file.quarantinePath)
        }

        try ensureQuarantineDirectoryExists(at: directoryURL)
        var metadata = try loadMetadata(at: metadataURL(in: directoryURL))
        let currentHash = try await calculateSHA256(url: quarantineURL)
        guard currentHash == file.sha256Hash else {
            throw QuarantineError.hashMismatch(expected: file.sha256Hash, actual: currentHash)
        }

        let originalDir = originalURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: originalDir.path) {
            try fileManager.createDirectory(at: originalDir, withIntermediateDirectories: true)
        }

        var backupURL: URL?
        if fileManager.fileExists(atPath: file.originalPath) {
            let availableBackupURL = nextAvailableBackupURL(for: originalURL)
            do {
                try fileManager.moveItem(at: originalURL, to: availableBackupURL)
                backupURL = availableBackupURL
            } catch {
                throw QuarantineError.restoreFailed(error.localizedDescription)
            }
        }

        do {
            try fileManager.moveItem(at: quarantineURL, to: originalURL)
        } catch {
            if let backupURL {
                try? fileManager.moveItem(at: backupURL, to: originalURL)
            }
            throw QuarantineError.restoreFailed(error.localizedDescription)
        }

        metadata.files.removeAll { $0.id == file.id }
        do {
            try saveMetadata(metadata, at: metadataURL(in: directoryURL))
        } catch {
            throw rollbackFailedRestore(
                originalURL: originalURL,
                quarantineURL: quarantineURL,
                backupURL: backupURL,
                metadataError: error
            )
        }
    }

    func delete(file: QuarantinedFile) throws {
        let quarantineURL = URL(fileURLWithPath: file.quarantinePath)
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)

        try ensureQuarantineDirectoryExists(at: directoryURL)
        let previousMetadata = try loadMetadata(at: metadataURL(in: directoryURL))
        var metadata = previousMetadata
        metadata.files.removeAll { $0.id == file.id }
        try saveMetadata(metadata, at: metadataURL(in: directoryURL))

        guard fileManager.fileExists(atPath: file.quarantinePath) else { return }

        do {
            try fileManager.removeItem(at: quarantineURL)
        } catch {
            let restorationError: Error?
            do {
                try saveMetadata(previousMetadata, at: metadataURL(in: directoryURL))
                restorationError = nil
            } catch {
                restorationError = error
            }

            let suffix = restorationError.map {
                " Metadata restoration also failed: \($0.localizedDescription)"
            } ?? ""
            throw QuarantineError.deleteFailed("\(error.localizedDescription).\(suffix)")
        }
    }

    func listQuarantinedFiles() -> [QuarantinedFile] {
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)
        let metadata = (try? loadMetadata(at: metadataURL(in: directoryURL))) ?? .empty
        return metadata.files.filter { fileManager.fileExists(atPath: $0.quarantinePath) }
    }

    private func metadataURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("metadata.json")
    }

    private func ensureQuarantineDirectoryExists(at directoryURL: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw QuarantineError.storageFailed("A file exists at \(directoryURL.path)")
            }
            return
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw QuarantineError.storageFailed(error.localizedDescription)
        }
    }

    private func loadMetadata(at url: URL) throws -> QuarantineMetadata {
        guard fileManager.fileExists(atPath: url.path) else { return .empty }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(QuarantineMetadata.self, from: data)
        } catch {
            throw QuarantineError.metadataFailed("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    private func saveMetadata(_ metadata: QuarantineMetadata, at url: URL) throws {
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: url, options: .atomic)
        } catch {
            throw QuarantineError.metadataFailed("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private func rollbackFailedQuarantine(
        sourceURL: URL,
        destinationURL: URL,
        metadataError: Error
    ) -> QuarantineError {
        do {
            try fileManager.moveItem(at: destinationURL, to: sourceURL)
            return .metadataFailed("Quarantine was rolled back: \(metadataError.localizedDescription)")
        } catch {
            return .moveFailed(
                "Metadata update failed (\(metadataError.localizedDescription)) and the source "
                    + "could not be restored (\(error.localizedDescription)). Payload remains at "
                    + destinationURL.path
            )
        }
    }

    private func rollbackFailedRestore(
        originalURL: URL,
        quarantineURL: URL,
        backupURL: URL?,
        metadataError: Error
    ) -> QuarantineError {
        var rollbackFailures: [String] = []

        do {
            try fileManager.moveItem(at: originalURL, to: quarantineURL)
        } catch {
            rollbackFailures.append("payload: \(error.localizedDescription)")
        }

        if let backupURL {
            do {
                try fileManager.moveItem(at: backupURL, to: originalURL)
            } catch {
                rollbackFailures.append("collision backup: \(error.localizedDescription)")
            }
        }

        guard rollbackFailures.isEmpty else {
            return .restoreFailed(
                "Metadata update failed (\(metadataError.localizedDescription)); rollback failed for "
                    + rollbackFailures.joined(separator: ", ")
            )
        }
        return .metadataFailed("Restore was rolled back: \(metadataError.localizedDescription)")
    }

    private func nextAvailableBackupURL(for url: URL) -> URL {
        var candidate = url.appendingPathExtension("backup")
        var index = 1

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: "\(url.path).backup.\(index)")
            index += 1
        }

        return candidate
    }

    private func calculateSHA256(url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum QuarantineError: LocalizedError {
    case fileNotFound(String)
    case moveFailed(String)
    case restoreFailed(String)
    case deleteFailed(String)
    case metadataFailed(String)
    case storageFailed(String)
    case hashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .moveFailed(let reason):
            return "Failed to move file: \(reason)"
        case .restoreFailed(let reason):
            return "Failed to restore file: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete quarantined file: \(reason)"
        case .metadataFailed(let reason):
            return "Failed to update quarantine metadata: \(reason)"
        case .storageFailed(let reason):
            return "Failed to prepare quarantine storage: \(reason)"
        case .hashMismatch:
            return "Quarantined file hash no longer matches its metadata."
        }
    }
}
