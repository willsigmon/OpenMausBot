import Foundation
import XCTest
@testable import HarnessCore

final class PortRedactTests: XCTestCase {
    func testMaskShapeMatchesUpstream() {
        let masked = Redact.secretsInText("token sk-ant-api03-abcdefghijklmnop here")
        XCTAssertTrue(masked.contains("«redacted "), "mask format matches upstream")
        XCTAssertFalse(masked.contains("sk-ant-api03-abcdefghijklmnop"))
        // The mask carries the original length.
        let length = "sk-ant-api03-abcdefghijklmnop".count
        XCTAssertTrue(masked.contains("«redacted \(length) chars»"))
    }

    func testKeyNamedObjectsAreMaskedWhole() {
        let redacted = Redact.secrets(.object([
            "ANTHROPIC_API_KEY": .string("sk-ant-verysecret"),
            "x-api-key": .string("another-secret"),
            "keyboard": .string("not a secret"),
            "nested": .object(["BOX_TOKEN": .string("box-secret")]),
            "env": .array([
                .object(["name": .string("OMB_COMMS_TOKEN"), "value": .string("comms-secret")]),
                .object(["name": .string("PLAIN"), "value": .string("visible value")]),
            ]),
        ]))
        XCTAssertEqual(redacted["ANTHROPIC_API_KEY"]?.stringValue, "«redacted 17 chars»")
        XCTAssertEqual(redacted["x-api-key"]?.stringValue, "«redacted 14 chars»")
        XCTAssertEqual(redacted["keyboard"]?.stringValue, "not a secret", "key-shaped non-secrets survive")
        XCTAssertEqual(redacted["nested"]?["BOX_TOKEN"]?.stringValue, "«redacted 10 chars»")
        XCTAssertEqual(redacted["env"]?.arrayValue?[0]["value"]?.stringValue, "«redacted 12 chars»",
                       "ACP {name,value} env entries are masked by name")
        XCTAssertEqual(redacted["env"]?.arrayValue?[1]["value"]?.stringValue, "visible value")
    }

    func testContentShapedSecretsInPlainText() {
        // key=value / key: value forms.
        let kv = Redact.secretsInText(#"failed with OPENAI_API_KEY=sk-proj-0123456789abcdef retry"#)
        XCTAssertTrue(kv.contains("OPENAI_API_KEY="))
        XCTAssertTrue(kv.contains("«redacted"))
        XCTAssertFalse(kv.contains("sk-proj-0123456789abcdef"))

        // Bearer tokens.
        let bearer = Redact.secretsInText("auth header Bearer abcdef1234567890 sent")
        XCTAssertTrue(bearer.contains("Bearer "))
        XCTAssertTrue(bearer.contains("«redacted 16 chars»"))
        XCTAssertFalse(bearer.contains("abcdef1234567890"))

        // Short strings are left alone (the <8 guard).
        XCTAssertEqual(Redact.secretsInText("short"), "short")

        // Prose after a colon has spaces and does not match the value rule.
        let prose = Redact.secretsInText("password: leave blank please ok")
        XCTAssertFalse(prose.contains("«redacted"), "prose is not mistaken for a credential token")
    }

    func testPemBlocksAreMaskedKeepingDelimiters() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA1234567890
        more secret body lines here
        -----END RSA PRIVATE KEY-----
        """
        let redacted = Redact.secretsInText(pem)
        XCTAssertTrue(redacted.contains("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertTrue(redacted.contains("-----END RSA PRIVATE KEY-----"))
        XCTAssertFalse(redacted.contains("MIIEpAIBAAKCAQEA1234567890"))
        XCTAssertTrue(redacted.contains("«redacted"))
    }
}
