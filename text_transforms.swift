// Trove — Dev Text Transforms pane.
//
// Differentiators vs Boop / DevUtils / TextSoap:
//   1. Chainable pipelines — compose a sequence of transforms; output of step N
//      feeds step N+1. Visual chip list, drag-to-reorder, per-chip delete.
//   2. Real-time preview at every stage — click a chip to inspect intermediate
//      output (the unique killer feature this tool exists for).
//   3. 30+ transforms across Encoding / Format / Crypto / Case / JWT / UUID /
//      Number / Lines / Regex.
//   4. Auto-detect of input shape (JWT, URL, JSON, base64, hex, UUID, ISO time)
//      with one-click "suggested" chips that prepend the right pipeline.
//
// Hard rules respected: no `@main`, no `App`, no new `Pane` case, all types
// prefixed `Xform*`, no top-level executable statements.

import SwiftUI
import Foundation
import CryptoKit
import AppKit
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Transform registry
// ===========================================================================

/// Stable identifier for a transform. Stored in pipeline chips and on disk-safe
/// for persistence in the future. Adding a new transform = add an `XformKind`
/// case + entry in `XformCatalog`.
enum XformKind: String, CaseIterable, Identifiable, Codable, Hashable {
    // Encoding
    case base64Encode, base64Decode
    case urlEncode, urlDecode
    case htmlEncode, htmlDecode
    case hexEncode, hexDecode
    // Format
    case jsonPretty, jsonMinify, jsonSortKeys
    case yamlPretty, xmlPretty
    // Crypto (CryptoKit — never CommonCrypto)
    case md5, sha1, sha256, sha512
    // Case
    case upper, lower, title, sentence, camel, snake, kebab, constant
    // JWT
    case jwtDecode
    // UUID
    case uuidV4, uuidV7, uuidFormat
    // Number
    case decToHex, hexToDec, decToBin, binToDec
    // Lines
    case linesSort, linesReverse, linesDedupe, linesCount, linesTrim
    case linesAddPrefix, linesAddSuffix
    // Regex
    case regexExtract, regexReplace

    var id: String { rawValue }
}

enum XformCategory: String, CaseIterable, Identifiable {
    case encoding = "Encoding"
    case format   = "Format"
    case crypto   = "Crypto"
    case caseConv = "Case"
    case jwt      = "JWT"
    case uuid     = "UUID"
    case number   = "Number"
    case lines    = "Lines"
    case regex    = "Regex"
    var id: String { rawValue }
}

/// Static info about each transform. `parameterized` means the chip needs a
/// configuration popover (regex pattern, prefix/suffix text, etc.).
struct XformDescriptor: Identifiable, Hashable {
    let kind: XformKind
    let title: String
    let category: XformCategory
    let parameterized: Bool
    var id: XformKind { kind }
}

enum XformCatalog {
    static let all: [XformDescriptor] = [
        // Encoding
        .init(kind: .base64Encode, title: "Base64 encode",  category: .encoding, parameterized: false),
        .init(kind: .base64Decode, title: "Base64 decode",  category: .encoding, parameterized: false),
        .init(kind: .urlEncode,    title: "URL encode",     category: .encoding, parameterized: false),
        .init(kind: .urlDecode,    title: "URL decode",     category: .encoding, parameterized: false),
        .init(kind: .htmlEncode,   title: "HTML encode",    category: .encoding, parameterized: false),
        .init(kind: .htmlDecode,   title: "HTML decode",    category: .encoding, parameterized: false),
        .init(kind: .hexEncode,    title: "Hex encode",     category: .encoding, parameterized: false),
        .init(kind: .hexDecode,    title: "Hex decode",     category: .encoding, parameterized: false),
        // Format
        .init(kind: .jsonPretty,   title: "JSON pretty",    category: .format,   parameterized: false),
        .init(kind: .jsonMinify,   title: "JSON minify",    category: .format,   parameterized: false),
        .init(kind: .jsonSortKeys, title: "JSON sort keys", category: .format,   parameterized: false),
        // red-team: titled "tidy" not "pretty" — no real YAML parser ships here.
        .init(kind: .yamlPretty,   title: "YAML tidy",      category: .format,   parameterized: false),
        .init(kind: .xmlPretty,    title: "XML pretty",     category: .format,   parameterized: false),
        // Crypto
        .init(kind: .md5,          title: "MD5",            category: .crypto,   parameterized: false),
        .init(kind: .sha1,         title: "SHA-1",          category: .crypto,   parameterized: false),
        .init(kind: .sha256,       title: "SHA-256",        category: .crypto,   parameterized: false),
        .init(kind: .sha512,       title: "SHA-512",        category: .crypto,   parameterized: false),
        // Case
        .init(kind: .upper,        title: "UPPER CASE",     category: .caseConv, parameterized: false),
        .init(kind: .lower,        title: "lower case",     category: .caseConv, parameterized: false),
        .init(kind: .title,        title: "Title Case",     category: .caseConv, parameterized: false),
        .init(kind: .sentence,     title: "Sentence case",  category: .caseConv, parameterized: false),
        .init(kind: .camel,        title: "camelCase",      category: .caseConv, parameterized: false),
        .init(kind: .snake,        title: "snake_case",     category: .caseConv, parameterized: false),
        .init(kind: .kebab,        title: "kebab-case",     category: .caseConv, parameterized: false),
        .init(kind: .constant,     title: "CONSTANT_CASE",  category: .caseConv, parameterized: false),
        // JWT
        .init(kind: .jwtDecode,    title: "Decode JWT",     category: .jwt,      parameterized: false),
        // UUID
        .init(kind: .uuidV4,       title: "Generate UUID v4", category: .uuid,   parameterized: false),
        .init(kind: .uuidV7,       title: "Generate UUID v7", category: .uuid,   parameterized: false),
        .init(kind: .uuidFormat,   title: "Format UUID",    category: .uuid,     parameterized: false),
        // Number
        .init(kind: .decToHex,     title: "Decimal → Hex",  category: .number,   parameterized: false),
        .init(kind: .hexToDec,     title: "Hex → Decimal",  category: .number,   parameterized: false),
        .init(kind: .decToBin,     title: "Decimal → Binary", category: .number, parameterized: false),
        .init(kind: .binToDec,     title: "Binary → Decimal", category: .number, parameterized: false),
        // Lines
        .init(kind: .linesSort,      title: "Sort lines",       category: .lines, parameterized: false),
        .init(kind: .linesReverse,   title: "Reverse lines",    category: .lines, parameterized: false),
        .init(kind: .linesDedupe,    title: "Dedupe lines",     category: .lines, parameterized: false),
        .init(kind: .linesCount,     title: "Count lines",      category: .lines, parameterized: false),
        .init(kind: .linesTrim,      title: "Trim each line",   category: .lines, parameterized: false),
        .init(kind: .linesAddPrefix, title: "Prefix each line", category: .lines, parameterized: true),
        .init(kind: .linesAddSuffix, title: "Suffix each line", category: .lines, parameterized: true),
        // Regex
        .init(kind: .regexExtract,   title: "Regex extract",  category: .regex,  parameterized: true),
        .init(kind: .regexReplace,   title: "Regex replace",  category: .regex,  parameterized: true),
    ]

