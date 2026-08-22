import Foundation

protocol ScanSchedulerProtocol {
    func createScheduledScan(_ job: ScanJob) throws
    func updateScheduledScan(_ job: ScanJob) throws
    func removeScheduledScan(_ job: ScanJob) throws
    func listScheduledScans() -> [ScanJob]
    func loadScheduledScans() throws -> [ScanJob]
    func getNextRunTime(for job: ScanJob) -> Date?
}

final class ScanScheduler: ScanSchedulerProtocol {
    typealias DataWriter = (Data, URL, Data.WritingOptions) throws -> Void
    typealias LaunchctlRunner = (String, URL) throws -> Void
    typealias LaunchAgentLoadedStatusProvider = (String) throws -> Bool

    private let fileManager: FileManager
    private let launchAgentsDir: URL
    private let jobsStorageURL: URL
    private let legacyJobsStorageURL: URL?
    private let applicationBundlePath: String
    private let dataWriter: DataWriter
    private let launchctlRunner: LaunchctlRunner
    private let launchAgentLoadedStatusProvider: LaunchAgentLoadedStatusProvider
    private static let bundleIdentifier = "com.newtonlorenz.SafeMacAV"
    private static let legacyBundleIdentifier = "com.newtonlorenz.ClamAV-GUI"

    init(
        fileManager: FileManager = .default,
        launchAgentsDirectory: URL? = nil,
        jobsStorageURL: URL? = nil,
        legacyJobsStorageURL: URL? = nil,
        applicationBundlePath: String = Bundle.main.bundlePath,
        launchctlExecutableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        userID: uid_t = getuid(),
        dataWriter: @escaping DataWriter = { data, url, options in
            try data.write(to: url, options: options)
        },
        launchAgentLoadedStatusProvider: LaunchAgentLoadedStatusProvider? = nil,
        launchctlRunner: LaunchctlRunner? = nil
    ) {
        self.fileManager = fileManager
        let homeDir = fileManager.homeDirectoryForCurrentUser
        self.launchAgentsDir = launchAgentsDirectory
            ?? homeDir.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support", isDirectory: true)
        let appDir = appSupport.appendingPathComponent("SafeMac AV")
        self.jobsStorageURL = jobsStorageURL
            ?? appDir.appendingPathComponent("scheduled_jobs.json")
        self.legacyJobsStorageURL = legacyJobsStorageURL
            ?? (jobsStorageURL == nil
                ? appSupport
                    .appendingPathComponent("ClamAV-GUI", isDirectory: true)
                    .appendingPathComponent("scheduled_jobs.json")
                : nil)
        self.applicationBundlePath = applicationBundlePath
        self.dataWriter = dataWriter
        self.launchctlRunner = launchctlRunner ?? { command, url in
            try Self.runLaunchctl(command, for: url, executableURL: launchctlExecutableURL)
        }
        self.launchAgentLoadedStatusProvider = launchAgentLoadedStatusProvider ?? { label in
            try Self.isLaunchAgentLoaded(
                label: label,
                userID: userID,
                executableURL: launchctlExecutableURL
            )
        }
    }

    func createScheduledScan(_ job: ScanJob) throws {
        let jobs = try loadStoredJobsStrictly()
        let updatedJobs = replacing(job, in: jobs)
        try apply(job: job, storedJobs: updatedJobs, installLaunchAgent: job.isEnabled)
    }

    func updateScheduledScan(_ job: ScanJob) throws {
        let jobs = try loadStoredJobsStrictly()
        let updatedJobs = replacing(job, in: jobs)
        try apply(job: job, storedJobs: updatedJobs, installLaunchAgent: job.isEnabled)
    }

