import Foundation

struct AppSettings: Codable, Equatable {
    var clamScanPath: String
    var freshclamPath: String
    var configDirectory: String
    var signatureDirectory: String
    var quarantineDirectory: String
    var defaultExclusions: [String]
    var customExclusions: [String]
    var autoUpdateSignatures: Bool
    var updateSchedule: ScanSchedule?
    var monitoredDirectories: [String]
    var monitoringEnabled: Bool
    var batchScanIntervalMinutes: Int
    var batchScanFileThreshold: Int
    var showNotifications: Bool
    var playSoundOnDetection: Bool
    var showPerformanceStats: Bool
    var pauseOnBattery: Bool
    var lowImpactMode: Bool
    var autoScanDownloads: Bool
    var notifyOnCleanFiles: Bool
    var scanWhenIdle: Bool
    var idleTimeoutMinutes: Int
    var launchAtLogin: Bool
    var hideFromDock: Bool
    var scannerBackend: ScannerBackend
    var clamdSettings: ClamdSettings

    var allExclusions: [String] {
        defaultExclusions + customExclusions
    }

    init(
        clamScanPath: String,
        freshclamPath: String,
        configDirectory: String,
        signatureDirectory: String,
        quarantineDirectory: String,
        defaultExclusions: [String],
        customExclusions: [String],
        autoUpdateSignatures: Bool,
        updateSchedule: ScanSchedule?,
        monitoredDirectories: [String],
        monitoringEnabled: Bool,
        batchScanIntervalMinutes: Int,
        batchScanFileThreshold: Int,
        showNotifications: Bool,
        playSoundOnDetection: Bool,
        showPerformanceStats: Bool = true,
        pauseOnBattery: Bool = true,
        lowImpactMode: Bool = false,
        autoScanDownloads: Bool = true,
        notifyOnCleanFiles: Bool = false,
        scanWhenIdle: Bool = true,
        idleTimeoutMinutes: Int = 30,
        launchAtLogin: Bool = false,
        hideFromDock: Bool = false,
        scannerBackend: ScannerBackend = .clamscan,
        clamdSettings: ClamdSettings = .default
    ) {
        self.clamScanPath = clamScanPath
        self.freshclamPath = freshclamPath
        self.configDirectory = configDirectory
        self.signatureDirectory = signatureDirectory
        self.quarantineDirectory = quarantineDirectory
        self.defaultExclusions = defaultExclusions
        self.customExclusions = customExclusions
        self.autoUpdateSignatures = autoUpdateSignatures
        self.updateSchedule = updateSchedule
        self.monitoredDirectories = monitoredDirectories
        self.monitoringEnabled = monitoringEnabled
        self.batchScanIntervalMinutes = batchScanIntervalMinutes
        self.batchScanFileThreshold = batchScanFileThreshold
        self.showNotifications = showNotifications
        self.playSoundOnDetection = playSoundOnDetection
        self.showPerformanceStats = showPerformanceStats
        self.pauseOnBattery = pauseOnBattery
        self.lowImpactMode = lowImpactMode
        self.autoScanDownloads = autoScanDownloads
        self.notifyOnCleanFiles = notifyOnCleanFiles
        self.scanWhenIdle = scanWhenIdle
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.launchAtLogin = launchAtLogin
        self.hideFromDock = hideFromDock
        self.scannerBackend = scannerBackend
        self.clamdSettings = clamdSettings
    }

    private enum CodingKeys: String, CodingKey {
        case clamScanPath
        case freshclamPath
        case configDirectory
        case signatureDirectory
        case quarantineDirectory
        case defaultExclusions
        case customExclusions
        case autoUpdateSignatures
        case updateSchedule
        case monitoredDirectories
        case monitoringEnabled
        case batchScanIntervalMinutes
        case batchScanFileThreshold
        case showNotifications
        case playSoundOnDetection
        case showPerformanceStats
        case pauseOnBattery
        case lowImpactMode
        case autoScanDownloads
        case notifyOnCleanFiles
        case scanWhenIdle
        case idleTimeoutMinutes
        case launchAtLogin
        case hideFromDock
        case scannerBackend
        case clamdSettings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default

