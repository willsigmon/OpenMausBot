import Foundation

// Keeping secrets out of the canonical NDJSON logs — the port of
// server/redact.ts.
//
// The bus tees every provider event verbatim, which is what makes protocol
// drift diagnosable — but the messages that set a session up carry the
// credentials the agent is handed. Those logs sit in ~/.openmausbot/events
// as ordinary files, are read by anyone debugging, and get pasted into
// issues. So the log keeps the SHAPE and loses the VALUES: a redacted entry
// still tells you a token was passed, under which name, and how long it
// was — enough to debug without the token being there.

/// Key names whose value is a credential. Matched case-insensitively as a
/// substring, so KEY catches ANTHROPIC_API_KEY and x-api-key.
private let secretKeyParts = [
    "token", "secret", "password", "passwd", "apikey", "api_key", "authorization", "auth_token",
]

/// `key` alone is too broad — it matches `keyboard`, `keys`, `hotkey`. Only
/// treat it as a credential when it stands alone or is a suffix, which is
/// how every real one is spelled (API_KEY, consumer-key, xai_key).
func isSecretName(_ name: String) -> Bool {
    let lower = name.lowercased()
    if secretKeyParts.contains(where: { lower.contains($0) }) { return true }
    // (^|[_.-])keys?$ — bare or suffixed "key"/"keys" only
    return lower.range(of: "(^|[_.-])keys?$", options: .regularExpression) != nil
}

private func mask(_ value: String) -> String { "«redacted \(value.count) chars»" }

// ── content-shaped secrets ────────────────────────────────────────────────
// What a bot's own reply, a tool title, or a permission card can carry.
// High precision on purpose: a generic "long hex/base64" heuristic would
// rewrite real code in the transcript, so only shapes that are
// unmistakably credentials match.

private let keyPrefixPatterns: [String] = [
    #"\bsk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_-]{16,}"#,                    // anthropic / openai / stripe
    #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,                            // github classic
    #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,                                        // github fine-grained
    #"\bxox[abposr]-[A-Za-z0-9-]{20,}"#,                                       // slack
    #"\bAKIA[0-9A-Z]{16}\b"#,                                                  // aws access key id
    #"\bAIza[0-9A-Za-z_-]{30,}"#,                                              // google api key
    #"\bnpm_[A-Za-z0-9]{20,}"#,                                                // npm
    #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,        // jwt
]
private let bearerPattern = #"(\bBearer\s+)([A-Za-z0-9._~+/=-]{12,})"#
private let pemOpenPattern = #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#
private let pemClosePattern = #"-----END [A-Z ]*PRIVATE KEY-----"#
/// key=value / key: value / key="value" where the key is secret-shaped. The
/// value must be a single token of some length; prose after a colon
/// ("password: leave blank…") has spaces and does not match.
private let keyValuePattern =
    #"\b((?:[A-Za-z0-9_-]*_)?(?:api[_-]?key|apikey|secret|token|password|passwd|authorization|auth[_-]?token|access[_-]?key|private[_-]?key)s?)(["']?\s*[=:]\s*)(["']?)([A-Za-z0-9._~+/=-]{8,})\3"#

public enum Redact {
    public static func secretsInText(_ text: String) -> String {
        guard text.count >= 8 else { return text }
        var out = text

        // PEM block first: open + masked body + close (body may span lines).
        out = redactPemBlocks(out)

        for pattern in keyPrefixPatterns {
            out = replaceMatches(in: out, pattern: pattern, options: []) { _, fullMatch in
                mask(fullMatch)
            }
        }
        out = replaceMatches(in: out, pattern: bearerPattern, options: [.caseInsensitive]) { groups, _ in
            let lead = groups.first ?? ""
            let token = groups.last ?? ""
            return lead + mask(token)
        }
        out = replaceMatches(in: out, pattern: keyValuePattern, options: [.caseInsensitive]) { groups, _ in
            // [key, separator, quote, value] — rebuild with masked value,
            // keeping any quote character on both sides.
            let parts = groups
            guard parts.count == 4 else { return parts.joined() }
            let key = parts[0], sep = parts[1], quote = parts[2], value = parts[3]
            return "\(key)\(sep)\(quote)\(mask(value))\(quote)"
        }
        return out
    }