    func removeScheduledScan(_ job: ScanJob) throws {
        let jobs = try loadStoredJobsStrictly()
        let plistURL = launchAgentURL(for: job)
        let legacyPlistURL = legacyLaunchAgentURL(for: job)
        let snapshot = try launchAgentSnapshot(at: plistURL)
        let legacySnapshot = try launchAgentSnapshot(at: legacyPlistURL)
        var unloadedExistingAgent = false
        var unloadedLegacyAgent = false

        do {
            if snapshot != nil {
                try unloadLaunchAgent(at: plistURL)
                unloadedExistingAgent = true
                try fileManager.removeItem(at: plistURL)
            }
            if legacySnapshot != nil {
                try unloadLaunchAgent(at: legacyPlistURL)
                unloadedLegacyAgent = true
                try fileManager.removeItem(at: legacyPlistURL)
            }

            let updatedJobs = jobs.filter { $0.id != job.id }
            try saveStoredJobs(updatedJobs)
        } catch {
            if unloadedExistingAgent {
                rollbackLaunchAgent(at: plistURL, to: snapshot, unloadCurrentAgent: false)
            }
            if unloadedLegacyAgent {
                rollbackLaunchAgent(at: legacyPlistURL, to: legacySnapshot, unloadCurrentAgent: false)
            }
            throw error
        }
    }

    func listScheduledScans() -> [ScanJob] {
        return loadStoredJobs()
    }

    func loadScheduledScans() throws -> [ScanJob] {
        try loadStoredJobsStrictly()
    }

    func migrateLegacyState() throws {
        _ = try loadStoredJobsStrictly()
    }

    func scheduledScan(jobID: UUID) -> ScanJob? {
        loadStoredJobs().first { $0.id == jobID }
    }

    func markScheduledScanRun(jobID: UUID, result: String, at date: Date) {
        do {
            let jobs = try loadStoredJobsStrictly()
            guard let existingJob = jobs.first(where: { $0.id == jobID }) else { return }
            var updatedJob = existingJob
            updatedJob.lastRun = date
            updatedJob.lastResult = result
            try saveStoredJobs(replacing(updatedJob, in: jobs))
        } catch {
            NSLog("Unable to persist scheduled scan result: %@", error.localizedDescription)
        }
    }

    func launchArguments(for job: ScanJob, scannerPath: String) -> [String] {
        [
            scannerPath,
            "--scheduled-scan",
            "--job-id",
            job.id.uuidString
        ]
    }

