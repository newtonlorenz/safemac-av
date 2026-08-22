import Darwin
import Foundation

struct BackgroundHelperSettings: Equatable {
    let autoUpdateSignatures: Bool
    let freshclamPath: String?

    static let safeDefaults = BackgroundHelperSettings(autoUpdateSignatures: false, freshclamPath: nil)
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
    private var directoryDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.lastKnownGoodURL = settingsURL
            .deletingPathExtension()
            .appendingPathExtension("last-known-good.json")
        self.fileManager = fileManager
    }

    deinit {
        let source = source
        self.source = nil
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
            directoryDescriptor = -1
        }
        source?.setCancelHandler {}
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
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        directoryDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            onReload(self.reload())
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        self.source = source
        source.resume()
    }

    private func decodeSettings(at url: URL) -> BackgroundHelperSettings? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let autoUpdateSignatures = object["autoUpdateSignatures"] as? Bool else {
            return nil
        }
        let freshclamPath = object["freshclamPath"] as? String
        guard freshclamPath == nil || freshclamPath!.hasPrefix("/") else { return nil }
        return BackgroundHelperSettings(
            autoUpdateSignatures: autoUpdateSignatures,
            freshclamPath: freshclamPath
        )
    }

    private func decodePersistedLastKnownGood() -> BackgroundHelperSettings? {
        guard isSafeOwnerOnlyRegularFile(at: lastKnownGoodURL) else { return nil }
        return decodeSettings(at: lastKnownGoodURL)
    }

    private func persistLastKnownGood(_ settings: BackgroundHelperSettings) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "autoUpdateSignatures": settings.autoUpdateSignatures,
            "freshclamPath": settings.freshclamPath as Any
        ], options: [.sortedKeys]) else { return }
        do {
            try data.write(to: lastKnownGoodURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lastKnownGoodURL.path)
        } catch {
            return
        }
    }

    private func isSafeOwnerOnlyRegularFile(at url: URL) -> Bool {
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
