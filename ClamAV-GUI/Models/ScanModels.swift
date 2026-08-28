import Foundation

struct ScanProgress: Equatable {
    var status: ScanStatus
    var currentFile: String?
    var filesScanned: Int
    var infectedCount: Int
    var startTime: Date
    var estimatedTimeRemaining: TimeInterval?
    var bytesScanned: Int64
    var estimatedTotalFiles: Int?
    var estimatedTotalBytes: Int64?

    init(
        status: ScanStatus,
        currentFile: String?,
        filesScanned: Int,
        infectedCount: Int,
        startTime: Date,
        estimatedTimeRemaining: TimeInterval? = nil,
        bytesScanned: Int64 = 0,
        estimatedTotalFiles: Int? = nil,
        estimatedTotalBytes: Int64? = nil
    ) {
        self.status = status
        self.currentFile = currentFile
        self.filesScanned = filesScanned
        self.infectedCount = infectedCount
        self.startTime = startTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.bytesScanned = bytesScanned
        self.estimatedTotalFiles = estimatedTotalFiles
        self.estimatedTotalBytes = estimatedTotalBytes
    }

    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    var fractionComplete: Double? {
        if let estimatedTotalBytes, estimatedTotalBytes > 0 {
            return min(1, max(0, Double(bytesScanned) / Double(estimatedTotalBytes)))
        }
        if let estimatedTotalFiles, estimatedTotalFiles > 0 {
            return min(1, max(0, Double(filesScanned) / Double(estimatedTotalFiles)))
        }
        return nil
    }

    var percentComplete: Int? {
        fractionComplete.map { Int(($0 * 100).rounded(.down)) }
    }
}

enum ScanStatus: String, Equatable {
    case preparing = "Preparing..."
    case scanning = "Scanning"
    case paused = "Paused"
    case completing = "Completing..."
    case completed = "Completed"
    case cancelled = "Cancelled"
    case failed = "Failed"
}

struct ScanResult: Identifiable, Equatable {
    let id: UUID
    let path: String
    let threatName: String
    let severity: ThreatSeverity
    let actionTaken: ScanAction
    let timestamp: Date

    init(path: String, threatName: String, severity: ThreatSeverity = .medium, actionTaken: ScanAction = .reported) {
        self.id = UUID()
        self.path = path
        self.threatName = threatName
        self.severity = severity
        self.actionTaken = actionTaken
        self.timestamp = Date()
    }
}

enum ThreatSeverity: String, CaseIterable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    var color: String {
        switch self {
        case .low: return "yellow"
        case .medium: return "orange"
        case .high: return "red"
        case .critical: return "purple"
        }
    }
}

enum ScanAction: String, Codable {
    case reported = "Reported"
    case quarantined = "Quarantined"
    case deleted = "Deleted"
    case ignored = "Ignored"
}

struct ScanReport: Equatable {
    let startTime: Date
    let endTime: Date
    let filesScanned: Int
    let infectedFiles: [ScanResult]
    let errors: [String]
    let scanPaths: [URL]
    let exitCode: Int32
    let completionState: ScanCompletionState

    init(
        startTime: Date,
        endTime: Date,
        filesScanned: Int,
        infectedFiles: [ScanResult],
        errors: [String],
        scanPaths: [URL],
        exitCode: Int32 = 0,
        completionState: ScanCompletionState? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.filesScanned = filesScanned
        self.infectedFiles = infectedFiles
        self.errors = errors
        self.scanPaths = scanPaths
        self.exitCode = exitCode
        self.completionState = completionState ?? ClamAVRunner.completionState(
            forExitCode: exitCode,
            infectedCount: infectedFiles.count
        )
    }

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    var isClean: Bool {
        infectedFiles.isEmpty
    }

    static func == (lhs: ScanReport, rhs: ScanReport) -> Bool {
        lhs.startTime == rhs.startTime &&
        lhs.endTime == rhs.endTime &&
        lhs.filesScanned == rhs.filesScanned &&
        lhs.infectedFiles == rhs.infectedFiles &&
        lhs.exitCode == rhs.exitCode &&
        lhs.completionState == rhs.completionState
    }
}

enum ScanCompletionState: String, Codable, Equatable {
    case success
    case infectedFound
    case scanError
    case cancelled
}

struct ScanOptions: Codable, Equatable {
    var recursive: Bool
    var followSymlinks: Bool
    var scanArchives: Bool
    var maxFileSize: Int // MB
    var maxScanSize: Int // MB
    var maxRecursionDepth: Int
    var maxScanTime: Int // seconds, 0 means ClamAV default
    var heuristicAlerts: Bool
    var alertEncryptedArchives: Bool
    var crossFileSystem: Bool
    var reportOnlyInfected: Bool
    var databasePath: String?
    var detectPUA: Bool
    var quarantineInfected: Bool
    var excludedPaths: [String]