    func getNextRunTime(for job: ScanJob) -> Date? {
        guard job.isEnabled else { return nil }

        let calendar = Calendar.current
        var components = job.schedule.time
        let now = Date()

        switch job.schedule.frequency {
        case .daily:
            components.year = calendar.component(.year, from: now)
            components.month = calendar.component(.month, from: now)
            components.day = calendar.component(.day, from: now)

            if let date = calendar.date(from: components), date > now {
                return date
            }
            components.day = calendar.component(.day, from: now) + 1
            return calendar.date(from: components)

        case .weekly:
            guard let dayOfWeek = job.schedule.dayOfWeek else { return nil }
            components.weekday = dayOfWeek
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)

        case .monthly:
            guard let dayOfMonth = job.schedule.dayOfMonth else { return nil }
            components.day = dayOfMonth
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        }
    }

    private func launchAgentURL(for job: ScanJob) -> URL {
        let filename = "\(Self.bundleIdentifier).scan.\(job.id.uuidString).plist"
        return launchAgentsDir.appendingPathComponent(filename)
    }

    private func legacyLaunchAgentURL(for job: ScanJob) -> URL {
        let filename = "\(Self.legacyBundleIdentifier).scan.\(job.id.uuidString).plist"
        return launchAgentsDir.appendingPathComponent(filename)
    }

    private func launchAgentLabel(for job: ScanJob) -> String {
        "\(Self.bundleIdentifier).scan.\(job.id.uuidString)"
    }

    private func buildLaunchAgentPlist(for job: ScanJob) -> String {
        let label = "\(Self.bundleIdentifier).scan.\(job.id.uuidString)"
        let scannerPath = "\(applicationBundlePath)/Contents/MacOS/ClamAV-GUI"

        var calendarInterval = ""
        switch job.schedule.frequency {
        case .daily:
            calendarInterval = """
                <key>Hour</key>
                <integer>\(job.schedule.time.hour ?? 9)</integer>
                <key>Minute</key>
                <integer>\(job.schedule.time.minute ?? 0)</integer>
            """
        case .weekly:
            calendarInterval = """
                <key>Weekday</key>
                <integer>\(job.schedule.dayOfWeek ?? 1)</integer>
                <key>Hour</key>
                <integer>\(job.schedule.time.hour ?? 9)</integer>
                <key>Minute</key>
                <integer>\(job.schedule.time.minute ?? 0)</integer>
            """
        case .monthly:
            calendarInterval = """
                <key>Day</key>
                <integer>\(job.schedule.dayOfMonth ?? 1)</integer>
                <key>Hour</key>
                <integer>\(job.schedule.time.hour ?? 9)</integer>
                <key>Minute</key>
                <integer>\(job.schedule.time.minute ?? 0)</integer>
            """
        }

        let arguments = launchArguments(for: job, scannerPath: scannerPath)
            .map { "<string>\(Self.escapePlist($0))</string>" }
            .joined(separator: "\n                ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                \(arguments)
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                \(calendarInterval)
            </dict>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/tmp/clamav-gui-\(job.id.uuidString).log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/clamav-gui-\(job.id.uuidString).err</string>
        </dict>
        </plist>
        """
    }

    private static func escapePlist(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func apply(job: ScanJob, storedJobs: [ScanJob], installLaunchAgent: Bool) throws {
        let plistURL = launchAgentURL(for: job)
        let legacyPlistURL = legacyLaunchAgentURL(for: job)
        let snapshot = try launchAgentSnapshot(at: plistURL)
        let legacySnapshot = try launchAgentSnapshot(at: legacyPlistURL)
        var unloadedExistingAgent = false
        var unloadedLegacyAgent = false
        var attemptedReplacementLoad = false
        var loadedReplacementAgent = false

        do {
            if snapshot != nil {
                try unloadLaunchAgent(at: plistURL)
                unloadedExistingAgent = true
            }
            if legacySnapshot != nil {
                try unloadLaunchAgent(at: legacyPlistURL)
                unloadedLegacyAgent = true
            }

            if installLaunchAgent {
                try ensureDirectoryExists(at: launchAgentsDir)
                try writeLaunchAgent(for: job, to: plistURL)
                attemptedReplacementLoad = true
                try loadLaunchAgent(at: plistURL)
                loadedReplacementAgent = true
                if legacySnapshot != nil {
                    try fileManager.removeItem(at: legacyPlistURL)
                }
            } else if snapshot != nil {
                try fileManager.removeItem(at: plistURL)
            }
            if !installLaunchAgent, legacySnapshot != nil {
                try fileManager.removeItem(at: legacyPlistURL)
            }

            try saveStoredJobs(storedJobs)
        } catch {
            if unloadedExistingAgent || attemptedReplacementLoad || loadedReplacementAgent {
                rollbackLaunchAgent(
                    at: plistURL,
                    to: snapshot,
                    unloadCurrentAgent: attemptedReplacementLoad
                )
            } else if snapshot == nil, fileManager.fileExists(atPath: plistURL.path) {
                performRollbackStep("remove incomplete launch agent file") {
                    try fileManager.removeItem(at: plistURL)
                }
            }
            if unloadedLegacyAgent {
                rollbackLaunchAgent(
                    at: legacyPlistURL,
                    to: legacySnapshot,
                    unloadCurrentAgent: false
                )
            }
            throw error
        }
    }

    private func replacing(_ job: ScanJob, in jobs: [ScanJob]) -> [ScanJob] {
        jobs.filter { $0.id != job.id } + [job]
    }

    private func launchAgentSnapshot(at url: URL) throws -> Data? {
        guard SafeMacPersistenceMigration.pathExistsWithoutFollowingSymbolicLink(url) else {
            return nil
        }
        return try SafeMacPersistenceMigration.readOwnedRegularFile(at: url)
    }

    private func writeLaunchAgent(for job: ScanJob, to url: URL) throws {
        try dataWriter(Data(buildLaunchAgentPlist(for: job).utf8), url, .atomic)
    }

    private func rollbackLaunchAgent(at url: URL, to snapshot: Data?, unloadCurrentAgent: Bool) {
        if unloadCurrentAgent {
            performRollbackStep("unload replacement launch agent") {
                try unloadLaunchAgent(at: url)
            }
        }

        performRollbackStep("restore launch agent file") {
            if let snapshot {
                try ensureDirectoryExists(at: url.deletingLastPathComponent())
                try dataWriter(snapshot, url, .atomic)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        if snapshot != nil {
            performRollbackStep("reload previous launch agent") {
                try loadLaunchAgent(at: url)
            }
        }
    }

    private func performRollbackStep(_ description: String, operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            NSLog("Unable to %@ while rolling back scheduler update: %@", description, error.localizedDescription)
        }
    }

    private func loadLaunchAgent(at url: URL) throws {
        try launchctlRunner("load", url)
    }

    private func unloadLaunchAgent(at url: URL) throws {
        try launchctlRunner("unload", url)
    }

    private static func runLaunchctl(_ command: String, for url: URL, executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [command, url.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ScanSchedulerError.launchctlFailed(command: command, status: process.terminationStatus)
        }
    }

    private static func isLaunchAgentLoaded(
        label: String,
        userID: uid_t,
        executableURL: URL
    ) throws -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["print", "gui/\(userID)/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit else {
            throw ScanSchedulerError.launchctlFailed(
                command: "print",
                status: process.terminationStatus
            )
        }
        return try loadedState(forPrintStatus: process.terminationStatus)
    }

    static func loadedState(forPrintStatus status: Int32) throws -> Bool {
        if status == 0 { return true }
        if status == 3 || status == 113 { return false }
        throw ScanSchedulerError.launchctlFailed(command: "print", status: status)
    }

    private func loadStoredJobs() -> [ScanJob] {
        (try? loadStoredJobsStrictly()) ?? []
    }

    private func loadStoredJobsStrictly() throws -> [ScanJob] {
        if let legacyJobsStorageURL {
            try SafeMacPersistenceMigration.migrateFileIfNeeded(
                from: legacyJobsStorageURL,
                to: jobsStorageURL,
                fileManager: fileManager,
                validator: { _ = try JSONDecoder().decode([ScanJob].self, from: $0) }
            )
        }
        guard SafeMacPersistenceMigration.pathExistsWithoutFollowingSymbolicLink(jobsStorageURL) else {
            return []
        }
        let data = try SafeMacPersistenceMigration.readOwnedRegularFile(at: jobsStorageURL)
        let jobs = try JSONDecoder().decode([ScanJob].self, from: data)
        try migrateLegacyLaunchAgents(for: jobs)
        return jobs
    }

    private func migrateLegacyLaunchAgents(for jobs: [ScanJob]) throws {
        for job in jobs {
            let legacyURL = legacyLaunchAgentURL(for: job)
            guard let legacySnapshot = try launchAgentSnapshot(at: legacyURL) else { continue }
            let replacementURL = launchAgentURL(for: job)
            let replacementSnapshot = try launchAgentSnapshot(at: replacementURL)
            let replacementIsLoaded: Bool
            if job.isEnabled, replacementSnapshot != nil {
                replacementIsLoaded = try launchAgentLoadedStatusProvider(launchAgentLabel(for: job))
            } else {
                replacementIsLoaded = false
            }
            var replacementLoadAttempted = false

            do {
                try unloadLaunchAgent(at: legacyURL)
                if job.isEnabled, !replacementIsLoaded {
                    if replacementSnapshot == nil {
                        try ensureDirectoryExists(at: launchAgentsDir)
                        try writeLaunchAgent(for: job, to: replacementURL)
                    }
                    replacementLoadAttempted = true
                    try loadLaunchAgent(at: replacementURL)
                }
                try fileManager.removeItem(at: legacyURL)
            } catch {
                if replacementLoadAttempted {
                    performRollbackStep("unload migrated launch agent") {
                        try unloadLaunchAgent(at: replacementURL)
                    }
                }
                performRollbackStep("restore replacement launch agent") {
                    if let replacementSnapshot {
                        try dataWriter(replacementSnapshot, replacementURL, .atomic)
                    } else if fileManager.fileExists(atPath: replacementURL.path) {
                        try fileManager.removeItem(at: replacementURL)
                    }
                }
                performRollbackStep("restore legacy launch agent") {
                    try dataWriter(legacySnapshot, legacyURL, .atomic)
                    try loadLaunchAgent(at: legacyURL)
                }
                throw error
            }
        }
    }

    private func saveStoredJobs(_ jobs: [ScanJob]) throws {
        try ensureDirectoryExists(at: jobsStorageURL.deletingLastPathComponent())
        let data = try JSONEncoder().encode(jobs)
        try dataWriter(data, jobsStorageURL, .atomic)
    }

    private func ensureDirectoryExists(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum ScanSchedulerError: LocalizedError {
    case launchctlFailed(command: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let command, let status):
            return "launchctl \(command) failed with exit status \(status)."
        }
    }
}
