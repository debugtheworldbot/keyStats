import XCTest
@testable import KeyStatsHelperLogic

final class InputEventDeduplicatorTests: XCTestCase {
    func testMatchingSyntheticCopyIsCountedOnce() {
        var deduplicator = InputEventDeduplicator()
        XCTAssertFalse(deduplicator.shouldDrop(type: 22, detail: 1, sourcePID: 0, eventTimestamp: 1, flags: 0, time: 10))
        XCTAssertTrue(deduplicator.shouldDrop(type: 22, detail: 1, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10.02))
        XCTAssertTrue(deduplicator.shouldDrop(type: 22, detail: 1, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10.04))
    }

    func testStandaloneOrUnrelatedSyntheticEventIsCounted() {
        var deduplicator = InputEventDeduplicator()
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 0, eventTimestamp: 1, flags: 0, time: 11))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 5, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 11.01))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 11.1))
    }

    func testInterleavedHardwareEventsDoNotHideEarlierCopies() {
        var deduplicator = InputEventDeduplicator()
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 0, eventTimestamp: 1, flags: 0, time: 10))
        XCTAssertFalse(deduplicator.shouldDrop(type: 5, detail: 0, sourcePID: 0, eventTimestamp: 2, flags: 0, time: 10.01))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 0, eventTimestamp: 3, flags: 0, time: 10.015))
        XCTAssertTrue(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10.02))
        XCTAssertTrue(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 3, flags: 0, time: 10.03))
    }

    func testIndependentSyntheticInputWithinWindowIsCounted() {
        var deduplicator = InputEventDeduplicator()
        for type: UInt32 in [10, 22] {
            XCTAssertFalse(deduplicator.shouldDrop(type: type, detail: 0, sourcePID: 0, eventTimestamp: 1, flags: 0, time: 10))
            XCTAssertFalse(deduplicator.shouldDrop(type: type, detail: 0, sourcePID: 123, eventTimestamp: 2, flags: 0, time: 10.04))
        }
    }

    func testModifierReleaseIsNotTreatedAsPressCopy() {
        var deduplicator = InputEventDeduplicator()
        XCTAssertFalse(deduplicator.shouldDrop(type: 12, detail: 56, sourcePID: 0, eventTimestamp: 1, flags: 1 << 17, time: 10))
        XCTAssertFalse(deduplicator.shouldDrop(type: 12, detail: 56, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10.01))
    }

    func testMissingTimestampDoesNotSuppressInput() {
        var deduplicator = InputEventDeduplicator()
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 0, eventTimestamp: 0, flags: 0, time: 10))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 0, flags: 0, time: 10.01))
    }

    func testExpiredAndFutureRecordsAreNotMatched() {
        var deduplicator = InputEventDeduplicator()
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 0, eventTimestamp: 1, flags: 0, time: 10))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10.081))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 0, eventTimestamp: 2, flags: 0, time: 11))
        XCTAssertFalse(deduplicator.shouldDrop(type: 10, detail: 4, sourcePID: 123, eventTimestamp: 2, flags: 0, time: 10.9))
    }

    func testHighEventRateKeepsRecentRecordsBounded() {
        var deduplicator = InputEventDeduplicator()
        for timestamp in 1...257 {
            XCTAssertFalse(deduplicator.shouldDrop(type: 5, detail: 0, sourcePID: 0, eventTimestamp: UInt64(timestamp), flags: 0, time: 10 + Double(timestamp) / 100_000))
        }
        XCTAssertFalse(deduplicator.shouldDrop(type: 5, detail: 0, sourcePID: 123, eventTimestamp: 1, flags: 0, time: 10.01))
        XCTAssertTrue(deduplicator.shouldDrop(type: 5, detail: 0, sourcePID: 123, eventTimestamp: 257, flags: 0, time: 10.01))
    }
}
