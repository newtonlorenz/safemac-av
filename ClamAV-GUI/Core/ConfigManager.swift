import Darwin
import Foundation

protocol ConfigManagerProtocol {
    var lastSettingsLoadState: SettingsLoadState { get }

    func loadSettings() -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
    func detectClamAVPaths() -> (clamscan: String?, freshclam: String?, configDir: String?)
    func validateClamAVInstallation() -> ClamAVInstallationStatus
    func validateClamAVInstallation(using settings: AppSettings) -> ClamAVInstallationStatus
    func getSignatureInfo() -> SignatureInfo
}

final class ConfigManager: ConfigManagerProtocol {
    private let fileManager: FileManager
    private let appDirectoryURL: URL
    private let settingsURL: URL
    private let legacySettingsURL: URL
    private(set) var lastSettingsLoadState: SettingsLoadState = .missing

    init(appSupportURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = appSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let appDirectoryURL = appSupport.appendingPathComponent("SafeMac AV", isDirectory: true)
        self.appDirectoryURL = appDirectoryURL
        self.settingsURL = appDirectoryURL.appendingPathComponent("settings.json")
        self.legacySettingsURL = appSupport
            .appendingPathComponent("ClamAV-GUI", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func loadSettings() -> AppSettings {
        do {
            try SafeMacPersistenceMigration.migrateFileIfNeeded(
                from: legacySettingsURL,
                to: settingsURL,
                fileManager: fileManager,
                validator: { _ = try JSONDecoder().decode(AppSettings.self, from: $0) }
            )
        } catch {
            lastSettingsLoadState = .fallbackDueToError(reason: error.localizedDescription)
            return .default
        }

        guard fileManager.fileExists(atPath: settingsURL.path) else {
            lastSettingsLoadState = .missing
            return .default
        }

        do {
            let data = try SafeMacPersistenceMigration.readOwnedRegularFile(at: settingsURL)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectoryURL.path)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            lastSettingsLoadState = .loaded
            return settings
        } catch {
            lastSettingsLoadState = .fallbackDueToError(reason: error.localizedDescription)
            return .default
        }
    }

    func saveSettings(_ settings: AppSettings) throws {
        do {
            try fileManager.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectoryURL.path)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        } catch {
            throw ConfigManagerError.settingsSaveFailed(
                path: settingsURL.path,
                reason: error.localizedDescription
            )
        }
    }

    func detectClamAVPaths() -> (clamscan: String?, freshclam: String?, configDir: String?) {
        let possiblePrefixes = ["/opt/homebrew", "/usr/local", "/usr"]

        var clamscan: String?
        var freshclam: String?
        var configDir: String?

        for prefix in possiblePrefixes {
            let clamscanPath = "\(prefix)/bin/clamscan"
            let freshclamPath = "\(prefix)/bin/freshclam"
            let configPath = "\(prefix)/etc/clamav"

            if clamscan == nil && fileManager.isExecutableFile(atPath: clamscanPath) {
                clamscan = clamscanPath
            }
            if freshclam == nil && fileManager.isExecutableFile(atPath: freshclamPath) {
                freshclam = freshclamPath
            }
            if configDir == nil && fileManager.fileExists(atPath: configPath) {
                configDir = configPath
            }
        }

        return (clamscan, freshclam, configDir)
    }

    func validateClamAVInstallation() -> ClamAVInstallationStatus {
        validateClamAVInstallation(using: loadSettings())
    }

    func validateClamAVInstallation(using settings: AppSettings) -> ClamAVInstallationStatus {
        guard fileManager.isExecutableFile(atPath: settings.freshclamPath) else {
            return .partialInstall(missing: ["freshclam"])
        }

        if settings.scannerBackend == .clamdscan {
            guard settings.clamdSettings.isEnabled,
                  fileManager.isExecutableFile(atPath: settings.clamdSettings.clamdScanPath) else {
                return .clamdUnavailable
            }
        } else {
            guard fileManager.isExecutableFile(atPath: settings.clamScanPath) else {
                return .notInstalled
            }
        }

        let signatureInfo = getSignatureInfo(using: settings)
        if signatureInfo.mainVersion == "Unknown" {
            return .missingSignatures
        }

        if let lastUpdated = signatureInfo.lastUpdated {
            let daysSinceUpdate = Calendar.current.dateComponents([.day], from: lastUpdated, to: Date()).day ?? 0
            if daysSinceUpdate > 7 {
                return .outdatedSignatures(daysSinceUpdate: daysSinceUpdate)
            }
        }

        let scannerPath = settings.scannerBackend == .clamdscan
            ? settings.clamdSettings.clamdScanPath
            : settings.clamScanPath
        return .ready(clamscanPath: scannerPath)
    }