        clamScanPath = try values.decodeIfPresent(String.self, forKey: .clamScanPath) ?? defaults.clamScanPath
        freshclamPath = try values.decodeIfPresent(String.self, forKey: .freshclamPath) ?? defaults.freshclamPath
        configDirectory = try values.decodeIfPresent(String.self, forKey: .configDirectory) ?? defaults.configDirectory
        signatureDirectory = try values.decodeIfPresent(String.self, forKey: .signatureDirectory) ?? defaults.signatureDirectory
        quarantineDirectory = try values.decodeIfPresent(String.self, forKey: .quarantineDirectory) ?? defaults.quarantineDirectory
        defaultExclusions = try values.decodeIfPresent([String].self, forKey: .defaultExclusions) ?? defaults.defaultExclusions
        customExclusions = try values.decodeIfPresent([String].self, forKey: .customExclusions) ?? defaults.customExclusions
        autoUpdateSignatures = try values.decodeIfPresent(Bool.self, forKey: .autoUpdateSignatures) ?? defaults.autoUpdateSignatures
        updateSchedule = try values.decodeIfPresent(ScanSchedule.self, forKey: .updateSchedule) ?? defaults.updateSchedule
        monitoredDirectories = try values.decodeIfPresent([String].self, forKey: .monitoredDirectories) ?? defaults.monitoredDirectories
        monitoringEnabled = try values.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? defaults.monitoringEnabled
        batchScanIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .batchScanIntervalMinutes) ?? defaults.batchScanIntervalMinutes
        batchScanFileThreshold = try values.decodeIfPresent(Int.self, forKey: .batchScanFileThreshold) ?? defaults.batchScanFileThreshold
        showNotifications = try values.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? defaults.showNotifications
        playSoundOnDetection = try values.decodeIfPresent(Bool.self, forKey: .playSoundOnDetection) ?? defaults.playSoundOnDetection
        showPerformanceStats = try values.decodeIfPresent(Bool.self, forKey: .showPerformanceStats) ?? defaults.showPerformanceStats
        pauseOnBattery = try values.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? defaults.pauseOnBattery
        lowImpactMode = try values.decodeIfPresent(Bool.self, forKey: .lowImpactMode) ?? defaults.lowImpactMode
        autoScanDownloads = try values.decodeIfPresent(Bool.self, forKey: .autoScanDownloads) ?? defaults.autoScanDownloads
        notifyOnCleanFiles = try values.decodeIfPresent(Bool.self, forKey: .notifyOnCleanFiles) ?? defaults.notifyOnCleanFiles
        scanWhenIdle = try values.decodeIfPresent(Bool.self, forKey: .scanWhenIdle) ?? defaults.scanWhenIdle
        idleTimeoutMinutes = try values.decodeIfPresent(Int.self, forKey: .idleTimeoutMinutes) ?? defaults.idleTimeoutMinutes
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        hideFromDock = try values.decodeIfPresent(Bool.self, forKey: .hideFromDock) ?? defaults.hideFromDock
        scannerBackend = try values.decodeIfPresent(ScannerBackend.self, forKey: .scannerBackend) ?? defaults.scannerBackend
        clamdSettings = try values.decodeIfPresent(ClamdSettings.self, forKey: .clamdSettings) ?? defaults.clamdSettings
    }

    static var `default`: AppSettings {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let isAppleSilicon = ProcessInfo.processInfo.machineHardwareName == "arm64"
        let brewPrefix = isAppleSilicon ? "/opt/homebrew" : "/usr/local"

        return AppSettings(
            clamScanPath: "\(brewPrefix)/bin/clamscan",
            freshclamPath: "\(brewPrefix)/bin/freshclam",
            configDirectory: "\(brewPrefix)/etc/clamav",
            signatureDirectory: "\(brewPrefix)/var/lib/clamav",
            quarantineDirectory: "\(homeDir)/.clamav-quarantine",
            defaultExclusions: DefaultExclusions.paths,
            customExclusions: [],
            autoUpdateSignatures: true,
            updateSchedule: .daily9am,
            monitoredDirectories: [
                "\(homeDir)/Downloads",
                "\(homeDir)/Desktop"
            ],
            monitoringEnabled: false,
            batchScanIntervalMinutes: 5,
            batchScanFileThreshold: 10,
            showNotifications: true,
            playSoundOnDetection: true,
            showPerformanceStats: true,
            pauseOnBattery: true,
            lowImpactMode: false,
            autoScanDownloads: true,
            notifyOnCleanFiles: false,
            scanWhenIdle: true,
            idleTimeoutMinutes: 30,
            launchAtLogin: false,
            hideFromDock: false,
            scannerBackend: .clamscan,
            clamdSettings: ClamdSettings(
                clamdScanPath: "\(brewPrefix)/bin/clamdscan",
                socketPath: "\(brewPrefix)/var/run/clamav/clamd.sock",
                isEnabled: false
            )
        )
    }
}

enum ScannerBackend: String, Codable, CaseIterable {
    case clamscan
    case clamdscan
}

struct ClamdSettings: Codable, Equatable {
    var clamdScanPath: String
    var socketPath: String
    var isEnabled: Bool

    static var `default`: ClamdSettings {
        let isAppleSilicon = ProcessInfo.processInfo.machineHardwareName == "arm64"
        let brewPrefix = isAppleSilicon ? "/opt/homebrew" : "/usr/local"
        return ClamdSettings(
            clamdScanPath: "\(brewPrefix)/bin/clamdscan",
            socketPath: "\(brewPrefix)/var/run/clamav/clamd.sock",
            isEnabled: false
        )
    }
}

struct DefaultExclusions {
    static let paths: [String] = [
        "node_modules",
        ".git",
        "Caches",
        "DerivedData",
        "*.xcodeproj/xcuserdata",
        "__pycache__",
        ".DS_Store",
        "*.pyc",
        ".npm",
        ".yarn",
        "vendor/bundle",
        ".gradle",
        "build",
        ".idea",
        ".vscode"
    ]
}

extension ProcessInfo {
    var machineHardwareName: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
        return String(data: data, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? "unknown"
    }
}
