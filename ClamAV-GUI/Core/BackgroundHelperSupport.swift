import Darwin
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

    static func isEmbeddedHelper(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.isExecutableFile(atPath: url.path) else { return false }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        return normalized.pathComponents.suffix(6) == [
            "Contents", "Library", "LoginItems", "SafeMacAVBackground.app", "Contents", "MacOS", executableName
        ].suffix(6)
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
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return false
        }

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

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