    func getSignatureInfo() -> SignatureInfo {
        getSignatureInfo(using: loadSettings())
    }

    private func getSignatureInfo(using settings: AppSettings) -> SignatureInfo {
        let sigDir = settings.signatureDirectory

        var mainVersion = "Unknown"
        var dailyVersion = "Unknown"
        var bytecodeVersion = "Unknown"
        var lastUpdated: Date?

        let mainCvd = URL(fileURLWithPath: sigDir).appendingPathComponent("main.cvd")
        let dailyCvd = URL(fileURLWithPath: sigDir).appendingPathComponent("daily.cvd")
        let dailyCld = URL(fileURLWithPath: sigDir).appendingPathComponent("daily.cld")
        let bytecodeCvd = URL(fileURLWithPath: sigDir).appendingPathComponent("bytecode.cvd")

        if let attrs = try? fileManager.attributesOfItem(atPath: mainCvd.path),
           let modDate = attrs[.modificationDate] as? Date {
            mainVersion = extractCvdVersion(from: mainCvd) ?? "Installed"
            lastUpdated = modDate
        }

        let dailyPath = fileManager.fileExists(atPath: dailyCld.path) ? dailyCld : dailyCvd
        if fileManager.fileExists(atPath: dailyPath.path) {
            dailyVersion = extractCvdVersion(from: dailyPath) ?? "Installed"
            if let attrs = try? fileManager.attributesOfItem(atPath: dailyPath.path),
               let modDate = attrs[.modificationDate] as? Date {
                if lastUpdated.map({ modDate > $0 }) ?? true {
                    lastUpdated = modDate
                }
            }
        }

        if fileManager.fileExists(atPath: bytecodeCvd.path) {
            bytecodeVersion = extractCvdVersion(from: bytecodeCvd) ?? "Installed"
        }

        return SignatureInfo(
            mainVersion: mainVersion,
            dailyVersion: dailyVersion,
            bytecodeVersion: bytecodeVersion,
            lastUpdated: lastUpdated,
            signatureCount: nil
        )
    }

    private func extractCvdVersion(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: 512),
              let header = String(data: headerData, encoding: .ascii) else {
            return nil
        }

        let components = header.components(separatedBy: ":")
        if components.count >= 3 {
            return components[2]
        }
        return nil
    }
}

enum SafeMacPersistenceMigration {
    typealias Publisher = (URL, URL) throws -> Int32

