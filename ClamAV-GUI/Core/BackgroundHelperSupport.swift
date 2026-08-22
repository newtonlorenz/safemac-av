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
}
