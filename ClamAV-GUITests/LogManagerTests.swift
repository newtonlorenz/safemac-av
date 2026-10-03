import XCTest
@testable import ClamAV_GUI

final class LogManagerTests: XCTestCase {
    func testClearedEntriesDoNotReturnWhenAnotherEntryIsAdded() {
        let manager = LogManager()
        manager.add(.info, "Previous session activity")
        manager.clear()
        XCTAssertTrue(manager.entries.isEmpty)

        manager.add(.warning, "New activity")
        XCTAssertEqual(manager.entries.map(\.message), ["New activity"])
    }

    func testClearPreservesEntryLimitForSubsequentActivity() {
        let manager = LogManager(maxEntries: 2)
        manager.add(.info, "Before clear")
        manager.clear()
        for message in ["First", "Second", "Third"] {
            manager.add(.info, message)
        }
        XCTAssertEqual(manager.entries.map(\.message), ["Second", "Third"])
    }
}
