import XCTest
@testable import HarnessCore

final class JSONValueTests: XCTestCase {
    // ── round trips ───────────────────────────────────────────────────────

    func testRoundTripNestedStructure() throws {
        let original: JSONValue = [
            "id": "inst-1",
            "enabled": true,
            "count": 7,
            "ratio": 0.5,
            "tags": ["alpha", "beta"],
            "nested": ["deep": ["deeper": [1, 2, 3]]],
            "nothing": .null,
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(decoded)), decoded)
    }

    func testDecodeEveryScalarShape() throws {
        let value = try decodeFromJSON(
            JSONValue.self,
            #"{"n": null, "t": true, "f": false, "i": 42, "d": 4.25, "s": "hi", "a": [], "o": {}}"#
        )
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["t"], .bool(true))
        XCTAssertEqual(value["f"], .bool(false))
        XCTAssertEqual(value["i"], .int(42))
        XCTAssertEqual(value["d"], .double(4.25))
        XCTAssertEqual(value["s"], .string("hi"))
        XCTAssertEqual(value["a"], .array([]))
        XCTAssertEqual(value["o"], .object([:]))
    }

    /// Decode order pitfall: a bool probe must run before the int probe or
    /// `true` decodes as 1.
    func testBoolDecodesBeforeInt() throws {
        let value = try decodeFromJSON(JSONValue.self, #"[true, false]"#)
        XCTAssertEqual(value.arrayValue?.first, .bool(true))
        XCTAssertEqual(value.arrayValue?.last, .bool(false))

        let options: JSONSerialization.ReadingOptions = [.fragmentsAllowed]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.bool(true)), options: options)
        XCTAssertEqual(encoded as? Bool, true)
    }

    func testIntAndDoubleStayDistinct() throws {
        let value = try decodeFromJSON(JSONValue.self, #"[42, 42.5]"#)
        guard case .array(let items) = value else {
            return XCTFail("expected array")
        }
        if case .int(let i) = items[0] { XCTAssertEqual(i, 42) } else { XCTFail("expected int, got \(items[0])") }
        if case .double(let d) = items[1] { XCTAssertEqual(d, 42.5) } else { XCTFail("expected double, got \(items[1])") }

        // Integral decimals ("2.0") decode through the int branch because
        // this ordering keeps huge integers exact (a double probe first
        // would corrupt e.g. 9007199254740993). Value-equality still holds.
        let decimal = try decodeFromJSON(JSONValue.self, "2.0")
        XCTAssertTrue(decimal == .int(2) || decimal == .double(2), "expected numeric 2, got \(decimal)")
    }

    func testLargeIntStaysExact() throws {
        // Beyond Double precision — decoding through double first would corrupt it.
        let json = #"{"big": 9007199254740993}"#
        let value = try decodeFromJSON(JSONValue.self, json)
        XCTAssertEqual(value["big"], .int(9_007_199_254_740_993))
    }

    // ── literal initializers ──────────────────────────────────────────────

    func testLiteralInitializers() {
        let boolLiteral: JSONValue = true
        let intLiteral: JSONValue = -12
        let floatLiteral: JSONValue = 1.5
        let stringLiteral: JSONValue = "hello"
        let arrayLiteral: JSONValue = [1, 2, 3]
        let dictLiteral: JSONValue = ["a": 1, "b": "two"]

        XCTAssertEqual(boolLiteral, .bool(true))
        XCTAssertEqual(intLiteral, .int(-12))
        XCTAssertEqual(floatLiteral, .double(1.5))
        XCTAssertEqual(stringLiteral, .string("hello"))
        XCTAssertEqual(arrayLiteral, .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(dictLiteral["b"], .string("two"))
    }

    // ── accessors ─────────────────────────────────────────────────────────

    func testTypedAccessors() throws {
        let value = try decodeFromJSON(JSONValue.self, #"{"i": 5, "d": 6.5, "s": "x", "b": true}"#)
        XCTAssertEqual(value["i"]?.intValue, 5)
        XCTAssertEqual(value["d"]?.doubleValue, 6.5)
        XCTAssertEqual(value["s"]?.stringValue, "x")
        XCTAssertEqual(value["b"]?.boolValue, true)
        // int promotes to double; double does not demote to int
        XCTAssertEqual(value["i"]?.doubleValue, 5.0)
        XCTAssertNil(value["d"]?.intValue)
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["s"]?.intValue)
    }

    func testSubscriptOnNonObjectReturnsNil() {
        XCTAssertEqual(JSONValue.string("nope")["key"], nil)
        XCTAssertEqual((.null as JSONValue)["key"], nil)
    }

    func testEncodingProducesCanonicalJSON() throws {
        let encoded = String(
            data: try JSONEncoder().encode(JSONValue.object(["z": .int(1), "a": .string("x")])),
            encoding: .utf8
        )
        // Dictionary key order is not guaranteed, so parse back instead of string-comparing.
        let reparsed = try JSONSerialization.jsonObject(with: Data(encoded!.utf8)) as? [String: Any]
        XCTAssertEqual(reparsed?["z"] as? Int, 1)
        XCTAssertEqual(reparsed?["a"] as? String, "x")
    }
}
