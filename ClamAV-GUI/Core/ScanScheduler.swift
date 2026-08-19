import Foundation

protocol ScanSchedulerProtocol {
    func createScheduledScan(_ job: ScanJob) throws
    func updateScheduledScan(_ job: ScanJob) throws
    func removeScheduledScan(_ job: ScanJob) throws
    func listScheduledScans() -> [ScanJob]
    func getNextRunTime(for job: ScanJob) -> Date?
}

final class ScanScheduler: ScanSchedulerProtocol {
    typealias DataWriter = (Data, URL, Data.WritingOptions) throws -> Void
    typealias LaunchctlRunner = (String, URL) throws -> Void

    private let fileManager: FileManager
    private let launchAgentsDir: URL
    private let jobsStorageURL: URL
    private let applicationBundlePath: String
    private let dataWriter: DataWriter
    private let launchctlRunner: LaunchctlRunner
    private let bundleIdentifier = "com.newtonlorenz.ClamAV-GUI"

    init(
        fileManager: FileManager = .default,
        launchAgentsDirectory: URL? = nil,
        jobsStorageURL: URL? = nil,
        applicationBundlePath: String = Bundle.main.bundlePath,
        launchctlExecutableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        dataWriter: @escaping DataWriter = { data, url, options in
            try data.write(to: url, options: options)
        },
        launchctlRunner: LaunchctlRunner? = nil
    ) {
        self.fileManager = fileManager
        let homeDir = fileManager.homeDirectoryForCurrentUser
        self.launchAgentsDir = launchAgentsDirectory
            ?? homeDir.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support", isDirectory: true)
        let appDir = appSupport.appendingPathComponent("ClamAV-GUI")
        self.jobsStorageURL = jobsStorageURL
            ?? appDir.appendingPathComponent("scheduled_jobs.json")
        self.applicationBundlePath = applicationBundlePath
        self.dataWriter = dataWriter
        self.launchctlRunner = launchctlRunner ?? { command, url in
            try Self.runLaunchctl(command, for: url, executableURL: launchctlExecutableURL)
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
        let snapshot = try launchAgentSnapshot(at: plistURL)
        var unloadedExistingAgent = false

        do {
            if snapshot != nil {
                try unloadLaunchAgent(at: plistURL)
                unloadedExistingAgent = true
                try fileManager.removeItem(at: plistURL)
            }

            let updatedJobs = jobs.filter { $0.id != job.id }
            try saveStoredJobs(updatedJobs)
        } catch {
            if unloadedExistingAgent {
                rollbackLaunchAgent(at: plistURL, to: snapshot, unloadCurrentAgent: false)
            }
            throw error
        }
    }

    func listScheduledScans() -> [ScanJob] {
        return loadStoredJobs()
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
        let filename = "\(bundleIdentifier).scan.\(job.id.uuidString).plist"
        return launchAgentsDir.appendingPathComponent(filename)
    }

    private func buildLaunchAgentPlist(for job: ScanJob) -> String {
        let label = "\(bundleIdentifier).scan.\(job.id.uuidString)"
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
        let snapshot = try launchAgentSnapshot(at: plistURL)
        var unloadedExistingAgent = false
        var attemptedReplacementLoad = false
        var loadedReplacementAgent = false

        do {
            if snapshot != nil {
                try unloadLaunchAgent(at: plistURL)
                unloadedExistingAgent = true
            }

            if installLaunchAgent {
                try ensureDirectoryExists(at: launchAgentsDir)
                try writeLaunchAgent(for: job, to: plistURL)
                attemptedReplacementLoad = true
                try loadLaunchAgent(at: plistURL)
                loadedReplacementAgent = true
            } else if snapshot != nil {
                try fileManager.removeItem(at: plistURL)
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
            throw error
        }
    }

    private func replacing(_ job: ScanJob, in jobs: [ScanJob]) -> [ScanJob] {
        jobs.filter { $0.id != job.id } + [job]
    }

    private func launchAgentSnapshot(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
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

    private func loadStoredJobs() -> [ScanJob] {
        (try? loadStoredJobsStrictly()) ?? []
    }

    private func loadStoredJobsStrictly() throws -> [ScanJob] {
        guard fileManager.fileExists(atPath: jobsStorageURL.path) else { return [] }
        let data = try Data(contentsOf: jobsStorageURL)
        return try JSONDecoder().decode([ScanJob].self, from: data)
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
