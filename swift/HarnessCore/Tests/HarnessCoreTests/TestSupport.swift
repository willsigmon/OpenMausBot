import Foundation
import XCTest
@testable import HarnessCore

// Shared helpers for the HarnessCore test target. Internal on purpose so
// every suite file can use them without re-import gymnastics.

/// Encodes a value and hands back its top-level JSON object for key-level
/// assertions (presence, absence, exact discriminator strings).
func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
}

/// Decodes a type from an inline JSON fixture string.
func decodeFromJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