    static func migrateFileIfNeeded(
        from legacyURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        validator: (Data) throws -> Void,
        publisher: Publisher? = nil
    ) throws {
        let legacyDirectory = legacyURL.deletingLastPathComponent()
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try rejectSymbolicLinkIfPresent(at: legacyDirectory.deletingLastPathComponent())
        try rejectSymbolicLinkIfPresent(at: destinationDirectory.deletingLastPathComponent())
        if pathExistsWithoutFollowingSymbolicLink(destinationURL) {
            let directoryDescriptor = try openOwnedDirectory(at: destinationDirectory)
            defer { close(directoryDescriptor) }
            let data = try readOwnedRegularFile(
                in: directoryDescriptor,
                named: destinationURL.lastPathComponent,
                displayPath: destinationURL.path
            )
            try validator(data)
            return
        }
        guard pathExistsWithoutFollowingSymbolicLink(legacyURL) else { return }

        let legacyDirectoryDescriptor = try openOwnedDirectory(at: legacyDirectory)
        defer { close(legacyDirectoryDescriptor) }
        let data = try readOwnedRegularFile(
            in: legacyDirectoryDescriptor,
            named: legacyURL.lastPathComponent,
            displayPath: legacyURL.path
        )
        try validator(data)
        let destinationDirectoryDescriptor = try openOwnedDirectory(
            at: destinationDirectory,
            createIfMissing: true
        )
        defer { close(destinationDirectoryDescriptor) }
        let temporaryName = ".safemac-migration-\(UUID().uuidString).tmp"
        let temporaryURL = destinationDirectory.appendingPathComponent(temporaryName)
        let temporaryDescriptor = try createTemporaryFile(
            in: destinationDirectoryDescriptor,
            named: temporaryName,
            displayPath: temporaryURL.path
        )
        let temporaryHandle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: true)
        do {
            try temporaryHandle.write(contentsOf: data)
            try temporaryHandle.synchronize()
            try temporaryHandle.close()
        } catch {
            try? temporaryHandle.close()
            throw error
        }
        defer {
            temporaryName.withCString { name in
                _ = unlinkat(destinationDirectoryDescriptor, name, 0)
            }
        }
        let linkResult: Int32
        if let publisher {
            linkResult = try publisher(temporaryURL, destinationURL)
        } else {
            linkResult = temporaryName.withCString { source in
                destinationURL.lastPathComponent.withCString { destination in
                    linkat(
                        destinationDirectoryDescriptor,
                        source,
                        destinationDirectoryDescriptor,
                        destination,
                        0
                    )
                }
            }
        }
        if linkResult != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // A competing publisher may have won the no-overwrite race. Validate the
        // actual path without following a final-component symlink before trusting it.
        let publishedData = try readOwnedRegularFile(
            in: destinationDirectoryDescriptor,
            named: destinationURL.lastPathComponent,
            displayPath: destinationURL.path
        )
        try validator(publishedData)
    }

    static func readOwnedRegularFile(at url: URL) throws -> Data {
        let directoryDescriptor = try openOwnedDirectory(at: url.deletingLastPathComponent())
        defer { close(directoryDescriptor) }
        return try readOwnedRegularFile(
            in: directoryDescriptor,
            named: url.lastPathComponent,
            displayPath: url.path
        )
    }

    private static func readOwnedRegularFile(
        in directoryDescriptor: Int32,
        named name: String,
        displayPath: String
    ) throws -> Data {
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let readError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? handle.close()
            throw readError
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            try? handle.close()
            throw SafeMacPersistenceMigrationError.unsafeFile(displayPath)
        }
        return try handle.readToEnd() ?? Data()
    }

    private static func openOwnedDirectory(
        at url: URL,
        createIfMissing: Bool = false
    ) throws -> Int32 {
        let parentURL = url.deletingLastPathComponent()
        let parentDescriptor: Int32 = parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(parentDescriptor) }
        try validateOwnedDirectory(descriptor: parentDescriptor, path: parentURL.path)

        if createIfMissing {
            let createResult = url.lastPathComponent.withCString {
                mkdirat(parentDescriptor, $0, mode_t(0o700))
            }
            if createResult != 0, errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        let descriptor = url.lastPathComponent.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try validateOwnedDirectory(descriptor: descriptor, path: url.path)
            if createIfMissing, fchmod(descriptor, mode_t(0o700)) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateOwnedDirectory(descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw SafeMacPersistenceMigrationError.unsafeDirectory(path)
        }
    }

    private static func createTemporaryFile(
        in directoryDescriptor: Int32,
        named name: String,
        displayPath: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            close(descriptor)
            throw SafeMacPersistenceMigrationError.unsafeFile(displayPath)
        }
        return descriptor
    }

    static func pathExistsWithoutFollowingSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }

    private static func rejectSymbolicLink(at url: URL) throws {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw SafeMacPersistenceMigrationError.symbolicLink(url.path)
        }
    }

    private static func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard pathExistsWithoutFollowingSymbolicLink(url) else { return }
        try rejectSymbolicLink(at: url)
    }
}

enum SafeMacPersistenceMigrationError: LocalizedError {
    case symbolicLink(String)
    case unsafeFile(String)
    case unsafeDirectory(String)

    var errorDescription: String? {
        switch self {
        case .symbolicLink(let path):
            return "Refusing to migrate a symbolic link at \(path)."
        case .unsafeFile(let path):
            return "Refusing to read an unowned or non-regular file at \(path)."
        case .unsafeDirectory(let path):
            return "Refusing to use an unowned or non-directory path at \(path)."
        }
    }
}

enum SettingsLoadState: Equatable {
    case missing
    case loaded
    case fallbackDueToError(reason: String)

    var allowsStartupReconciliationPersistence: Bool {
        switch self {
        case .missing, .loaded:
            return true
        case .fallbackDueToError:
            return false
        }
    }
}

enum ConfigManagerError: LocalizedError {
    case settingsSaveFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .settingsSaveFailed(let path, let reason):
            return "Unable to save settings at \(path): \(reason)"
        }
    }
}

enum ClamAVInstallationStatus: Equatable {
    case notInstalled
    case partialInstall(missing: [String])
    case missingSignatures
    case outdatedSignatures(daysSinceUpdate: Int)
    case clamdUnavailable
    case ready(clamscanPath: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isInstalled: Bool {
        switch self {
        case .missingSignatures, .outdatedSignatures, .ready:
            return true
        case .notInstalled, .partialInstall, .clamdUnavailable:
            return false
        }
    }

    var message: String {
        switch self {
        case .notInstalled:
            return "ClamAV is not installed. Please run: brew install clamav"
        case .partialInstall(let missing):
            return "Missing components: \(missing.joined(separator: ", "))"
        case .missingSignatures:
            return "Virus signatures not found. Please run Update Signatures."
        case .outdatedSignatures(let days):
            return "Signatures are \(days) days old. Consider updating."
        case .clamdUnavailable:
            return "clamdscan is selected but local clamd is not configured."
        case .ready:
            return "ClamAV is ready"
        }
    }
}