    /// Deep copy of untyped JSON with credential VALUES replaced. Handles
    /// the two shapes that actually carry them: a plain object of env vars
    /// ({KEY: "v"}) and the ACP wire shape ({name, value}). Anything
    /// unrecognized is copied as-is.
    public static func secrets(_ input: JSONValue, depth: Int = 0) -> JSONValue {
        switch input {
        case .string(let text):
            return .string(secretsInText(text))
        case .array(let items):
            return .array(items.map { item in
                // ACP env entries: {name: "OMB_COMMS_TOKEN", value: "…"}
                if let obj = item.objectValue,
                   case .string(let name) = obj["name"],
                   case .string(let value) = obj["value"]
                {
                    guard isSecretName(name) else { return Redact.secrets(item, depth: depth + 1) }
                    var masked = obj
                    masked["value"] = .string(mask(value))
                    return .object(masked)
                }
                return Redact.secrets(item, depth: depth + 1)
            })
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, value) in object {
                if case .string(let stringValue) = value, isSecretName(key) {
                    out[key] = .string(mask(stringValue))
                    continue
                }
                // any other string may still CONTAIN a credential (a command
                // line, a header value, a bot's reply) — the content pass
                // catches those
                out[key] = secrets(value, depth: depth + 1)
            }
            return .object(out)
        case .null, .bool, .int, .double:
            if depth > 12 { return input }
            return input
        }
    }

    // ── regex plumbing ────────────────────────────────────────────────────

    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options,
        build: ([String], _ fullMatch: String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            result += String(text[cursor..<matchRange.lowerBound])
            let fullMatch = String(text[matchRange])
            var groups: [String] = []
            if match.numberOfRanges > 1 {
                for i in 1..<match.numberOfRanges {
                    if let groupRange = Range(match.range(at: i), in: text) {
                        groups.append(String(text[groupRange]))
                    } else {
                        groups.append("")
                    }
                }
            }
            result += build(groups, fullMatch)
            cursor = matchRange.upperBound
        }
        result += String(text[cursor...])
        return result
    }

    private static func redactPemBlocks(_ text: String) -> String {
        guard
            let openRegex = try? NSRegularExpression(pattern: pemOpenPattern),
            let closeRegex = try? NSRegularExpression(pattern: pemClosePattern)
        else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        var pairs: [(openEnd: Int, closeStart: Int, closeEnd: Int)] = []

        openRegex.enumerateMatches(in: text, options: [], range: fullRange) { openMatch, _, stop in
            guard let openMatch else { return }
            guard openMatch.range.location != NSNotFound,
                  openMatch.range.upperBound <= (text as NSString).length
            else { return }
            let restLength = (text as NSString).length - openMatch.range.upperBound
            guard restLength > 0 else { return }
            if let closeMatch = closeRegex.firstMatch(
                in: text, options: [],
                range: NSRange(location: openMatch.range.upperBound, length: restLength))
            {
                pairs.append((openMatch.range.upperBound, closeMatch.range.lowerBound, closeMatch.range.upperBound))
                if pairs.count >= 64 { stop.pointee = true }
            }
        }

        guard !pairs.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for pair in pairs {
            let nsText = text as NSString
            guard pair.openEnd >= cursor, pair.closeStart >= pair.openEnd else { continue }
            result += nsText.substring(with: NSRange(location: cursor, length: pair.openEnd - cursor))
            let body = nsText.substring(with: NSRange(location: pair.openEnd, length: pair.closeStart - pair.openEnd))
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            result += "\n\(mask(trimmed))\n"
            cursor = pair.closeStart
        }
        result += (text as NSString).substring(from: cursor)
        return result
    }
}
