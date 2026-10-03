import Foundation
import CryptoKit
import Darwin

protocol QuarantineManagerProtocol {
    func quarantine(file: String, threat: String) async throws
    func restore(file: QuarantinedFile) async throws
    func delete(file: QuarantinedFile) throws
    func listQuarantinedFiles() -> [QuarantinedFile]
}

final class QuarantineManager: QuarantineManagerProtocol {
    // All managers share this queue so metadata and payload changes form one in-process
    // transaction, including when callers construct multiple managers for the same storage.
    private static let transactionQueue = DispatchQueue(label: "com.safemac.quarantine", qos: .utility)
    private let configManager: ConfigManagerProtocol
    private let fileManager = FileManager.default

    private var quarantineDirectory: String {
        configManager.loadSettings().quarantineDirectory
    }

    init(configManager: ConfigManagerProtocol) {
        self.configManager = configManager
    }

    func quarantine(file: String, threat: String) async throws {
        try await performTransaction { try self.quarantineTransaction(file: file, threat: threat) }
    }

    private func quarantineTransaction(file: String, threat: String) throws {
        let sourceURL = URL(fileURLWithPath: file)
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)

        guard fileManager.fileExists(atPath: file) else {
            throw QuarantineError.fileNotFound(file)
        }

        let sourcePath = sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let storagePath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let storagePrefix = storagePath.hasSuffix("/") ? storagePath : storagePath + "/"
        guard sourcePath != storagePath, !sourcePath.hasPrefix(storagePrefix) else {
            throw QuarantineError.invalidPayload("Files already inside quarantine storage cannot be quarantined again.")
        }

        let storageLock = try acquireStorageLock(in: directoryURL)
        defer { releaseStorageLock(storageLock) }
        var metadata = try loadMetadata(at: metadataURL(in: directoryURL))
        let attrs = try fileManager.attributesOfItem(atPath: file)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw QuarantineError.invalidPayload("Only regular files can be quarantined.")
        }
        let fileSize = attrs[.size] as? Int64 ?? 0
        let hash = try calculateSHA256(url: sourceURL)

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
        try await performTransaction { try self.restoreTransaction(file: file) }
    }

    private func restoreTransaction(file: QuarantinedFile) throws {
        let quarantineURL = URL(fileURLWithPath: file.quarantinePath)
        let originalURL = URL(fileURLWithPath: file.originalPath)
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)

        let storageLock = try acquireStorageLock(in: directoryURL)
        defer { releaseStorageLock(storageLock) }
        var metadata = try loadMetadata(at: metadataURL(in: directoryURL))
        try validateRegisteredRecord(file, in: metadata)
        try validatePayload(at: quarantineURL, in: directoryURL)
        let currentHash = try calculateSHA256(url: quarantineURL)
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
        try Self.transactionQueue.sync { try deleteTransaction(file: file) }
    }

    private func deleteTransaction(file: QuarantinedFile) throws {
        let quarantineURL = URL(fileURLWithPath: file.quarantinePath)
        let directoryURL = URL(fileURLWithPath: quarantineDirectory)

        let storageLock = try acquireStorageLock(in: directoryURL)
        defer { releaseStorageLock(storageLock) }
        let previousMetadata = try loadMetadata(at: metadataURL(in: directoryURL))
        try validateRegisteredRecord(file, in: previousMetadata)
        try validatePayload(at: quarantineURL, in: directoryURL, allowMissing: true)
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
        (try? readQuarantinedFiles()) ?? []
    }

    func readQuarantinedFiles() throws -> [QuarantinedFile] {
        try Self.transactionQueue.sync {
            let directoryURL = URL(fileURLWithPath: quarantineDirectory)
            guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
            let storageLock = try acquireStorageLock(in: directoryURL)
            defer { releaseStorageLock(storageLock) }
            let metadata = try loadMetadata(at: metadataURL(in: directoryURL))
            return try metadata.files.filter {
                let payloadURL = URL(fileURLWithPath: $0.quarantinePath)
                try validatePayload(at: payloadURL, in: directoryURL, allowMissing: true)
                return fileManager.fileExists(atPath: payloadURL.path)
            }
        }
    }

    private func performTransaction(_ operation: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.transactionQueue.async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func validateRegisteredRecord(_ file: QuarantinedFile, in metadata: QuarantineMetadata) throws {
        let matches = metadata.files.filter { $0.id == file.id }
        guard matches.count == 1, matches.first == file else {
            throw QuarantineError.invalidRecord
        }
    }

    private func validatePayload(at url: URL, in directoryURL: URL, allowMissing: Bool = false) throws {
        let payloadURL = url.standardizedFileURL
        let storageURL = directoryURL.standardizedFileURL
        guard url.path == payloadURL.path,
              payloadURL.deletingLastPathComponent().path == storageURL.path,
              payloadURL.pathExtension == "quarantine",
              UUID(uuidString: payloadURL.deletingPathExtension().lastPathComponent) != nil else {
            throw QuarantineError.invalidPayload("The payload is not a quarantine file in the selected storage directory.")
        }

        // attributesOfItem inspects the link itself, unlike fileExists, which follows it.
        // This rejects symlinks (including dangling links), directories and special files.
        do {
            let attributes = try fileManager.attributesOfItem(atPath: payloadURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw QuarantineError.invalidPayload("The quarantine payload must be a regular file.")
            }
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == NSFileReadNoSuchFileError else { throw error }
            if allowMissing { return }
            throw QuarantineError.fileNotFound(payloadURL.path)
        }
    }

    private func acquireStorageLock(in directoryURL: URL) throws -> Int32 {
        try ensureQuarantineDirectoryExists(at: directoryURL)
        let lockURL = directoryURL.appendingPathComponent(".transaction.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else {
            throw QuarantineError.storageFailed("Could not open the quarantine transaction lock: \(String(cString: strerror(errno)))")
        }

        do {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0,
                  attributes.st_uid == geteuid(),
                  attributes.st_nlink == 1,
                  (attributes.st_mode & S_IFMT) == S_IFREG else {
                throw QuarantineError.storageFailed("The quarantine transaction lock must be a regular file owned by the current user.")
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw QuarantineError.storageFailed("Could not secure the quarantine transaction lock.")
            }
            // Each process opens its own descriptor; flock therefore also serialises
            // GUI and scheduled launches that share this quarantine directory.
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw QuarantineError.storageFailed("Could not acquire the quarantine transaction lock: \(String(cString: strerror(errno)))")
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func releaseStorageLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
        // Keep the lock file: unlinking it would let another process lock a different inode.
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

    private func calculateSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum QuarantineError: LocalizedError {
    case fileNotFound(String)
    case moveFailed(String)
    case restoreFailed(String)
    case deleteFailed(String)
    case metadataFailed(String)
    case storageFailed(String)
    case invalidRecord
    case invalidPayload(String)
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
        case .invalidRecord:
            return "This file no longer matches a record in the selected quarantine. Refresh the list and try again."
        case .invalidPayload(let reason):
            return "Invalid quarantine payload: \(reason)"
        case .hashMismatch:
            return "Quarantined file hash no longer matches its metadata."
        }
    }
}
