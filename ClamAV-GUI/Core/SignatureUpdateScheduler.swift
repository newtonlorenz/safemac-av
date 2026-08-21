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
    private let fileManager: FileManager
    private let launchAgentsDir: URL
    private let appBundleURL: URL
    private let label = "com.newtonlorenz.ClamAV-GUI.signature-update"

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        appBundleURL: URL = Bundle.main.bundleURL
    ) {
        self.fileManager = fileManager
        let homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.launchAgentsDir = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        self.appBundleURL = appBundleURL
    }

    func install(schedule: ScanSchedule) throws {
        try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plistURL = launchAgentURL
        let temporaryURL = plistURL.appendingPathExtension("tmp")
        let plistContent = buildLaunchAgentPlist(schedule: schedule)

        try plistContent.write(to: temporaryURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryURL.path)

        if fileManager.fileExists(atPath: plistURL.path) {
            _ = try? bootout(plistURL: plistURL)
            try fileManager.removeItem(at: plistURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: plistURL)
        try bootstrap(plistURL: plistURL)
    }

    func remove() throws {
        let plistURL = launchAgentURL
        guard fileManager.fileExists(atPath: plistURL.path) else { return }

        _ = try? bootout(plistURL: plistURL)
        try fileManager.removeItem(at: plistURL)
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
            <key>StandardOutPath</key>
            <string>/tmp/clamav-gui-signature-update.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/clamav-gui-signature-update.err</string>
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SignatureUpdateSchedulerError.launchctlFailed(arguments: arguments, status: process.terminationStatus)
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
    case launchctlFailed(arguments: [String], status: Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let arguments, let status):
            return "launchctl \(arguments.joined(separator: " ")) failed with status \(status)"
        }
    }
}