    static func descriptor(_ k: XformKind) -> XformDescriptor {
        // Hardest-standards rule: a missing-kind developer mistake must not
        // crash the UI in production. The lookup falls through to a synthetic
        // descriptor (kind echoed as title, category=format, non-parameterized)
        // so the chip still renders. `assertionFailure` flags the omission in
        // dev builds, NSLog leaves a breadcrumb in release crash reports.
        if let d = all.first(where: { $0.kind == k }) { return d }
        NSLog("XformCatalog: descriptor missing for kind %@ — add an entry to XformCatalog.all", k.rawValue)
        assertionFailure("XformCatalog: descriptor missing for kind \(k.rawValue)")
        return XformDescriptor(kind: k, title: k.rawValue, category: .format, parameterized: false)
    }
}

// ===========================================================================
// MARK: - Errors
// ===========================================================================

struct XformError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { self.message = m }
}

// ===========================================================================
// MARK: - Pipeline step
// ===========================================================================

/// One chip in the pipeline. Carries its own kind + parameter bag.
struct XformStep: Identifiable, Hashable {
    let id = UUID()
    var kind: XformKind
    /// `param1` is the primary user-supplied argument (regex pattern, prefix text).
    var param1: String = ""
    /// `param2` is a secondary argument (regex replacement).
    var param2: String = ""

    var title: String { XformCatalog.descriptor(kind).title }
}

/// Result of running one step. Either we got a string, or we caught an error.
/// Downstream steps short-circuit to `.skipped` so the chip list stays informative.
enum XformStepOutcome {
    case ok(String)
    case error(String)
    case skipped
}

// ===========================================================================
// MARK: - Transform engine
// ===========================================================================

enum XformEngine {

    /// Run every step in order, returning each step's outcome (parallel array
    /// to `steps`) and the final string (last successful output, falling back
    /// to the input if nothing ran).
    static func run(input: String, steps: [XformStep]) -> (outcomes: [XformStepOutcome], output: String) {
        var current = input
        var outcomes: [XformStepOutcome] = []
        var failed = false
        for s in steps {
            if failed {
                outcomes.append(.skipped)
                continue
            }
            switch apply(s, to: current) {
            case .success(let next):
                outcomes.append(.ok(next))
                current = next
            case .failure(let err):
                outcomes.append(.error(err.localizedDescription))
                failed = true
            }
        }
        return (outcomes, current)
    }

