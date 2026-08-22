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
        let store = ExternalScanRequestStore()
        let handoff = FinderScanRequestHandoff(
            enqueue: { try store.enqueue(paths: $0, source: $1) },
            postWake: { requestID in
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("com.newtonlorenz.ClamAV-GUI.scanRequest"),
                    object: nil,
                    userInfo: ["requestID": requestID.uuidString],
                    deliverImmediately: true
                )
            },
            presentFailure: { Self.presentHandoffFailure(message: $0) }
        )
        handoff.submit(paths: paths)

        // Open main app
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.newtonlorenz.ClamAV-GUI") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func presentHandoffFailure(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
