import Cocoa
import FinderSync

class FinderSync: FIFinderSync {
    static let mainAppBundleIdentifier = "com.newtonlorenz.ClamAV-GUI"

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
                    ExternalScanRequestStore.scanRequestNotificationName,
                    object: nil,
                    userInfo: ["requestID": requestID.uuidString],
                    deliverImmediately: true
                )
            },
            presentFailure: { _ in Self.presentHandoffFailure() }
        )
        if handoff.submit(paths: paths) {
            Self.openMainApp()
        }
    }

    private static func openMainApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainAppBundleIdentifier) else {
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func presentHandoffFailure() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainAppBundleIdentifier) else {
            presentGenericFailureAlert()
            return
        }

        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard error == nil else {
                DispatchQueue.main.async {
                    presentGenericFailureAlert()
                }
                return
            }
            DistributedNotificationCenter.default().postNotificationName(
                ExternalScanRequestStore.scanRequestFailedNotificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    private static func presentGenericFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = FinderScanRequestHandoff.genericFailureMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
