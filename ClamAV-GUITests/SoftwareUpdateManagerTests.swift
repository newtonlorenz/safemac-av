import XCTest
@testable import ClamAV_GUI

@MainActor
final class SoftwareUpdateManagerTests: XCTestCase {
    private let validPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

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
                publicKey: validPublicKey
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "not a url",
                publicKey: validPublicKey
            )
        )
    }

    func testRequiresValidPublicEdDSAKey() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "public-key"
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: "c2hvcnQ="
            )
        )
    }

    func testRequiresSignedFeedAndPreExtractionVerification() {
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: validPublicKey,
                requiresSignedFeed: false,
                verifiesUpdateBeforeExtraction: true
            )
        )
        XCTAssertFalse(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: validPublicKey,
                requiresSignedFeed: true,
                verifiesUpdateBeforeExtraction: false
            )
        )
    }

    func testAcceptsHTTPSFeedURLAndPublicKey() {
        XCTAssertTrue(
            SoftwareUpdateManager.hasRequiredSparkleConfiguration(
                feedURLString: "https://example.com/appcast.xml",
                publicKey: validPublicKey
            )
        )
    }

    func testAutomatedTestInitializationDoesNotStartUpdater() {
        let manager = SoftwareUpdateManager(bundle: .main, isAutomatedTest: true)

        XCTAssertFalse(manager.canCheckForUpdates)
    }
}