    init(
        recursive: Bool,
        followSymlinks: Bool,
        scanArchives: Bool,
        maxFileSize: Int,
        maxScanSize: Int,
        maxRecursionDepth: Int,
        maxScanTime: Int,
        heuristicAlerts: Bool,
        alertEncryptedArchives: Bool,
        crossFileSystem: Bool,
        reportOnlyInfected: Bool,
        databasePath: String?,
        detectPUA: Bool,
        quarantineInfected: Bool,
        excludedPaths: [String]
    ) {
        self.recursive = recursive
        self.followSymlinks = followSymlinks
        self.scanArchives = scanArchives
        self.maxFileSize = maxFileSize
        self.maxScanSize = maxScanSize
        self.maxRecursionDepth = maxRecursionDepth
        self.maxScanTime = maxScanTime
        self.heuristicAlerts = heuristicAlerts
        self.alertEncryptedArchives = alertEncryptedArchives
        self.crossFileSystem = crossFileSystem
        self.reportOnlyInfected = reportOnlyInfected
        self.databasePath = databasePath
        self.detectPUA = detectPUA
        self.quarantineInfected = quarantineInfected
        self.excludedPaths = excludedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case recursive
        case followSymlinks
        case scanArchives
        case maxFileSize
        case maxScanSize
        case maxRecursionDepth
        case maxScanTime
        case heuristicAlerts
        case alertEncryptedArchives
        case crossFileSystem
        case reportOnlyInfected
        case databasePath
        case detectPUA
        case quarantineInfected
        case excludedPaths
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScanOptions.default

        recursive = try values.decodeIfPresent(Bool.self, forKey: .recursive) ?? defaults.recursive
        followSymlinks = try values.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? defaults.followSymlinks
        scanArchives = try values.decodeIfPresent(Bool.self, forKey: .scanArchives) ?? defaults.scanArchives
        maxFileSize = try values.decodeIfPresent(Int.self, forKey: .maxFileSize) ?? defaults.maxFileSize
        maxScanSize = try values.decodeIfPresent(Int.self, forKey: .maxScanSize) ?? defaults.maxScanSize
        maxRecursionDepth = try values.decodeIfPresent(Int.self, forKey: .maxRecursionDepth) ?? defaults.maxRecursionDepth
        maxScanTime = try values.decodeIfPresent(Int.self, forKey: .maxScanTime) ?? defaults.maxScanTime
        heuristicAlerts = try values.decodeIfPresent(Bool.self, forKey: .heuristicAlerts) ?? defaults.heuristicAlerts
        alertEncryptedArchives = try values.decodeIfPresent(Bool.self, forKey: .alertEncryptedArchives) ?? defaults.alertEncryptedArchives
        crossFileSystem = try values.decodeIfPresent(Bool.self, forKey: .crossFileSystem) ?? defaults.crossFileSystem
        reportOnlyInfected = try values.decodeIfPresent(Bool.self, forKey: .reportOnlyInfected) ?? defaults.reportOnlyInfected
        databasePath = try values.decodeIfPresent(String.self, forKey: .databasePath) ?? defaults.databasePath
        detectPUA = try values.decodeIfPresent(Bool.self, forKey: .detectPUA) ?? defaults.detectPUA
        quarantineInfected = try values.decodeIfPresent(Bool.self, forKey: .quarantineInfected) ?? defaults.quarantineInfected
        excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? defaults.excludedPaths
    }

    static var `default`: ScanOptions {
        ScanOptions(
            recursive: true,
            followSymlinks: false,
            scanArchives: true,
            maxFileSize: 100,
            maxScanSize: 400,
            maxRecursionDepth: 15,
            maxScanTime: 0,
            heuristicAlerts: true,
            alertEncryptedArchives: false,
            crossFileSystem: true,
            reportOnlyInfected: false,
            databasePath: nil,
            detectPUA: false,
            quarantineInfected: true,
            excludedPaths: DefaultExclusions.paths
        )
    }
}

enum ScanSource: String, Codable, Equatable {
    case manual
    case quick
    case custom
    case scheduled
    case finder
    case realtime
    case download
    case idle
}

enum ScanType: String, Codable, Equatable, CaseIterable {
    case quick = "Quick"
    case custom = "Custom"
    case full = "Full"
    case scheduled = "Scheduled"
    case realtime = "Real-time"
}

struct ScanRequest: Equatable {
    let source: ScanSource
    let paths: [URL]
    let options: ScanOptions
    let jobID: UUID?

    init(source: ScanSource, paths: [URL], options: ScanOptions, jobID: UUID? = nil) {
        self.source = source
        self.paths = paths
        self.options = options
        self.jobID = jobID
    }
}

enum ScanOutcome: Equatable {
    case completed(ScanReport)
    case failed(String)
    case cancelled
    case skippedAlreadyRunning(active: ScanSource?)

    var report: ScanReport? {
        if case .completed(let report) = self { return report }
        return nil
    }

    var errorMessage: String? {
        switch self {
        case .completed:
            return nil
        case .failed(let message):
            return message
        case .cancelled:
            return "Scan was cancelled."
        case .skippedAlreadyRunning(let active):
            if let active {
                return "Skipped because a \(active.rawValue) scan is already running."
            }
            return "Skipped because another scan is already running."
        }
    }

    var scheduledResultMessage: String {
        switch self {
        case .completed(let report):
            return report.infectedFiles.isEmpty ? "success" : "success: \(report.infectedFiles.count) threat(s) found"
        case .failed(let message):
            return "failed: \(message)"
        case .cancelled:
            return "cancelled"
        case .skippedAlreadyRunning:
            return "skippedAlreadyRunning"
        }
    }
}

struct ScanJob: Identifiable, Codable {
    let id: UUID
    var name: String
    var paths: [String]
    var options: ScanOptions
    var schedule: ScanSchedule
    var isEnabled: Bool
    var lastRun: Date?
    var lastResult: String?

    init(name: String, paths: [String], options: ScanOptions = .default, schedule: ScanSchedule) {
        self.id = UUID()
        self.name = name
        self.paths = paths
        self.options = options
        self.schedule = schedule
        self.isEnabled = true
        self.lastRun = nil
        self.lastResult = nil
    }
}

struct ScanSchedule: Codable, Equatable {
    var frequency: ScheduleFrequency
    var time: DateComponents
    var dayOfWeek: Int? // 1-7, Sunday = 1
    var dayOfMonth: Int? // 1-31

    static var daily9am: ScanSchedule {
        ScanSchedule(frequency: .daily, time: DateComponents(hour: 9, minute: 0))
    }
}

enum ScheduleFrequency: String, Codable, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
}