    static func apply(_ step: XformStep, to input: String) -> Result<String, Error> {
        do {
            return .success(try perform(step, on: input))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Per-kind implementations

    private static func perform(_ step: XformStep, on s: String) throws -> String {
        switch step.kind {
        // Encoding
        case .base64Encode:
            guard let d = s.data(using: .utf8) else { throw XformError("input not UTF-8") }
            return d.base64EncodedString()
        case .base64Decode:
            // Accept both std and url-safe alphabets; pad as needed.
            let normalized = base64Normalize(s)
            guard let d = Data(base64Encoded: normalized) else { throw XformError("not valid Base64") }
            return String(data: d, encoding: .utf8) ?? d.map { String(format: "%02x", $0) }.joined()
        case .urlEncode:
            return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        case .urlDecode:
            return s.removingPercentEncoding ?? s
        case .htmlEncode:
            return htmlEscape(s)
        case .htmlDecode:
            return htmlUnescape(s)
        case .hexEncode:
            guard let d = s.data(using: .utf8) else { throw XformError("input not UTF-8") }
            return d.map { String(format: "%02x", $0) }.joined()
        case .hexDecode:
            let cleaned = s.filter { !$0.isWhitespace }
            guard cleaned.count % 2 == 0 else { throw XformError("hex length must be even") }
            var out = Data(capacity: cleaned.count / 2)
            var idx = cleaned.startIndex
            while idx < cleaned.endIndex {
                let next = cleaned.index(idx, offsetBy: 2)
                guard let b = UInt8(cleaned[idx..<next], radix: 16) else {
                    throw XformError("non-hex character at offset \(cleaned.distance(from: cleaned.startIndex, to: idx))")
                }
                out.append(b)
                idx = next
            }
            return String(data: out, encoding: .utf8) ?? out.map { String(format: "%02x", $0) }.joined()

        // Format
        case .jsonPretty:
            return try jsonReformat(s, sortKeys: false, minify: false)
        case .jsonMinify:
            return try jsonReformat(s, sortKeys: false, minify: true)
        case .jsonSortKeys:
            return try jsonReformat(s, sortKeys: true, minify: false)
        case .yamlPretty:
            // red-team: we don't ship a YAML parser. This is a textual TIDY —
            // not a true structural reformat. For complex YAML (anchors,
            // flow-style nested maps, multi-line literals) it will not
            // restructure anything. Documented behavior: collapse blank-line
            // runs, trim trailing whitespace, normalize tabs→two-spaces.
            return yamlTidy(s)
        case .xmlPretty:
            return try xmlPretty(s)

        // Crypto — CryptoKit, never deprecated CommonCrypto.
        case .md5:
            let d = Data(s.utf8)
            return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        case .sha1:
            let d = Data(s.utf8)
            return Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined()
        case .sha256:
            let d = Data(s.utf8)
            return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        case .sha512:
            let d = Data(s.utf8)
            return SHA512.hash(data: d).map { String(format: "%02x", $0) }.joined()

        // Case
        case .upper:    return s.uppercased()
        case .lower:    return s.lowercased()
        case .title:    return s.capitalized
        case .sentence: return sentenceCase(s)
        case .camel:    return tokenCase(s, joiner: "", upperFirst: false, upperRest: true)
        case .snake:    return tokenCase(s, joiner: "_", upperFirst: false, upperRest: false)
        case .kebab:    return tokenCase(s, joiner: "-", upperFirst: false, upperRest: false)
        case .constant: return tokenCase(s, joiner: "_", upperFirst: true,  upperRest: true).uppercased()

        // JWT
        case .jwtDecode:
            return try decodeJWT(s)

        // UUID
        case .uuidV4:
            return UUID().uuidString
        case .uuidV7:
            return makeUUIDv7().uuidString
        case .uuidFormat:
            // Strip braces, hyphens, whitespace then re-insert canonical hyphens.
            let hex = s.filter { $0.isHexDigit }
            guard hex.count == 32 else { throw XformError("expected 32 hex chars; got \(hex.count)") }
            let chars = Array(hex.uppercased())
            return "\(String(chars[0..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))-\(String(chars[16..<20]))-\(String(chars[20..<32]))"

        // Number
        case .decToHex:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = Int64(trimmed) else { throw XformError("not a decimal integer") }
            return String(n, radix: 16)
        case .hexToDec:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                     .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            guard let n = Int64(t, radix: 16) else { throw XformError("not a hex integer") }
            return String(n)
        case .decToBin:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = Int64(trimmed) else { throw XformError("not a decimal integer") }
            return String(n, radix: 2)
        case .binToDec:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                     .replacingOccurrences(of: "0b", with: "", options: [.caseInsensitive])
            guard let n = Int64(t, radix: 2) else { throw XformError("not a binary integer") }
            return String(n)

        // Lines (preserve LF vs CRLF unless the transform inherently rewrites it)
        case .linesSort:
            let (lines, sep) = splitLinesPreservingSeparator(s)
            return lines.sorted().joined(separator: sep)
        case .linesReverse:
            let (lines, sep) = splitLinesPreservingSeparator(s)
            return lines.reversed().joined(separator: sep)
        case .linesDedupe:
            let (lines, sep) = splitLinesPreservingSeparator(s)
            var seen = Set<String>(); var out: [String] = []
            for l in lines where seen.insert(l).inserted { out.append(l) }
            return out.joined(separator: sep)
        case .linesCount:
            let (lines, _) = splitLinesPreservingSeparator(s)
            return "\(lines.count)"
        case .linesTrim:
            let (lines, sep) = splitLinesPreservingSeparator(s)
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: sep)
        case .linesAddPrefix:
            let (lines, sep) = splitLinesPreservingSeparator(s)
            return lines.map { step.param1 + $0 }.joined(separator: sep)
        case .linesAddSuffix:
            let (lines, sep) = splitLinesPreservingSeparator(s)
            return lines.map { $0 + step.param1 }.joined(separator: sep)

        // Regex
        case .regexExtract:
            guard !step.param1.isEmpty else { throw XformError("regex pattern is empty") }
            // red-team: refuse pathologically catastrophic patterns up-front so a
            // user-pasted `(.*)+` against 50 MB doesn't freeze the main actor.
            // NSRegularExpression has no built-in timeout; cheap structural reject
            // is the only safe guard without moving the engine off-main.
            try rejectCatastrophicRegex(step.param1, inputBytes: s.utf8.count)
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: step.param1, options: [])
            } catch {
                throw XformError("invalid regex: \(error.localizedDescription)")
            }
            let ns = s as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = regex.matches(in: s, range: range)
            return matches.map { ns.substring(with: $0.range) }.joined(separator: "\n")
        case .regexReplace:
            guard !step.param1.isEmpty else { throw XformError("regex pattern is empty") }
            // red-team: same catastrophic-backtracking guard as regexExtract.
            try rejectCatastrophicRegex(step.param1, inputBytes: s.utf8.count)
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: step.param1, options: [])
            } catch {
                throw XformError("invalid regex: \(error.localizedDescription)")
            }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            let output = regex.stringByReplacingMatches(in: s, range: range, withTemplate: step.param2)
            // red-team: a replace-all with a large template can balloon output
            // beyond the 50 MB input refuse threshold. Cap here so downstream
            // pipeline steps don't choke on pathological expansion.
            if output.utf8.count > XformModel.refuseBytes {
                throw XformError("regex replacement output exceeds 50 MB — refusing to return result")
            }
            return output
        }
    }
}

// ===========================================================================
// MARK: - Helpers used by the engine
// ===========================================================================

