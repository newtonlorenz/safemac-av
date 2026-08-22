import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class SoftwareUpdateManager: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    let isConfigured: Bool

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
#endif

    init(
        bundle: Bundle = .main,
        startsUpdater: Bool = true,
        isAutomatedTest: Bool = SoftwareUpdateManager.defaultIsAutomatedTest()
    ) {
        isConfigured = Self.hasRequiredSparkleConfiguration(bundle: bundle)

#if canImport(Sparkle)
        guard isConfigured, startsUpdater, !isAutomatedTest else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
#endif
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
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func defaultIsAutomatedTest() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
