import XCTest
@testable import HarnessCore

final class RuntimeEventIdTests: XCTestCase {
    func testEventIdFormatMatchesUpstreamShape() {
        let id = RuntimeEvent.newEventId()
        XCTAssertTrue(id.hasPrefix("ev-"), "id should start with ev-: \(id)")
        let segments = id.split(separator: "-")
        XCTAssertEqual(segments.count, 3, "ev-<base36 ms>-<base36 counter>: \(id)")

        // Segment 1: base36 milliseconds timestamp.
        let millis = Int(String(segments[1]), radix: 36)
        XCTAssertNotNil(millis, "timestamp segment must be valid base36: \(segments[1])")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(millis! - now), 60_000, "timestamp segment should be current time in ms")

        // Segment 2: base36 monotonically increasing counter.
        XCTAssertNotNil(Int(String(segments[2]), radix: 36), "counter segment must be valid base36: \(segments[2])")
    }

    func testEventIdsAreUniqueAcrossCalls() {
        let ids = (0..<1000).map { _ in RuntimeEvent.newEventId() }
        XCTAssertEqual(Set(ids).count, ids.count, "event ids must be unique")
    }

    func testCounterIncrementsMonotonically() throws {
        // Two calls within the same millisecond still differ by the counter.
        let first = RuntimeEvent.newEventId()
        let second = RuntimeEvent.newEventId()
        XCTAssertNotEqual(first, second)

        let firstCount = try XCTUnwrap(Int(first.split(separator: "-")[2].description, radix: 36))
        let secondCount = try XCTUnwrap(Int(second.split(separator: "-")[2].description, radix: 36))
        XCTAssertEqual(secondCount, firstCount + 1)
    }

    func testNewIdIsLowercaseUUIDShaped() {
        let id = RuntimeEvent.newId()
        XCTAssertEqual(id, id.lowercased())
        XCTAssertFalse(id.contains("EV-"))
        // UUID without dashes is still 32 hex chars; with dashes, 36.
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit || $0 == "-" })
    }
}