/// Restore base64url → base64 and pad to a multiple of four. Tolerant decoder.
// red-team: catastrophic-backtracking guard. NSRegularExpression has no
// timeout, so we unconditionally reject patterns that nest unbounded
// quantifiers (`(.*)+`, `(a+)+`, `(.+)*`, `(\w+\s?)+`, `(a*b*)+`, `([a-z]+)+`)
// which can take exponential time. Threshold lowered to 0 so even tiny inputs
// are protected — hung UI on any size input is unacceptable.
// This is a heuristic — false positives are acceptable because the user can
// rewrite the pattern; false negatives (hung UI) are not.
private func rejectCatastrophicRegex(_ pattern: String, inputBytes: Int) throws {
    // Always check, regardless of input size.
    _ = inputBytes
    // Category 1: group ending in a quantifier that is itself quantified.
    // Cheap textual check: detect "*)+", "+)+", "*)*", "+)*", "*)?+", etc.
    let danger = ["*)+", "+)+", "*)*", "+)*", "*)?", "+)?",
                  // Additional: groups with a nested quantifier followed by outer *
                  "*)+" , "+)+", "?)+",
                  // Outer * variants
                  "*)*", "+)*", "?)*"]
    for d in danger where pattern.contains(d) {
        throw XformError("pattern looks catastrophic (\(d)) — refusing to run")
    }
    // Category 2: two or more * or + quantifiers where one is inside a group
    // that itself carries a * or + quantifier. Heuristic: count total `*` and `+`
    // chars; if there are 2+, and the pattern also contains `)+` or `)*` or
    // `)?` patterns (outer quantifier on a group), reject it.
    let quantCount = pattern.filter { $0 == "*" || $0 == "+" }.count
    let hasOuterGroupQuant = pattern.contains(")+") || pattern.contains(")*") || pattern.contains(")?")
    if quantCount >= 2 && hasOuterGroupQuant {
        throw XformError("pattern contains nested quantifiers inside a quantified group — refusing to run")
    }
}

private func base64Normalize(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "-", with: "+")
             .replacingOccurrences(of: "_", with: "/")
             .replacingOccurrences(of: "\n", with: "")
             .replacingOccurrences(of: "\r", with: "")
             .replacingOccurrences(of: " ",  with: "")
    let mod = t.count % 4
    if mod > 0 { t.append(String(repeating: "=", count: 4 - mod)) }
    return t
}

private func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&":  out += "&amp;"
        case "<":  out += "&lt;"
        case ">":  out += "&gt;"
        case "\"": out += "&quot;"
        case "'":  out += "&#39;"
        default:   out.append(c)
        }
    }
    return out
}

private func htmlUnescape(_ s: String) -> String {
    // Cover the common named entities + numeric (decimal & hex) refs.
    var out = s
    let pairs: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&nbsp;", " "),
    ]
    for (k, v) in pairs { out = out.replacingOccurrences(of: k, with: v) }
    // Numeric: &#NNN; and &#xHH; (also &#X.. — uppercase hex prefix is legal HTML5)
    do {
        // red-team: pattern was `x?` (lowercase only). Real-world HTML emits
        // both `&#x...;` and `&#X...;`; matching only lowercase silently
        // skipped uppercase-prefixed entities. Use `.caseInsensitive` so the
        // optional x/X is accepted, then the runtime branch already lowercases
        // the prefix check via `hasPrefix("x") || hasPrefix("X")`.
        let rx = try NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);", options: [.caseInsensitive])
        let ns = out as NSString
        var result = ""
        var cursor = 0
        let matches = rx.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            let raw = ns.substring(with: m.range(at: 1))
            let scalar: Unicode.Scalar?
            if raw.hasPrefix("x") || raw.hasPrefix("X") {
                let hex = String(raw.dropFirst())
                scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init)
            } else {
                scalar = UInt32(raw).flatMap(Unicode.Scalar.init)
            }
            if let s = scalar { result.append(Character(s)) }
            else              { result += ns.substring(with: m.range) }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        out = result
    } catch { /* keep prior best effort */ }
    return out
}

private func jsonReformat(_ s: String, sortKeys: Bool, minify: Bool) throws -> String {
    let data = Data(s.utf8)
    let obj: Any
    do {
        obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw XformError("invalid JSON: \(error.localizedDescription)")
    }
    var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed]
    if !minify    { opts.insert(.prettyPrinted) }
    if sortKeys   { opts.insert(.sortedKeys) }
    let out = try JSONSerialization.data(withJSONObject: obj, options: opts)
    return String(data: out, encoding: .utf8) ?? s
}

private func yamlTidy(_ s: String) -> String {
    let normalized = s.replacingOccurrences(of: "\t", with: "  ")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
                          .map { $0.trimmingTrailingWhitespace() }
    // Collapse runs of blank lines into a single blank line.
    var out: [String] = []
    var blankRun = 0
    for l in lines {
        if l.isEmpty {
            blankRun += 1
            if blankRun <= 1 { out.append(l) }
        } else {
            blankRun = 0
            out.append(l)
        }
    }
    return out.joined(separator: "\n")
}

private func xmlPretty(_ s: String) throws -> String {
    // Use XMLDocument for real reformatting (Foundation on macOS supports this).
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return s }
    let doc: XMLDocument
    do {
        // red-team: XXE defense. Pasting `<!DOCTYPE x [ <!ENTITY e SYSTEM "file:///etc/passwd"> ]>`
        // into a pretty-printer must NEVER resolve the external entity. The
        // default XMLDocument parser will follow file:// and http:// SYSTEM
        // identifiers; opt out explicitly. `.nodeLoadExternalEntitiesNever`
        // refuses every external entity reference; we keep DTD parsing off too.
        let options: XMLNode.Options = [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]
        doc = try XMLDocument(xmlString: trimmed, options: options)
    } catch {
        throw XformError("invalid XML: \(error.localizedDescription)")
    }
    let pretty = doc.xmlString(options: [.nodePrettyPrint])
    return pretty
}

private extension Substring {
    func trimmingTrailingWhitespace() -> String {
        var s = String(self)
        while let last = s.last, last.isWhitespace, last != "\n" { s.removeLast() }
        return s
    }
}

