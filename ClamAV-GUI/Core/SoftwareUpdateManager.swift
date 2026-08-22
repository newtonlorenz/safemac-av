import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class SoftwareUpdateManager: ObservableObject {
    let isConfigured: Bool
    private(set) var hasStartedUpdater = false

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
#endif
    private var routeObserver: NSObjectProtocol?
    private let isAutomatedTest: Bool
    private let updaterStartHandler: (() -> Void)?
    private let updateCheckHandler: (() -> Void)?

    init(
        bundle: Bundle = .main,
        startsUpdater: Bool = false,
        isAutomatedTest: Bool = SoftwareUpdateManager.defaultIsAutomatedTest(),
        isConfiguredOverride: Bool? = nil,
        updaterStartHandler: (() -> Void)? = nil,
        updateCheckHandler: (() -> Void)? = nil
    ) {
        isConfigured = isConfiguredOverride ?? Self.hasRequiredSparkleConfiguration(bundle: bundle)
        self.isAutomatedTest = isAutomatedTest
        self.updaterStartHandler = updaterStartHandler
        self.updateCheckHandler = updateCheckHandler
        routeObserver = NotificationCenter.default.addObserver(
            forName: .checkForAppUpdates,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }

#if canImport(Sparkle)
        if isConfigured, !isAutomatedTest, updaterStartHandler == nil {
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            updaterController = controller
        }
#endif

        if startsUpdater {
            startUpdaterIfPossible()
        }
    }

    func startUpdaterIfPossible() {
        guard isConfigured, !isAutomatedTest, !hasStartedUpdater else { return }
        hasStartedUpdater = true
        if let updaterStartHandler {
            updaterStartHandler()
            return
        }
#if canImport(Sparkle)
        updaterController?.startUpdater()
#endif
    }

    func checkForUpdates() {
        startUpdaterIfPossible()
        guard hasStartedUpdater else { return }
        if let updateCheckHandler {
            updateCheckHandler()
            return
        }
#if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
#endif
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    nonisolated static func hasRequiredSparkleConfiguration(bundle: Bundle) -> Bool {
        hasRequiredSparkleConfiguration(
            feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            requiresSignedFeed: bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool,
            verifiesUpdateBeforeExtraction: bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool
        )
    }

    nonisolated static func hasRequiredSparkleConfiguration(
        feedURLString: String?,
        publicKey: String?,
        requiresSignedFeed: Bool? = true,
        verifiesUpdateBeforeExtraction: Bool? = true
    ) -> Bool {
        guard let feedURLString,
              let feedURL = URL(string: feedURLString),
              feedURL.scheme == "https",
              feedURL.host?.isEmpty == false,
              let publicKey,
              requiresSignedFeed == true,
              verifiesUpdateBeforeExtraction == true else {
            return false
        }

        return !feedURLString.contains("$(")
            && !publicKey.contains("$(")
            && isValidSparklePublicKey(publicKey)
    }

    nonisolated private static func isValidSparklePublicKey(_ publicKey: String) -> Bool {
        let trimmedPublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPublicKey.isEmpty,
              let decodedPublicKey = Data(base64Encoded: trimmedPublicKey) else {
            return false
        }

        return decodedPublicKey.count == 32
    }

    nonisolated private static func defaultIsAutomatedTest() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Coordinates the initial foreground launch so Sparkle cannot present its
/// first-run consent sheet before required maintenance has completed.
@MainActor
final class SoftwareUpdateStartupCoordinator {
    private var hasRunInitialMaintenance = false

    func runInitialMaintenance(
        launchMode: LaunchMode,
        settingsProvider: () -> AppSettings,
        isUITesting: Bool,
        maintenance: () async -> Void,
        afterMaintenance: () -> Void = {},
        startUpdater: () -> Void
    ) async {
        guard !hasRunInitialMaintenance else { return }
        hasRunInitialMaintenance = true
        await maintenance()
        afterMaintenance()
        guard launchMode.isInteractive,
              !launchMode.hidesDock(settings: settingsProvider(), isUITesting: isUITesting) else {
            return
        }
        startUpdater()
    }
}

extension Notification.Name {
    static let checkForAppUpdates = Notification.Name("com.newtonlorenz.ClamAV-GUI.checkForAppUpdates")
}
