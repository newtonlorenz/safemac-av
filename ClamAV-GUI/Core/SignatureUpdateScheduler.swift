import Darwin
import Foundation

protocol SignatureUpdateScheduling: AnyObject {
    func reconcile(enabled: Bool, schedule: ScanSchedule) throws
}

enum SignatureUpdateLaunchctlOperation: Equatable {
    case bootstrap(domain: String, plistURL: URL)
    case bootout(serviceTarget: String)
}

final class SignatureUpdateScheduler: SignatureUpdateScheduling {
    typealias DataWriter = (Data, URL, Data.WritingOptions) throws -> Void
    typealias LoadedStatusProvider = () throws -> Bool
    typealias LaunchctlRunner = (SignatureUpdateLaunchctlOperation) throws -> Void

    static let label = "com.newtonlorenz.ClamAV-GUI.signature-update"

    private struct Snapshot {
        let plistData: Data?
        let wasLoaded: Bool
    }

    private struct MutationState {
        var previousJobBootedOut = false
        var replacementWritten = false
        var replacementBootstrapAttempted = false

        var requiresRollback: Bool {
            previousJobBootedOut || replacementWritten || replacementBootstrapAttempted
        }
    }

    private let fileManager: FileManager
    private let launchAgentsDirectory: URL
    private let applicationBundlePath: String
    private let backgroundHelperExecutableURL: URL
    private let backgroundHelperValidator: (URL) -> Bool
    private let domain: String
    private let serviceTarget: String
    private let dataWriter: DataWriter
    private let loadedStatusProvider: LoadedStatusProvider
    private let launchctlRunner: LaunchctlRunner

    init(
        fileManager: FileManager = .default,
        launchAgentsDirectory: URL? = nil,
        applicationBundlePath: String = Bundle.main.bundlePath,
        backgroundHelperExecutableURL: URL? = nil,
        backgroundHelperValidator: @escaping (URL) -> Bool = { url in
            BackgroundHelperBundle.isEmbeddedHelper(at: url)
        },
        userID: uid_t = getuid(),
        launchctlExecutableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        dataWriter: @escaping DataWriter = { data, url, options in
            try data.write(to: url, options: options)
        },
        loadedStatusProvider: LoadedStatusProvider? = nil,
        launchctlRunner: LaunchctlRunner? = nil
    ) {
        let domain = "gui/\(userID)"
        let serviceTarget = "\(domain)/\(Self.label)"
        self.fileManager = fileManager
        self.launchAgentsDirectory = launchAgentsDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.applicationBundlePath = applicationBundlePath
        let bundleURL = URL(fileURLWithPath: applicationBundlePath, isDirectory: true)
        self.backgroundHelperExecutableURL = backgroundHelperExecutableURL
            ?? BackgroundHelperBundle.executableURL(in: bundleURL)
        self.backgroundHelperValidator = backgroundHelperValidator
        self.domain = domain
        self.serviceTarget = serviceTarget
        self.dataWriter = dataWriter
        self.loadedStatusProvider = loadedStatusProvider ?? {
            try Self.isLoaded(serviceTarget: serviceTarget, executableURL: launchctlExecutableURL)
        }
        self.launchctlRunner = launchctlRunner ?? { operation in
            try Self.runLaunchctl(operation, executableURL: launchctlExecutableURL)
        }
    }

    func reconcile(enabled: Bool, schedule: ScanSchedule) throws {
        let plistURL = launchAgentURL
        if enabled, !backgroundHelperValidator(backgroundHelperExecutableURL) {
            throw SignatureUpdateSchedulerError.backgroundHelperUnavailable
        }
        let snapshot = try snapshot(at: plistURL)
        let replacement = try enabled ? launchAgentData(for: schedule) : nil
        var mutation = MutationState()

        do {
            if snapshot.wasLoaded {
                try bootout()
                mutation.previousJobBootedOut = true
            }

            if let replacement {
                try fileManager.createDirectory(
                    at: launchAgentsDirectory,
                    withIntermediateDirectories: true
                )
                try dataWriter(replacement, plistURL, .atomic)
                mutation.replacementWritten = true
                try normalizePermissions(at: plistURL)
                mutation.replacementBootstrapAttempted = true
                try bootstrap(plistURL: plistURL)
            } else if snapshot.plistData != nil {
                try fileManager.removeItem(at: plistURL)
            }
        } catch {
            guard mutation.requiresRollback else { throw error }
            do {
                try restore(snapshot, at: plistURL, mutation: mutation)
            } catch let rollbackError {
                throw SignatureUpdateSchedulerError.reconciliationAndRollbackFailed(
                    primaryDescription: Self.safeDescription(for: error),
                    rollbackDescription: Self.safeDescription(for: rollbackError)
                )
            }
            throw error
        }
    }