private func decodeJWT(_ s: String) throws -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw XformError("JWT must have 3 dot-separated segments; got \(parts.count)") }
    let header = try decodeJWTSegmentAsJSON(String(parts[0]), name: "header")
    let payload = try decodeJWTSegmentAsJSON(String(parts[1]), name: "payload")
    // Show signature as raw base64 — never claim verification.
    let sig = String(parts[2])
    return """
    // header
    \(header)

    // payload
    \(payload)

    // signature (base64url, NOT verified)
    \(sig)
    """
}

private func decodeJWTSegmentAsJSON(_ segment: String, name: String) throws -> String {
    let normalized = base64Normalize(segment)
    guard let raw = Data(base64Encoded: normalized) else {
        throw XformError("JWT \(name) is not valid base64url")
    }
    let obj: Any
    do {
        obj = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
    } catch {
        // If it's not JSON, just return UTF-8 text so the user sees *something*.
        return String(data: raw, encoding: .utf8) ?? raw.base64EncodedString()
    }
    let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    return String(data: pretty, encoding: .utf8) ?? ""
}

private func sentenceCase(_ s: String) -> String {
    let lower = s.lowercased()
    var chars = Array(lower)
    var nextShouldCap = true
    for i in chars.indices {
        let c = chars[i]
        if nextShouldCap && c.isLetter {
            chars[i] = Character(String(c).uppercased())
            nextShouldCap = false
        }
        if c == "." || c == "!" || c == "?" { nextShouldCap = true }
    }
    return String(chars)
}

/// Tokenize identifier-ish strings and rejoin in a target style.
private func tokenCase(_ s: String, joiner: String, upperFirst: Bool, upperRest: Bool) -> String {
    // Split on non-alphanumeric or camel-hump boundaries.
    var tokens: [String] = []
    var current = ""
    var prev: Character? = nil
    for c in s {
        if c.isLetter || c.isNumber {
            if let p = prev, p.isLowercase, c.isUppercase {
                tokens.append(current); current = ""
            }
            current.append(c)
        } else {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        prev = c
    }
    if !current.isEmpty { tokens.append(current) }
    if tokens.isEmpty { return "" }
    return tokens.enumerated().map { idx, tok -> String in
        let lower = tok.lowercased()
        let isFirst = (idx == 0)
        let shouldUpper = isFirst ? upperFirst : upperRest
        if shouldUpper {
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return lower
    }.joined(separator: joiner)
}

/// UUID v7 = unix-millisecond timestamp + random tail, version & variant set.
/// Implemented here because Foundation's `UUID()` is v4.
private func makeUUIDv7() -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    let ms = UInt64(Date().timeIntervalSince1970 * 1000)
    bytes[0] = UInt8((ms >> 40) & 0xff)
    bytes[1] = UInt8((ms >> 32) & 0xff)
    bytes[2] = UInt8((ms >> 24) & 0xff)
    bytes[3] = UInt8((ms >> 16) & 0xff)
    bytes[4] = UInt8((ms >> 8)  & 0xff)
    bytes[5] = UInt8(ms & 0xff)
    // Fill the rest with secure randomness.
    var rand = [UInt8](repeating: 0, count: 10)
    let status = SecRandomCopyBytes(kSecRandomDefault, rand.count, &rand)
    if status != errSecSuccess {
        // red-team: if Security.framework declines to seed us (sandbox weirdness,
        // entropy-source failure during early boot) the buffer would stay all-zero
        // and we'd emit a predictable v7 UUID that collides on every call. Fall
        // back to SystemRandomNumberGenerator (Swift's CSPRNG-backed RNG) so the
        // tail is still unique even when Security.framework fails us.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<10 { rand[i] = UInt8.random(in: 0...255, using: &rng) }
    }
    for i in 0..<10 { bytes[6 + i] = rand[i] }
    // Version 7 in high nibble of byte 6.
    bytes[6] = (bytes[6] & 0x0F) | 0x70
    // RFC 4122 variant (10xx) in high bits of byte 8.
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// Split lines but remember whether the file used CRLF or LF so we put it back
/// in the same flavor. Stripping `\r` then `\n` lets a single mixed-line-ending
/// file round-trip without surprising the user.
private func splitLinesPreservingSeparator(_ s: String) -> (lines: [String], separator: String) {
    let crlf = s.contains("\r\n")
    let sep = crlf ? "\r\n" : "\n"
    let normalized = crlf ? s.replacingOccurrences(of: "\r\n", with: "\n") : s
    return (normalized.components(separatedBy: "\n"), sep)
}

// ===========================================================================
// MARK: - Auto-detect
// ===========================================================================

/// Regex-based shape detection for the suggested-transforms row. Returns the
/// suggested pipeline (list of `XformKind`) given the current input. Order
/// matters — first matching rule wins.
enum XformAutoDetect {
    static func suggest(for raw: String) -> [(label: String, pipeline: [XformKind])] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        var out: [(String, [XformKind])] = []

        if matches(s, "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$") {
            out.append(("Decode JWT", [.jwtDecode]))
        }
        if matches(s, "^https?://") {
            out.append(("URL decode", [.urlDecode]))
        }
        if isLikelyJSON(s) {
            out.append(("JSON pretty", [.jsonPretty]))
        }
        if matches(s, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") {
            out.append(("Format UUID", [.uuidFormat]))
        }
        if matches(s, "^[A-Za-z0-9+/=\\-_\\s]+$") && s.count >= 8 && s.count % 4 == 0 && !isLikelyJSON(s) {
            // Base64 is structurally permissive. Keep it suggestion-only, not
            // auto-apply. Avoid suggesting on short or non-base64-shaped input.
            out.append(("Try Base64 decode", [.base64Decode]))
        }
        if matches(s, "^[0-9a-fA-F\\s]+$") && s.filter({ !$0.isWhitespace }).count >= 4
            && s.filter({ !$0.isWhitespace }).count % 2 == 0 {
            out.append(("Hex decode", [.hexDecode]))
        }
        if matches(s, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}") {
            // ISO timestamp — surface a no-op formatting chip via lines/trim so
            // the user has a hint that we detected it. No timestamp transform
            // exists yet; keep the suggestion list informative.
            out.append(("Trim each line", [.linesTrim]))
        }

        return out
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return rx.firstMatch(in: s, range: range) != nil
    }

    private static func isLikelyJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, let last = t.last else { return false }
        guard (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) != nil
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

@MainActor
final class XformModel: ObservableObject {
    @Published var input: String = ""
    @Published var steps: [XformStep] = []
    @Published var outcomes: [XformStepOutcome] = []
    @Published var output: String = ""
    /// Index of the chip the user clicked to "scrub" the pipeline; `nil` means
    /// show final output. The real-time intermediate-preview differentiator.
    @Published var inspectedStepIdx: Int? = nil
    /// Top-of-pane warning banner (size warnings, etc.).
    @Published var inputBanner: String? = nil
    /// `true` once we've hit the hard refuse threshold; pipeline won't run.
    @Published var inputBlocked: Bool = false

    /// Debounce token: increments on every input/pipeline change, and the
    /// scheduled re-evaluation no-ops if the token changed under it. Lets us
    /// debounce massive pastes without piling up `Task`s.
    private var revision: UInt64 = 0

    /// Size thresholds — warn at 1 MB, refuse at 50 MB. Matches the spec.
    static let warnBytes: Int = 1_000_000
    static let refuseBytes: Int = 50_000_000

    init() {}

    func setInput(_ s: String) {
        input = s
        recomputeSoon()
    }

    func addStep(_ kind: XformKind) {
        steps.append(XformStep(kind: kind))
        recomputeSoon()
    }

    /// Prepend a suggested pipeline at the front (push existing steps down).
    func prependPipeline(_ kinds: [XformKind]) {
        let newSteps = kinds.map { XformStep(kind: $0) }
        steps.insert(contentsOf: newSteps, at: 0)
        recomputeSoon()
    }

    func removeStep(id: UUID) {
        steps.removeAll { $0.id == id }
        if inspectedStepIdx != nil, inspectedStepIdx ?? -1 >= steps.count {
            inspectedStepIdx = nil
        }
        recomputeSoon()
    }

    func moveStep(from src: IndexSet, to dst: Int) {
        steps.move(fromOffsets: src, toOffset: dst)
        recomputeSoon()
    }

    func updateParam(stepID: UUID, param1: String? = nil, param2: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == stepID }) else { return }
        if let p = param1 { steps[i].param1 = p }
        if let p = param2 { steps[i].param2 = p }
        recomputeSoon()
    }

    func clearPipeline() {
        steps.removeAll()
        inspectedStepIdx = nil
        recompute()
    }

    /// Snapshot — what the user is currently viewing in the output box.
    var currentlyViewedOutput: String {
        if let idx = inspectedStepIdx, idx >= 0, idx < outcomes.count {
            switch outcomes[idx] {
            case .ok(let s):      return s
            case .error(let msg): return "// error in step \(idx + 1): \(msg)"
            case .skipped:        return "// (skipped — earlier step failed)"
            }
        }
        return output
    }

    // MARK: - Debounce + execution

    /// Big inputs would lag the UI if we recomputed on every keystroke. Schedule
    /// with a short delay; the latest scheduled run wins via the `revision`
    /// token.
    private func recomputeSoon() {
        updateInputGuards()
        revision &+= 1
        let token = revision
        let bytes = input.utf8.count
        let delayMs: Int = bytes > 200_000 ? 220 : 40
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard let self else { return }
            await MainActor.run {
                if self.revision == token { self.recompute() }
            }
        }
    }

    private func updateInputGuards() {
        let bytes = input.utf8.count
        if bytes >= Self.refuseBytes {
            inputBanner = "Input is \(byteString(bytes)). Refusing to run — keep it under 50 MB."
            inputBlocked = true
        } else if bytes >= Self.warnBytes {
            inputBanner = "Large input (\(byteString(bytes))) — transforms may be slow."
            inputBlocked = false
        } else {
            inputBanner = nil
            inputBlocked = false
        }
    }

    private func recompute() {
        if inputBlocked {
            outcomes = Array(repeating: .skipped, count: steps.count)
            output = ""
            return
        }
        let (outs, final) = XformEngine.run(input: input, steps: steps)
        outcomes = outs
        output = final
    }

    private func byteString(_ b: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(b))
    }
}

