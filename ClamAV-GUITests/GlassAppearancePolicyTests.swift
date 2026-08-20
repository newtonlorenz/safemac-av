import XCTest
@testable import ClamAV_GUI

final class GlassAppearancePolicyTests: XCTestCase {
    func testUsesLiquidGlassWhenSupported() {
        let appearance = GlassAppearancePolicy.resolve(
            supportsLiquidGlass: true,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertEqual(appearance.surface, .liquidGlass)
        XCTAssertFalse(appearance.usesHighContrastBorder)
    }

    func testUsesMaterialFallbackBeforeMacOS26() {
        let appearance = GlassAppearancePolicy.resolve(
            supportsLiquidGlass: false,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertEqual(appearance.surface, .translucentMaterial)
    }

    func testReduceTransparencyUsesOpaqueSurface() {
        let appearance = GlassAppearancePolicy.resolve(
            supportsLiquidGlass: true,
            reduceTransparency: true,
            increaseContrast: false
        )

        XCTAssertEqual(appearance.surface, .opaque)
    }

    func testIncreaseContrastStrengthensSurfaceBoundary() {
        let appearance = GlassAppearancePolicy.resolve(
            supportsLiquidGlass: true,
            reduceTransparency: false,
            increaseContrast: true
        )

        XCTAssertTrue(appearance.usesHighContrastBorder)
    }
}
