import Foundation

protocol SignatureUpdateSchedulerProtocol {
    func install(schedule: ScanSchedule) throws
    func remove() throws
    func launchArguments(executablePath: String) -> [String]
}

enum SignatureUpdateSchedulerFactory {
    static func defaultScheduler() -> any SignatureUpdateSchedulerProtocol {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return NoopSignatureUpdateScheduler()
        }
        return SignatureUpdateScheduler()
    }
}

private struct NoopSignatureUpdateScheduler: SignatureUpdateSchedulerProtocol {
    func install(schedule: ScanSchedule) throws {}
    func remove() throws {}
    func launchArguments(executablePath: String) -> [String] {
        [executablePath, "--update-signatures"]
    }
}

final class SignatureUpdateScheduler: SignatureUpdateSchedulerProtocol {
    typealias DataWriter = (Data, URL, Data.WritingOptions) throws -> Void
    typealias LaunchctlRunner = ([String]) throws -> Void

    private let fileManager: FileManager
    private let launchAgentsDir: URL
    private let appBundleURL: URL
    private let dataWriter: DataWriter
    private let launchctlRunner: LaunchctlRunner
    private let label = "com.newtonlorenz.ClamAV-GUI.signature-update"

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        appBundleURL: URL = Bundle.main.bundleURL,
        dataWriter: @escaping DataWriter = { data, url, options in
            try data.write(to: url, options: options)
        },
        launchctlRunner: LaunchctlRunner? = nil
    ) {
        self.fileManager = fileManager
        let homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.launchAgentsDir = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        self.appBundleURL = appBundleURL
        self.dataWriter = dataWriter
        self.launchctlRunner = launchctlRunner ?? Self.runLaunchctl(arguments:)
    }

    func install(schedule: ScanSchedule) throws {
        try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plistURL = launchAgentURL
        let snapshot = try snapshot(at: plistURL)
        let plistData = Data(buildLaunchAgentPlist(schedule: schedule).utf8)
        var replacementWritten = false

        do {
            if snapshot != nil {
                try? bootout(plistURL: plistURL)
            }

            try dataWriter(plistData, plistURL, .atomic)
            replacementWritten = true
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
            try bootstrap(plistURL: plistURL)
        } catch {
            if replacementWritten {
                try? bootout(plistURL: plistURL)
            }
            restore(snapshot, at: plistURL)
            throw error
        }
    }

    func remove() throws {
        let plistURL = launchAgentURL
        let snapshot = try snapshot(at: plistURL)
        guard snapshot != nil else { return }

        do {
            try? bootout(plistURL: plistURL)
            try fileManager.removeItem(at: plistURL)
        } catch {
            restore(snapshot, at: plistURL)
            throw error
        }
    }

    func launchArguments(executablePath: String) -> [String] {
        [executablePath, "--update-signatures"]
    }

    func buildLaunchAgentPlist(schedule: ScanSchedule) -> String {
        let executablePath = appBundleURL
            .appendingPathComponent("Contents/MacOS/ClamAV-GUI")
            .path
        let arguments = launchArguments(executablePath: executablePath)
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
                \(Self.calendarInterval(for: schedule))
            </dict>
            <key>RunAtLoad</key>
            <false/>
        </dict>
        </plist>
        """
    }

    private var launchAgentURL: URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    private func bootstrap(plistURL: URL) throws {
        try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func bootout(plistURL: URL) throws {
        try runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
    }

    private func runLaunchctl(arguments: [String]) throws {
        try launchctlRunner(arguments)
    }

    private static func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SignatureUpdateSchedulerError.launchctlFailed(status: process.terminationStatus)
        }
    }

    private func snapshot(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func restore(_ snapshot: Data?, at url: URL) {
        do {
            if let snapshot {
                try dataWriter(snapshot, url, .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                try? bootstrap(plistURL: url)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            NSLog("Unable to restore automatic signature update schedule: %@", error.localizedDescription)
        }
    }

    private static func calendarInterval(for schedule: ScanSchedule) -> String {
        switch schedule.frequency {
        case .daily:
            return """
                <key>Hour</key>
                <integer>\(schedule.time.hour ?? 9)</integer>
                <key>Minute</key>
                <integer>\(schedule.time.minute ?? 0)</integer>
            """
        case .weekly:
            return """
                <key>Weekday</key>
                <integer>\(schedule.dayOfWeek ?? 1)</integer>
                <key>Hour</key>
                <integer>\(schedule.time.hour ?? 9)</integer>
                <key>Minute</key>
                <integer>\(schedule.time.minute ?? 0)</integer>
            """
        case .monthly:
            return """
                <key>Day</key>
                <integer>\(schedule.dayOfMonth ?? 1)</integer>
                <key>Hour</key>
                <integer>\(schedule.time.hour ?? 9)</integer>
                <key>Minute</key>
                <integer>\(schedule.time.minute ?? 0)</integer>
            """
        }
    }

    private static func escapePlist(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum SignatureUpdateSchedulerError: LocalizedError {
    case launchctlFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let status):
            return "launchctl failed with status \(status)"
        }
    }
}