// ===========================================================================
// MARK: - Top-level view
// ===========================================================================

public struct XformView: View {
    @StateObject private var model = XformModel()
    @EnvironmentObject private var stage: Stage

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputCard
                suggestionsCard
                pipelineCard
                outputCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Text Transforms")
        .navigationSubtitle(subtitle)
    }

    // MARK: subtitle

    private var subtitle: String {
        if model.steps.isEmpty {
            return "Paste text, then chain transforms"
        }
        let errs = model.outcomes.filter { if case .error = $0 { return true } else { return false } }.count
        return errs == 0
            ? "\(model.steps.count) step\(model.steps.count == 1 ? "" : "s")"
            : "\(model.steps.count) step\(model.steps.count == 1 ? "" : "s") · \(errs) error\(errs == 1 ? "" : "s")"
    }

    // MARK: input

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Input").font(.headline)
                    Spacer()
                    if let banner = model.inputBanner {
                        HStack(spacing: 6) {
                            Image(systemName: model.inputBlocked
                                  ? "exclamationmark.octagon.fill"
                                  : "exclamationmark.triangle.fill")
                            Text(banner)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((model.inputBlocked ? Color.red : Color.orange).opacity(0.18),
                                    in: Capsule())
                        .foregroundStyle(model.inputBlocked ? .red : .orange)
                    }
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            model.setInput(s)
                        }
                    } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .help("Replace input with current clipboard text")
                    Button(role: .destructive) {
                        model.setInput("")
                    } label: { Label("Clear", systemImage: "xmark.circle") }
                    .disabled(model.input.isEmpty)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(
                        get: { model.input },
                        set: { model.setInput($0) }))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: 200)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    if model.input.isEmpty {
                        // red-team: TextEditor has no placeholder API on macOS;
                        // overlay a non-hit-testable hint so a fresh-launch user
                        // sees a concrete example instead of an empty box.
                        Text("Paste a JWT, JSON blob, base64 string, or any text. Then add transforms below — the pipeline runs as you type.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    // MARK: suggestions

    private var suggestionsCard: some View {
        let suggestions = XformAutoDetect.suggest(for: model.input)
        return Group {
            if suggestions.isEmpty {
                EmptyView()
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                            Text("Suggested transforms").font(.headline)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, s in
                                    Button {
                                        model.prependPipeline(s.pipeline)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "plus.circle.fill")
                                            Text(s.label)
                                        }
                                        .font(.callout)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: pipeline

    private var pipelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Pipeline").font(.headline)
                    if !model.steps.isEmpty {
                        Text("· click a chip to inspect that step's output")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    XformAddMenu(model: model)
                    if !model.steps.isEmpty {
                        Button(role: .destructive) { model.clearPipeline() } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .help("Remove all steps")
                    }
                }
                if model.steps.isEmpty {
                    Text("Add a transform to start building a pipeline. Each step's output feeds the next.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    XformChipList(model: model)
                }
            }
        }
    }

    // MARK: output

    private var outputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(outputTitle).font(.headline)
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(model.currentlyViewedOutput, forType: .string)
                        stage.flash("Copied transform output")
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(model.currentlyViewedOutput.isEmpty)
                    // ⌘C would clash with system text-selection copy.
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy output to the clipboard (⌘⇧C)")

                    Button {
                        Self.saveTransformOutput(model.currentlyViewedOutput,
                                                 label: outputFilenameLabel)
                    } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .disabled(model.currentlyViewedOutput.isEmpty)
                    .keyboardShortcut("s", modifiers: [.command])
                    .help("Save the output as a .txt file (⌘S).")

                    Menu {
                        Button {
                            Self.quickSaveTransformOutputToDownloads(model.currentlyViewedOutput,
                                                                    label: outputFilenameLabel)
                        } label: {
                            Label("Save to Downloads", systemImage: "arrow.down.circle")
                        }
                        .keyboardShortcut("d", modifiers: [.command])
                        Button {
                            stage.addText(model.currentlyViewedOutput)
                            stage.flash("Sent transform output to Stage")
                        } label: {
                            Label("Send to Stage", systemImage: "tray.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.currentlyViewedOutput.isEmpty)
                    .help("More actions")

                    if model.inspectedStepIdx != nil {
                        Button { model.inspectedStepIdx = nil } label: {
                            Label("Show final", systemImage: "arrow.uturn.right")
                        }
                        .help("Return to the final pipeline output")
                    }
                }
                TextEditor(text: .constant(model.currentlyViewedOutput))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 360)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    // Drag the output as a .txt file straight into Finder, Mail,
                    // Slack, etc. The provider materializes the file on-demand.
                    .onDrag {
                        Self.makeTransformItemProvider(model.currentlyViewedOutput,
                                                       label: outputFilenameLabel)
                    }
                    .contextMenu {
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(model.currentlyViewedOutput, forType: .string)
                            stage.flash("Copied transform output")
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(model.currentlyViewedOutput.isEmpty)
                        Button {
                            Self.saveTransformOutput(model.currentlyViewedOutput,
                                                     label: outputFilenameLabel)
                        } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                        .disabled(model.currentlyViewedOutput.isEmpty)
                        Button {
                            Self.quickSaveTransformOutputToDownloads(model.currentlyViewedOutput,
                                                                    label: outputFilenameLabel)
                        } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                        .disabled(model.currentlyViewedOutput.isEmpty)
                        Button {
                            stage.addText(model.currentlyViewedOutput)
                            stage.flash("Sent transform output to Stage")
                        } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
                        .disabled(model.currentlyViewedOutput.isEmpty)
                    }
            }
        }
    }

    private var outputTitle: String {
        if let idx = model.inspectedStepIdx, idx < model.steps.count {
            return "Step \(idx + 1) output — \(model.steps[idx].title)"
        }
        return "Output"
    }

    /// Human-friendly base label baked into save filenames. Reflects whether
    /// the user is inspecting a pipeline step or the final output.
    private var outputFilenameLabel: String {
        if let idx = model.inspectedStepIdx, idx < model.steps.count {
            let title = model.steps[idx].title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            return "Transform step \(idx + 1) \(title)"
        }
        return "Transform output"
    }

    // -----------------------------------------------------------------------
    // Save helpers — statics so closures don't capture self.
    // -----------------------------------------------------------------------

    /// Save As… with NSSavePanel. Default `.txt`, name pre-filled with
    /// "<label> <timestamp>.txt". Remembers last-used directory.
    fileprivate static func saveTransformOutput(_ text: String, label: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "\(label) \(timestampForFilename()).txt"
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                try text.write(to: dest, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    fileprivate static func quickSaveTransformOutputToDownloads(_ text: String, label: String) {
        guard let downloads = downloadsDir() else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let name = "\(label) \(timestampForFilename()).txt"
        let dest = collisionFreeURL(in: downloads, name: name)
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    /// NSItemProvider that materializes a .txt on-demand for drag-to-Finder.
    fileprivate static func makeTransformItemProvider(_ text: String, label: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let filename = "\(label).txt"
        provider.suggestedName = filename
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(filename)")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                completion(url, false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    // ---- shared save-dir state (statics so closures don't capture self) ----

    private static let kSaveDirKey = "text_transforms.saveDir.last"

    fileprivate static func lastSaveDir() -> URL? {
        guard let p = UserDefaults.standard.string(forKey: kSaveDirKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    fileprivate static func setLastSaveDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: kSaveDirKey)
    }

    fileprivate static func downloadsDir() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Append " (2)", " (3)"… before the extension until the destination
    /// doesn't exist. Cap at 99.
    fileprivate static func collisionFreeURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: dest.path) { return dest }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...99 {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(stem) (\(n))")
                : dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            dest = candidate
        }
        return dest
    }

    /// "2026-05-13 21:45" — local time, sortable, filename-safe.
    fileprivate static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}

// ===========================================================================
// MARK: - Add-transform menu
// ===========================================================================

struct XformAddMenu: View {
    @ObservedObject var model: XformModel

    var body: some View {
        Menu {
            ForEach(XformCategory.allCases) { cat in
                Menu(cat.rawValue) {
                    ForEach(XformCatalog.all.filter { $0.category == cat }) { d in
                        Button(d.title) { model.addStep(d.kind) }
                    }
                }
            }
        } label: {
            Label("Add transform", systemImage: "plus")
        }
        .menuStyle(.button)
    }
}

// ===========================================================================
// MARK: - Chip list (the pipeline UI itself)
// ===========================================================================

struct XformChipList: View {
    @ObservedObject var model: XformModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { idx, step in
                XformChipRow(
                    model: model,
                    step: step,
                    index: idx,
                    outcome: idx < model.outcomes.count ? model.outcomes[idx] : .skipped,
                    isInspected: model.inspectedStepIdx == idx
                )
                if step.id != model.steps.last?.id {
                    HStack {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                        Spacer()
                    }
                    .frame(height: 12)
                }
            }
        }
    }
}

