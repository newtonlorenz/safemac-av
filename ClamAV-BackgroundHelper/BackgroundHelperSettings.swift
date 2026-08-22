import Darwin
import Foundation

struct BackgroundHelperSettings: Equatable {
    let autoUpdateSignatures: Bool
    let freshclamPath: String?
    let configDirectory: String?
    let signatureDirectory: String?
    let showNotifications: Bool

    static let safeDefaults = BackgroundHelperSettings(
        autoUpdateSignatures: false,
        freshclamPath: nil,
        configDirectory: nil,
        signatureDirectory: nil,
        showNotifications: false
    )
}

/// Watches the containing directory rather than the JSON file, so atomic file
/// replacement is observed. A malformed replacement never replaces the last
/// known-good settings; safe defaults are used only before a valid first load.
final class BackgroundHelperSettingsStore {
    private let settingsURL: URL
    private let lastKnownGoodURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var lastKnownGood: BackgroundHelperSettings?
    private var source: DispatchSourceFileSystemObject?

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.lastKnownGoodURL = settingsURL
            .deletingPathExtension()
            .appendingPathExtension("last-known-good.json")
        self.fileManager = fileManager
    }

    deinit {
        source?.cancel()
    }

    @discardableResult
    func reload() -> BackgroundHelperSettings {
        let primarySettings = decodeSettings(at: settingsURL)
        let decoded = primarySettings ?? decodePersistedLastKnownGood()
        lock.lock()
        defer { lock.unlock() }
        if let decoded {
            lastKnownGood = decoded
            if primarySettings != nil {
                persistLastKnownGood(decoded)
            }
        }
        return lastKnownGood ?? .safeDefaults
    }

    func startWatching(onReload: @escaping (BackgroundHelperSettings) -> Void = { _ in }) {
        guard source == nil else { return }
        let directory = settingsURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                return
            }
        }
        guard isSafeOwnerOnlyDirectory(at: directory) else { return }
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            onReload(self.reload())
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func decodeSettings(at url: URL) -> BackgroundHelperSettings? {
        guard isSafeOwnerOnlyDirectory(at: settingsURL.deletingLastPathComponent()),
              isSafeOwnerOnlyRegularFile(at: url),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let autoUpdateSignatures = object["autoUpdateSignatures"] as? Bool else {
            return nil
        }
        let freshclamPath = object["freshclamPath"] as? String
        let configDirectory = object["configDirectory"] as? String
        let signatureDirectory = object["signatureDirectory"] as? String
        let showNotifications = object["showNotifications"] as? Bool ?? false
        guard freshclamPath == nil || freshclamPath!.hasPrefix("/"),
              configDirectory == nil || configDirectory!.hasPrefix("/"),
              signatureDirectory == nil || signatureDirectory!.hasPrefix("/") else { return nil }
        return BackgroundHelperSettings(
            autoUpdateSignatures: autoUpdateSignatures,
            freshclamPath: freshclamPath,
            configDirectory: configDirectory,
            signatureDirectory: signatureDirectory,
            showNotifications: showNotifications
        )
    }

    private func decodePersistedLastKnownGood() -> BackgroundHelperSettings? {
        guard isSafeOwnerOnlyRegularFile(at: lastKnownGoodURL) else { return nil }
        return decodeSettings(at: lastKnownGoodURL)
    }

    private func persistLastKnownGood(_ settings: BackgroundHelperSettings) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": settings.autoUpdateSignatures,
            "freshclamPath": settings.freshclamPath as Any,
            "configDirectory": settings.configDirectory as Any,
            "signatureDirectory": settings.signatureDirectory as Any,
            "showNotifications": settings.showNotifications
        ], options: [.sortedKeys]) else { return }
        do {
            try data.write(to: lastKnownGoodURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lastKnownGoodURL.path)
        } catch {
            return
        }
    }

    private func isSafeOwnerOnlyRegularFile(at url: URL) -> Bool {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & S_IFMT) == S_IFREG,
              (attributes.st_mode & 0o077) == 0 else {
            return false
        }
        return true
    }

    private func isSafeOwnerOnlyDirectory(at url: URL) -> Bool {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & S_IFMT) == S_IFDIR,
              (attributes.st_mode & 0o077) == 0 else {
            return false
        }
        return true
    }
}
