import XCTest
@testable import ClamAV_GUI

@MainActor
final class SoftwareUpdateManagerTests: XCTestCase {
    func testRejectsMissingSparkleConfiguration() {
        XCTAssertFalse(SoftwareUpdateManager.hasRequiredSparkleConfiguration(feedURLString: nil, publicKey: nil))
        XCTAssertFalse(SoftwareUpdateManager.hasRequiredSparkleConfiguration(feedURLString: "https://example.com/appcast.xml", publicKey: ""))
    }

    func testRejectsUnexpandedBuildSettingPlaceholders() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "$(SPARKLE_FEED_URL)",
                publicKey: "$(SPARKLE_PUBLIC_ED_KEY)"
            )
        )
    }

    func testRequiresHTTPSFeedURL() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "http://example.com/appcast.xml",
                publicKey: "public-key"
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "not a url",
                publicKey: "public-key"
            )
        )
    }

    func testRequiresSignedFeedAndPreExtractionVerification() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "public-key",
                requiresSignedFeed: false,
                verifiesUpdateBeforeExtraction: true
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "public-key",
                requiresSignedFeed: true,
                verifiesUpdateBeforeExtraction: false
            )
        )
    }

    func testAcceptsHTTPSFeedURLAndPublicKey() {
        XCTAssertTrue(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "public-key"
            )
        )
    }

    func testAutomatedTestInitializationDoesNotStartUpdater() {
        let manager = SoftwareUpdateManager(bundle: .main, isAutomatedTest: true)

        XCTAssertFalse(manager.canCheckForUpdates)
    }
}
