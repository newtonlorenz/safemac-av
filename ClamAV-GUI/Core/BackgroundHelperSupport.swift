import Darwin
import Combine
import Foundation
import Security

/// The helper has a deliberately tiny command surface. It must never accept a
/// main-app command line because it owns no windows, Finder handoff, or Sparkle.
enum BackgroundHelperLaunchMode: Equatable {
    case backgroundSession
    case scheduledSignatureUpdate
    case invalid

    var presentsUserInterface: Bool { false }
    var startsSoftwareUpdateSubsystem: Bool { false }
    var consumesFinderRequests: Bool { false }
}

enum BackgroundHelperLaunchModeParser {
    private static let scheduledSignatureFlag = "--scheduled-signature-update"

    static func parse(arguments: [String]) -> BackgroundHelperLaunchMode {
        let flags = Array(arguments.dropFirst())
        guard !flags.isEmpty else { return .backgroundSession }
        return flags == [scheduledSignatureFlag] ? .scheduledSignatureUpdate : .invalid
    }
}

enum BackgroundHelperBundle {
    static let bundleIdentifier = "com.newtonlorenz.ClamAV-GUI.Background"
    static let executableName = "SafeMacAVBackground"
    static let teamIdentifier = "CQPH8YR62A"

    static func executableURL(in mainBundleURL: URL) -> URL {
        mainBundleURL
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
            .appendingPathComponent("SafeMacAVBackground.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    static func isEmbeddedHelper(
        at url: URL,
        in mainBundleURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: url.path) else { return false }
        let normalizedMainBundle = mainBundleURL.standardizedFileURL
        let expectedExecutable = executableURL(in: normalizedMainBundle).standardizedFileURL
        let normalizedExecutable = url.standardizedFileURL
        guard normalizedExecutable == expectedExecutable else { return false }
        let helperBundleURL = expectedExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let data = try? Data(contentsOf: helperBundleURL.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { return false }
        var attributes = stat()
        guard lstat(helperBundleURL.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFDIR,
              lstat(expectedExecutable.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helperBundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        let requirementString = "identifier \(bundleIdentifier) and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

enum FreshclamInvocationError: Error, Equatable {
    case unsafeExecutable
    case unsafePath
    case signatureDirectoryCreationFailed
}

/// Shared command construction keeps foreground and helper updates on the
/// same freshclam contract: configuration, data directory, stdout and verbose
/// output. Both callers validate the executable before it is ever launched.
struct FreshclamInvocation: Equatable {
    let executablePath: String
    let arguments: [String]

    static func make(
        executablePath: String,
        configDirectory: String,
        signatureDirectory: String,
        fileManager: FileManager = .default
    ) throws -> FreshclamInvocation {
        guard isTrustedExecutable(at: executablePath, fileManager: fileManager) else {
            throw FreshclamInvocationError.unsafeExecutable
        }
        let resolvedExecutablePath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        guard configDirectory.hasPrefix("/"), signatureDirectory.hasPrefix("/") else {
            throw FreshclamInvocationError.unsafePath
        }
        let signatureURL = URL(fileURLWithPath: signatureDirectory, isDirectory: true)
        do {
            if !fileManager.fileExists(atPath: signatureURL.path) {
                try fileManager.createDirectory(at: signatureURL, withIntermediateDirectories: true)
            }
        } catch {
            throw FreshclamInvocationError.signatureDirectoryCreationFailed
        }
        let configFile = URL(fileURLWithPath: configDirectory, isDirectory: true)
            .appendingPathComponent("freshclam.conf")
        var arguments = [String]()
        if fileManager.fileExists(atPath: configFile.path) {
            arguments.append("--config-file=\(configFile.path)")
        }
        arguments += ["--stdout", "--datadir=\(signatureDirectory)", "--verbose"]
        // Validate the resolved inode and execute that resolved path. This
        // prevents a later symlink retarget from changing what is launched.
        return FreshclamInvocation(executablePath: resolvedExecutablePath, arguments: arguments)
    }

    static func isTrustedExecutable(at path: String, fileManager: FileManager = .default) -> Bool {
        guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else { return false }
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var attributes = stat()
        guard lstat(resolvedPath, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              (attributes.st_mode & 0o022) == 0,
              attributes.st_uid == 0 || attributes.st_uid == geteuid() else {
            return false
        }
        return true
    }
}

/// A privacy-neutral interpretation of freshclam output shared by foreground
/// and background launch modes. Callers never need to surface raw process
/// output to logs or notifications.
enum FreshclamUpdateOutcome: Equatable {
    case updated(main: String?, daily: String?, bytecode: String?)
    case upToDate
    case failed(message: String)

    static func parse(output: String, exitCode: Int32) -> FreshclamUpdateOutcome {
        var mainVersion: String?
        var dailyVersion: String?
        var bytecodeVersion: String?
        var isUpToDate = false
        var didUpdate = false
        var errorMessage: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            if trimmed.contains("main.cvd") || trimmed.contains("main.cld") { mainVersion = version(in: trimmed) ?? mainVersion }
            if trimmed.contains("daily.cvd") || trimmed.contains("daily.cld") { dailyVersion = version(in: trimmed) ?? dailyVersion }
            if trimmed.contains("bytecode.cvd") || trimmed.contains("bytecode.cld") { bytecodeVersion = version(in: trimmed) ?? bytecodeVersion }
            isUpToDate = isUpToDate || trimmed.contains("is up to date") || trimmed.contains("up-to-date")
            didUpdate = didUpdate || lowercased.contains("updated") || lowercased.contains("downloaded")
            if errorMessage == nil, lowercased.contains("error") || lowercased.contains("failed") { errorMessage = trimmed }
        }
        if exitCode != 0 && !isUpToDate && !didUpdate {
            return .failed(message: errorMessage ?? "Update failed with exit code \(exitCode)")
        }
        if isUpToDate && !didUpdate { return .upToDate }
        return .updated(main: mainVersion, daily: dailyVersion, bytecode: bytecodeVersion)
    }

    private static func version(in line: String) -> String? {
        let patterns = [
            #"version (\d+)"#,
            #"updated \(version: (\d+)"#,
            #"is up to date \(version: (\d+)"#,
            #"bytecode\.cvd database is up-to-date \(version: (\d+)"#,
            #"daily\.cld database is up-to-date \(version: (\d+)"#,
            #"main\.cvd database is up-to-date \(version: (\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return String(line[range])
        }
        return nil
    }
}

enum BackgroundRoute: String, CaseIterable {
    case open
    case settings
    case checkForUpdates

    static func parse(_ rawValue: String?) -> BackgroundRoute? {
        guard let rawValue else { return nil }
        return BackgroundRoute(rawValue: rawValue)
    }

    var distributedNotificationName: Notification.Name {
        Notification.Name("com.newtonlorenz.ClamAV-GUI.background-route.\(rawValue)")
    }
}

/// A durable, fixed-enum handoff between the login helper and the foreground
/// app. Distributed notifications are only a wake-up hint; the request file is
/// the authority and is consumed exactly once by the main app.
final class BackgroundRouteRequestStore {
    private let requestURL: URL
    private let fileManager: FileManager
    private let removeRequest: (URL) throws -> Void

    init(
        baseURL: URL? = nil,
        fileManager: FileManager = .default,
        removeRequest: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.fileManager = fileManager
        self.removeRequest = removeRequest
        if let baseURL {
            requestURL = baseURL.appendingPathComponent("background-route.request", isDirectory: false)
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            requestURL = support
                .appendingPathComponent("ClamAV-GUI", isDirectory: true)
                .appendingPathComponent("background-route.request", isDirectory: false)
        }
    }

    func enqueue(_ route: BackgroundRoute) -> Bool {
        let directory = requestURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard prepareSecureDirectory(directory) else { return false }
            var existing = stat()
            if lstat(requestURL.path, &existing) == 0, !isSafeRegularFile(at: requestURL) {
                return false
            }
            if lstat(requestURL.path, &existing) != 0, errno != ENOENT {
                return false
            }
            try Data(route.rawValue.utf8).write(to: requestURL, options: .atomic)
            guard normalizeSecureFile(at: requestURL) else { return false }
            return isSafeRegularFile(at: requestURL)
        } catch {
            return false
        }
    }

    func consume() -> BackgroundRoute? {
        guard let route = peek(), acknowledge(route) else { return nil }
        return route
    }

    func peek() -> BackgroundRoute? {
        guard let rawValue = readSecureRequest() else {
            return nil
        }
        return BackgroundRoute.parse(rawValue)
    }

    /// Acknowledge only the route just dispatched. A changed request remains
    /// durable for the next drain instead of being deleted as stale work.
    func acknowledge(_ route: BackgroundRoute) -> Bool {
        guard readSecureRequest() == route.rawValue else {
            return false
        }
        do {
            try removeRequest(requestURL)
            return true
        } catch {
            return false
        }
    }

    /// Drops a request only after proving it is our owner-only regular file.
    /// Used if canonical main-app launch fails, preventing later replay.
    func discard(_ route: BackgroundRoute) {
        _ = acknowledge(route)
    }

    private func isSafeRegularFile(at url: URL) -> Bool {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & 0o077) == 0 else {
            return false
        }
        return true
    }

    private func prepareSecureDirectory(_ directory: URL) -> Bool {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var attributes = stat()
        return fstat(descriptor, &attributes) == 0
            && (attributes.st_mode & S_IFMT) == S_IFDIR
            && attributes.st_uid == geteuid()
            && fchmod(descriptor, S_IRUSR | S_IWUSR | S_IXUSR) == 0
    }

    private func normalizeSecureFile(at url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var attributes = stat()
        return fstat(descriptor, &attributes) == 0
            && (attributes.st_mode & S_IFMT) == S_IFREG
            && attributes.st_uid == geteuid()
            && fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
    }

    private func readSecureRequest() -> String? {
        let descriptor = open(requestURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & 0o077) == 0 else {
            return nil
        }
        return String(data: handle.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// A same-user, symlink-resistant advisory lease shared by the legacy main
/// executable and the embedded helper. The descriptor stays open for the
/// duration of work so the kernel releases it if either process terminates.
final class BackgroundWorkLease {
    private let url: URL
    private let fileManager: FileManager
    private var descriptor: Int32 = -1

    init(
        name: String,
        baseURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let baseURL {
            url = baseURL.appendingPathComponent("\(name).lock", isDirectory: false)
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            url = support
                .appendingPathComponent("ClamAV-GUI", isDirectory: true)
                .appendingPathComponent("\(name).lock", isDirectory: false)
        }
    }

    deinit { release() }

    func acquire() -> Bool {
        guard descriptor == -1 else { return true }
        let directory = url.deletingLastPathComponent()
        guard prepareSecureDirectory(directory) else { return false }

        let fileDescriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return false }
        var attributes = stat()
        guard fstat(fileDescriptor, &attributes) == 0,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & S_IFMT) == S_IFREG,
              (attributes.st_mode & 0o077) == 0,
              flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            return false
        }
        descriptor = fileDescriptor
        return true
    }

    private func prepareSecureDirectory(_ directory: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { return false }
        defer { close(directoryDescriptor) }

        var attributes = stat()
        guard fstat(directoryDescriptor, &attributes) == 0,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & S_IFMT) == S_IFDIR,
              fchmod(directoryDescriptor, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            return false
        }
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

enum BackgroundMenuBarOwnership {
    /// The foreground app keeps its standalone menu item unless the helper is
    /// both registered and currently holding the shared background lease.
    static func mainShouldPresentMenuBar(
        helperIsEnabled: Bool,
        makeLease: () -> BackgroundWorkLease = { BackgroundWorkLease(name: "background-monitoring") }
    ) -> Bool {
        guard helperIsEnabled else { return true }
        let lease = makeLease()
        guard lease.acquire() else { return false }
        lease.release()
        return true
    }
}

@MainActor
final class BackgroundMenuBarOwnershipCoordinator: ObservableObject {
    static let helperWillAcquireNotification = Notification.Name("com.newtonlorenz.ClamAV-GUI.background-helper-will-acquire")

    @Published private(set) var mainShouldPresentMenuBar = false
    private let makeLease: () -> BackgroundWorkLease
    private let now: () -> Date
    private let startupGrace: TimeInterval
    private var lease: BackgroundWorkLease?
    private var helperEnabled = false
    private var nextRecoveryAttempt = Date.distantFuture
    private var ownershipHintObserver: NSObjectProtocol?
    private var recoveryTimer: DispatchSourceTimer?

    init(
        makeLease: @escaping () -> BackgroundWorkLease = { BackgroundWorkLease(name: "background-monitoring") },
        now: @escaping () -> Date = Date.init,
        startupGrace: TimeInterval = 5,
        startsRecoveryTimer: Bool = true
    ) {
        self.makeLease = makeLease
        self.now = now
        self.startupGrace = startupGrace
        ownershipHintObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.helperWillAcquireNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareForHelperOwnership() }
        }
        if startsRecoveryTimer {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                Task { @MainActor in self?.recoverIfHelperIsAbsent() }
            }
            recoveryTimer = timer
            timer.resume()
        }
    }

    deinit {
        if let ownershipHintObserver {
            DistributedNotificationCenter.default().removeObserver(ownershipHintObserver)
        }
        recoveryTimer?.cancel()
    }

    func reconcile(helperEnabled: Bool) {
        self.helperEnabled = helperEnabled
        if helperEnabled {
            prepareForHelperOwnership()
        } else {
            claimFallbackOwnership()
        }
    }

    /// Called by the app lifecycle timer. It deliberately waits through a
    /// startup grace period so a late login helper can claim ownership first.
    func recoverIfHelperIsAbsent() {
        guard helperEnabled, now() >= nextRecoveryAttempt, lease == nil else { return }
        claimFallbackOwnership()
    }

    func prepareForHelperOwnership() {
        lease?.release()
        lease = nil
        mainShouldPresentMenuBar = false
        nextRecoveryAttempt = now().addingTimeInterval(startupGrace)
    }

    private func claimFallbackOwnership() {
        let candidate = makeLease()
        guard candidate.acquire() else {
            mainShouldPresentMenuBar = false
            return
        }
        lease = candidate
        mainShouldPresentMenuBar = true
    }

    static func notifyHelperWillAcquireOwnership() {
        DistributedNotificationCenter.default().post(
            name: helperWillAcquireNotification,
            object: nil,
            userInfo: nil
        )
    }
}