struct XformChipRow: View {
    @ObservedObject var model: XformModel
    let step: XformStep
    let index: Int
    let outcome: XformStepOutcome
    let isInspected: Bool

    @State private var showParamPopover = false

    var body: some View {
        let desc = XformCatalog.descriptor(step.kind)
        let outcomeColor: Color = {
            switch outcome {
            case .ok:      return .green
            case .error:   return .red
            case .skipped: return .secondary
            }
        }()

        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18)

            HStack(spacing: 6) {
                Circle()
                    .fill(outcomeColor)
                    .frame(width: 7, height: 7)
                Text(desc.title)
                    .font(.body.weight(.medium))
                if desc.parameterized {
                    Text(paramSummary(step))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if case .error(let msg) = outcome {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if case .skipped = outcome {
                    Text("skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            Spacer()

            if desc.parameterized {
                Button { showParamPopover = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Configure")
                .popover(isPresented: $showParamPopover, arrowEdge: .bottom) {
                    XformStepParamEditor(model: model, step: step)
                        .padding(14)
                        .frame(width: 320)
                }
            }
            Button { model.removeStep(id: step.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove this step")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isInspected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isInspected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.3),
                              lineWidth: isInspected ? 1.5 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Real-time intermediate preview — clicking a chip scrubs the
            // output panel to that step's result.
            if model.inspectedStepIdx == index {
                model.inspectedStepIdx = nil
            } else {
                model.inspectedStepIdx = index
            }
        }
        .onDrag {
            // Encode the index so the drop target knows where it came from.
            NSItemProvider(object: "\(index)" as NSString)
        }
        .onDrop(of: [.text], delegate: XformChipDropDelegate(
            model: model,
            targetIndex: index
        ))
    }

    private func paramSummary(_ s: XformStep) -> String {
        switch s.kind {
        case .linesAddPrefix: return s.param1.isEmpty ? "(no prefix)" : "“\(s.param1)”"
        case .linesAddSuffix: return s.param1.isEmpty ? "(no suffix)" : "“\(s.param1)”"
        case .regexExtract:   return s.param1.isEmpty ? "(no pattern)" : "/\(s.param1)/"
        case .regexReplace:   return s.param1.isEmpty ? "(no pattern)" : "/\(s.param1)/→\(s.param2)"
        default: return ""
        }
    }
}

struct XformChipDropDelegate: DropDelegate {
    let model: XformModel
    let targetIndex: Int

    func validateDrop(info: DropInfo) -> Bool { true }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8),
                  let src = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            DispatchQueue.main.async {
                if src != targetIndex && src >= 0 && src < model.steps.count {
                    let dest = src < targetIndex ? targetIndex + 1 : targetIndex
                    model.moveStep(from: IndexSet(integer: src), to: dest)
                }
            }
        }
        return true
    }
}

// ===========================================================================
// MARK: - Step parameter editor (regex / prefix / suffix popover)
// ===========================================================================

struct XformStepParamEditor: View {
    @ObservedObject var model: XformModel
    let step: XformStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch step.kind {
            case .linesAddPrefix:
                Text("Prefix").font(.headline)
                TextField("e.g. >>> ", text: bindingForParam1())
                    .textFieldStyle(.roundedBorder)
            case .linesAddSuffix:
                Text("Suffix").font(.headline)
                TextField("e.g. ;", text: bindingForParam1())
                    .textFieldStyle(.roundedBorder)
            case .regexExtract:
                Text("Regex (NSRegularExpression syntax)").font(.headline)
                TextField("pattern, e.g. \\d+", text: bindingForParam1())
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Matches are joined with newlines.").font(.caption).foregroundStyle(.secondary)
            case .regexReplace:
                Text("Regex").font(.headline)
                TextField("pattern", text: bindingForParam1())
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Replacement").font(.headline)
                TextField("template, $1 backrefs supported", text: bindingForParam2())
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            default:
                Text("No parameters for this transform.")
            }
        }
    }

    private func bindingForParam1() -> Binding<String> {
        Binding(
            get: {
                model.steps.first(where: { $0.id == step.id })?.param1 ?? ""
            },
            set: { model.updateParam(stepID: step.id, param1: $0) }
        )
    }

    private func bindingForParam2() -> Binding<String> {
        Binding(
            get: {
                model.steps.first(where: { $0.id == step.id })?.param2 ?? ""
            },
            set: { model.updateParam(stepID: step.id, param2: $0) }
        )
    }
}
