import XCTest

// Assuming the module name is KeyStats
// If not, this line might need adjustment, but since we are just creating the file, it's fine.
// In a real Xcode project, we'd ensure the test target can import the main target.
// Since the user might need to adjust project settings, we assume standard behavior.

class StatsManagerTests: XCTestCase {
    var statsManager: StatsManager!
    var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Use a unique suite name to avoid conflicts and persistency between tests
        userDefaults = UserDefaults(suiteName: "test.KeyStats.\(UUID().uuidString)")
        userDefaults.removePersistentDomain(forName: userDefaults.suiteName!)
        statsManager = StatsManager(userDefaults: userDefaults)
    }

    override func tearDown() {
        if let suiteName = userDefaults.suiteName {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testInitialization() {
        XCTAssertEqual(statsManager.currentStats.keyPresses, 0)
        XCTAssertEqual(statsManager.currentStats.totalClicks, 0)
    }

    func testIncrementKeyPresses() {
        statsManager.incrementKeyPresses(keyName: "A")
        XCTAssertEqual(statsManager.currentStats.keyPresses, 1)
        XCTAssertEqual(statsManager.currentStats.keyPressCounts["A"], 1)

        statsManager.incrementKeyPresses(keyName: "B")
        XCTAssertEqual(statsManager.currentStats.keyPresses, 2)
        XCTAssertEqual(statsManager.currentStats.keyPressCounts["B"], 1)

        statsManager.incrementKeyPresses(keyName: "A")
        XCTAssertEqual(statsManager.currentStats.keyPresses, 3)
        XCTAssertEqual(statsManager.currentStats.keyPressCounts["A"], 2)
    }

    func testIncrementClicks() {
        statsManager.incrementLeftClicks()
        XCTAssertEqual(statsManager.currentStats.leftClicks, 1)
        XCTAssertEqual(statsManager.currentStats.totalClicks, 1)

        statsManager.incrementRightClicks()
        XCTAssertEqual(statsManager.currentStats.rightClicks, 1)
        XCTAssertEqual(statsManager.currentStats.totalClicks, 2)

        statsManager.incrementSideBackClicks()
        XCTAssertEqual(statsManager.currentStats.sideBackClicks, 1)
        XCTAssertEqual(statsManager.currentStats.totalClicks, 3)

        statsManager.incrementSideForwardClicks()
        XCTAssertEqual(statsManager.currentStats.sideForwardClicks, 1)
        XCTAssertEqual(statsManager.currentStats.totalClicks, 4)
    }

    func testMouseDistance() {
        statsManager.addMouseDistance(100.0)
        XCTAssertEqual(statsManager.currentStats.mouseDistance, 100.0)

        statsManager.addMouseDistance(50.0)
        XCTAssertEqual(statsManager.currentStats.mouseDistance, 150.0)
    }

    func testPersistence() {
        statsManager.incrementKeyPresses(keyName: "Test")
        statsManager.flushPendingSave()

        // Re-initialize with same defaults
        let newManager = StatsManager(userDefaults: userDefaults)
        XCTAssertEqual(newManager.currentStats.keyPresses, 1)
        XCTAssertEqual(newManager.currentStats.keyPressCounts["Test"], 1)
    }

    func testAppStats() {
        // AppIdentity is internal, so we rely on @testable import KeyStats to access it.
        // If not accessible, we might need to rely on public interfaces or skip this test.
        // Assuming access.
        let appIdentity = AppIdentity(bundleId: "com.test.app", displayName: "Test App")
        statsManager.incrementKeyPresses(keyName: "Space", appIdentity: appIdentity)

        XCTAssertEqual(statsManager.currentStats.appStats["com.test.app"]?.keyPresses, 1)
        XCTAssertEqual(statsManager.currentStats.appStats["com.test.app"]?.displayName, "Test App")
    }
}
