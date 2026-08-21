import Cocoa
import FinderSync

class FinderSync: FIFinderSync {
    override init() {
        super.init()

        // Watch all volumes
        let finderSync = FIFinderSyncController.default()
        if let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) {
            finderSync.directoryURLs = Set(mountedVolumes)
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let menuItem = NSMenuItem(
            title: "Scan with SafeMac AV",
            action: #selector(scanSelectedItems(_:)),
            keyEquivalent: ""
        )
        menuItem.image = NSImage(systemSymbolName: "shield.checkmark", accessibilityDescription: "Scan")
        menu.addItem(menuItem)
        return menu
    }

    @objc func scanSelectedItems(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty else { return }

        // Persist the request first; distributed notifications are only a wake signal.
        let paths = items.map { $0.path }
        do {
            let request = try ExternalScanRequestStore().enqueue(paths: paths, source: ExternalScanRequestStore.finderSource)
            DistributedNotificationCenter.default().postNotificationName(
                ExternalScanRequestStore.scanRequestNotificationName,
                object: nil,
                userInfo: ["requestID": request.id.uuidString],
                deliverImmediately: true
            )
        } catch {
            NSLog("SafeMac AV Finder request could not be persisted: %@", error.localizedDescription)
            openMainApp {
                DistributedNotificationCenter.default().postNotificationName(
                    ExternalScanRequestStore.scanRequestFailedNotificationName,
                    object: nil,
                    userInfo: ["message": ExternalScanRequestStore.genericHandoffFailureMessage],
                    deliverImmediately: true
                )
            }
            return
        }

        openMainApp()
    }

    private func openMainApp(completion: (() -> Void)? = nil) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.newtonlorenz.ClamAV-GUI") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                completion?()
            }
        } else {
            completion?()
        }
    }
}
