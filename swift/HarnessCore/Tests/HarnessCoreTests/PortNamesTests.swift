import Foundation
import XCTest
@testable import HarnessCore

final class PortNamesTests: XCTestCase {
    func testPicksAvoidTakenNames() {
        let taken = Names.pool.prefix(20).map { $0 }
        for _ in 0..<50 {
            let picked = Names.pickBotName(taken: taken)
            XCTAssertFalse(
                taken.map { $0.lowercased() }.contains(picked.lowercased()),
                "picked name must not collide with a taken one")
            XCTAssertTrue(Names.pool.contains(where: { $0.caseInsensitiveCompare(picked) == .orderedSame })
                || picked.contains(" "),
                "picked names come from the pool until it is exhausted")
        }
    }

    func testExhaustedPoolNumbersAFallbackName() {
        let taken = Names.pool
        var results = Set<String>()
        for _ in 0..<25 {
            let picked = Names.pickBotName(taken: taken)
            XCTAssertTrue(picked.hasSuffix(" 2") || picked.hasSuffix(" 3"),
                          "numbered fallback like 'Scout 2' is produced, got \(picked)")
            results.insert(picked)
        }
        XCTAssertFalse(results.isEmpty)
    }

    func testTakenNamesAreTrimmedAndCaseInsensitive() {
        // Nothing taken → always a pool name.
        let picked = Names.pickBotName(taken: ["  scout ", "PIXEL"])
        XCTAssertFalse(["scout", "pixel"].contains(picked.lowercased()))
    }
}
