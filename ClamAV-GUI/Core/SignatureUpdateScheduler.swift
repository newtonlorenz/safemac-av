import Foundation

protocol SignatureUpdateScheduling: AnyObject {
    func reconcile(enabled: Bool, schedule: ScanSchedule) throws
}

final class SignatureUpdateScheduler: SignatureUpdateScheduling {
    typealias DataWriter = (Data, URL, Data.WritingOptions) throws -> Void
    typealias LaunchctlRunner = (String, URL) throws -> Void

    static let label = "com.newtonlorenz.ClamAV-GUI.signature-update"

    private let fileManager: FileManager
    private let launchAgentsDirectory: URL
    private let applicationBundlePath: String
    private let dataWriter: DataWriter
    private let launchctlRunner: LaunchctlRunner

    init(
        fileManager: FileManager = .default,
        launchAgentsDirectory: URL? = nil,
        applicationBundlePath: String = Bundle.main.bundlePath,
        launchctlExecutableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        dataWriter: @escaping DataWriter = { data, url, options in
            try data.write(to: url, options: options)
        },
        launchctlRunner: LaunchctlRunner? = nil
    ) {
        self.fileManager = fileManager
        self.launchAgentsDirectory = launchAgentsDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.applicationBundlePath = applicationBundlePath
        self.dataWriter = dataWriter
        self.launchctlRunner = launchctlRunner ?? { command, url in
            try Self.runLaunchctl(command, for: url, executableURL: launchctlExecutableURL)
        }
    }

    func reconcile(enabled: Bool, schedule: ScanSchedule) throws {
        let url = launchAgentURL
        let snapshot = try snapshot(at: url)

        guard enabled else {
            guard snapshot != nil else { return }
            try unload(at: url)
            do {
                try fileManager.removeItem(at: url)
            } catch {
                restore(snapshot, at: url, reload: true)
                throw error
            }
            return
        }

        let replacement = try launchAgentData(for: schedule)
        var replacementWritten = false
        var replacementLoadAttempted = false

        do {
            if snapshot != nil {
                try unload(at: url)
            }
            try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            try dataWriter(replacement, url, .atomic)
            replacementWritten = true
            replacementLoadAttempted = true
            try load(at: url)
        } catch {
            if replacementLoadAttempted {
                try? unload(at: url)
            }
            if snapshot != nil || replacementWritten {
                restore(snapshot, at: url, reload: snapshot != nil)
            }
            throw error
        }
    }

    private var launchAgentURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    private func launchAgentData(for schedule: ScanSchedule) throws -> Data {
        let calendar = try calendarInterval(for: schedule)
        let executablePath = URL(fileURLWithPath: applicationBundlePath)
            .appendingPathComponent("Contents/MacOS/ClamAV-GUI")
            .path
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executablePath, "--scheduled-signature-update"],
            "StartCalendarInterval": calendar,
            "RunAtLoad": false
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private func calendarInterval(for schedule: ScanSchedule) throws -> [String: Int] {
        let hour = schedule.time.hour ?? 9
        let minute = schedule.time.minute ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw SignatureUpdateSchedulerError.invalidSchedule
        }

        var interval = ["Hour": hour, "Minute": minute]
        switch schedule.frequency {
        case .daily:
            break
        case .weekly:
            guard let weekday = schedule.dayOfWeek, (1...7).contains(weekday) else {
                throw SignatureUpdateSchedulerError.invalidSchedule
            }
            interval["Weekday"] = weekday
        case .monthly:
            guard let day = schedule.dayOfMonth, (1...31).contains(day) else {
                throw SignatureUpdateSchedulerError.invalidSchedule
            }
            interval["Day"] = day
        }
        return interval
    }

    private func snapshot(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func restore(_ snapshot: Data?, at url: URL, reload: Bool) {
        do {
            if let snapshot {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try dataWriter(snapshot, url, .atomic)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            NSLog("Unable to restore automatic signature update schedule: %@", error.localizedDescription)
        }

        if reload {
            do {
                try load(at: url)
            } catch {
                NSLog("Unable to reload previous automatic signature update schedule: %@", error.localizedDescription)
            }
        }
    }

    private func load(at url: URL) throws {
        try launchctlRunner("load", url)
    }

    private func unload(at url: URL) throws {
        try launchctlRunner("unload", url)
    }

    private static func runLaunchctl(_ command: String, for url: URL, executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [command, url.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SignatureUpdateSchedulerError.launchctlFailed(
                command: command,
                status: process.terminationStatus
            )
        }
    }
}

enum SignatureUpdateSchedulerError: LocalizedError {
    case invalidSchedule
    case launchctlFailed(command: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSchedule:
            return "The automatic signature update schedule is invalid."
        case .launchctlFailed(let command, let status):
            return "launchctl \(command) failed with exit status \(status)."
        }
    }
}
