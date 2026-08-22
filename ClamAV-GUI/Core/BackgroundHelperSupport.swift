import Darwin
import Combine
import Foundation

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
        let normalizedMainBundle = mainBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let expectedExecutable = executableURL(in: normalizedMainBundle)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let normalizedExecutable = url.standardizedFileURL.resolvingSymlinksInPath()
        guard normalizedExecutable == expectedExecutable else { return false }
        let helperBundleURL = expectedExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let data = try? Data(contentsOf: helperBundleURL.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return info["CFBundleIdentifier"] as? String == bundleIdentifier
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
        return FreshclamInvocation(executablePath: executablePath, arguments: arguments)
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

    init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try Data(route.rawValue.utf8).write(to: requestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
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
        guard isSafeRegularFile(at: requestURL),
              let rawValue = try? String(contentsOf: requestURL, encoding: .utf8) else {
            return nil
        }
        return BackgroundRoute.parse(rawValue)
    }

    /// Acknowledge only the route just dispatched. A changed request remains
    /// durable for the next drain instead of being deleted as stale work.
    func acknowledge(_ route: BackgroundRoute) -> Bool {
        guard isSafeRegularFile(at: requestURL),
              (try? String(contentsOf: requestURL, encoding: .utf8)) == route.rawValue else {
            return false
        }
        do {
            try fileManager.removeItem(at: requestURL)
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
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: geteuid()),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0 else {
            return false
        }
        return true
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