    private var launchAgentURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    private func launchAgentData(for schedule: ScanSchedule) throws -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [
                backgroundHelperExecutableURL.path,
                "--scheduled-signature-update"
            ],
            "StartCalendarInterval": try calendarInterval(for: schedule),
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

    private func snapshot(at url: URL) throws -> Snapshot {
        let plistData: Data?
        if fileManager.fileExists(atPath: url.path) {
            plistData = try Data(contentsOf: url)
        } else {
            plistData = nil
        }
        return Snapshot(plistData: plistData, wasLoaded: try loadedStatusProvider())
    }

    private func restore(
        _ snapshot: Snapshot,
        at url: URL,
        mutation: MutationState
    ) throws {
        if mutation.replacementBootstrapAttempted {
            try bootout()
        }

        if let plistData = snapshot.plistData {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try dataWriter(plistData, url, .atomic)
            try normalizePermissions(at: url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        if snapshot.wasLoaded {
            guard snapshot.plistData != nil else {
                throw SignatureUpdateSchedulerError.loadedJobMissingPropertyList
            }
            try bootstrap(plistURL: url)
        }
    }

    private func bootstrap(plistURL: URL) throws {
        try launchctlRunner(.bootstrap(domain: domain, plistURL: plistURL))
    }

    private func normalizePermissions(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    }

    private func bootout() throws {
        try launchctlRunner(.bootout(serviceTarget: serviceTarget))
    }

    private static func isLoaded(serviceTarget: String, executableURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["print", serviceTarget]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            throw SignatureUpdateSchedulerError.launchctlFailed(
                command: "print",
                status: process.terminationStatus
            )
        }
        return try loadedState(forPrintStatus: process.terminationStatus)
    }

    static func loadedState(forPrintStatus status: Int32) throws -> Bool {
        if status == 0 { return true }
        if isMissingServiceStatus(status) { return false }
        throw SignatureUpdateSchedulerError.launchctlFailed(command: "print", status: status)
    }

    private static func runLaunchctl(
        _ operation: SignatureUpdateLaunchctlOperation,
        executableURL: URL
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        switch operation {
        case .bootstrap(let domain, let plistURL):
            process.arguments = ["bootstrap", domain, plistURL.path]
        case .bootout(let serviceTarget):
            process.arguments = ["bootout", serviceTarget]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit else {
            throw SignatureUpdateSchedulerError.launchctlFailed(
                command: operation.commandName,
                status: process.terminationStatus
            )
        }
        if case .bootout = operation,
           Self.isMissingServiceStatus(process.terminationStatus) {
            return
        }
        guard process.terminationStatus == 0 else {
            throw SignatureUpdateSchedulerError.launchctlFailed(
                command: operation.commandName,
                status: process.terminationStatus
            )
        }
    }

    private static func isMissingServiceStatus(_ status: Int32) -> Bool {
        status == 3 || status == 113
    }

    private static func safeDescription(for error: Error) -> String {
        if let schedulerError = error as? SignatureUpdateSchedulerError {
            return schedulerError.errorDescription ?? "The schedule operation failed."
        }
        return "The schedule operation failed."
    }
}

private extension SignatureUpdateLaunchctlOperation {
    var commandName: String {
        switch self {
        case .bootstrap: "bootstrap"
        case .bootout: "bootout"
        }
    }
}

enum SignatureUpdateSchedulerError: LocalizedError, Equatable {
    case invalidSchedule
    case backgroundHelperUnavailable
    case launchctlFailed(command: String, status: Int32)
    case loadedJobMissingPropertyList
    case reconciliationAndRollbackFailed(
        primaryDescription: String,
        rollbackDescription: String
    )

    var errorDescription: String? {
        switch self {
        case .invalidSchedule:
            return "The automatic signature update schedule is invalid."
        case .backgroundHelperUnavailable:
            return "SafeMac AV could not find its background helper. Reinstall the app before enabling automatic signature updates."
        case .launchctlFailed(let command, let status):
            return "launchctl \(command) failed with exit status \(status)."
        case .loadedJobMissingPropertyList:
            return "The previous loaded schedule could not be restored from disk."
        case .reconciliationAndRollbackFailed:
            return "The schedule change failed and the previous launchd state could not be restored."
        }
    }
}
