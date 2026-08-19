import Foundation

protocol ConfigManagerProtocol {
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

    init(appSupportURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = appSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let appDirectoryURL = appSupport.appendingPathComponent("ClamAV-GUI", isDirectory: true)
        self.appDirectoryURL = appDirectoryURL
        self.settingsURL = appDirectoryURL.appendingPathComponent("settings.json")
    }

    func loadSettings() -> AppSettings {
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        do {
            try fileManager.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
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
