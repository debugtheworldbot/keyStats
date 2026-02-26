import XCTest
@testable import KeyStats

class DailyStatsTests: XCTestCase {

    func testInitialization() {
        let stats = DailyStats()
        XCTAssertEqual(stats.keyPresses, 0)
        XCTAssertEqual(stats.totalClicks, 0)
        XCTAssertEqual(stats.mouseDistance, 0)
    }

    func testTotalClicks() {
        var stats = DailyStats()
        stats.leftClicks = 10
        stats.rightClicks = 5
        stats.sideBackClicks = 2
        stats.sideForwardClicks = 1

        XCTAssertEqual(stats.totalClicks, 18)
    }

    func testCorrectionRate() {
        var stats = DailyStats()
        stats.keyPresses = 100
        stats.keyPressCounts["Delete"] = 5
        stats.keyPressCounts["ForwardDelete"] = 5
        stats.keyPressCounts["A"] = 90

        // 10 deletes out of 100 keys
        XCTAssertEqual(stats.correctionRate, 0.1, accuracy: 0.0001)
    }

    func testInputRatio() {
        var stats = DailyStats()
        stats.keyPresses = 100
        stats.leftClicks = 50
        // total clicks = 50

        XCTAssertEqual(stats.inputRatio, 2.0, accuracy: 0.0001)
    }

    func testEncodingDecoding() {
        var stats = DailyStats()
        stats.keyPresses = 42
        stats.leftClicks = 10
        stats.keyPressCounts["Enter"] = 5

        do {
            let data = try JSONEncoder().encode(stats)
            let decoded = try JSONDecoder().decode(DailyStats.self, from: data)

            XCTAssertEqual(decoded.keyPresses, 42)
            XCTAssertEqual(decoded.leftClicks, 10)
            XCTAssertEqual(decoded.keyPressCounts["Enter"], 5)
        } catch {
            XCTFail("Encoding/Decoding failed: \(error)")
        }
    }
}
