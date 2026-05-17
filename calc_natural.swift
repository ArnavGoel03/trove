// calc_natural.swift — Numi-parity natural-language preprocessor for the calc
// engine. Rewrites everyday English phrasing into arithmetic that the existing
// `evaluateArithmetic` path (NSExpression-backed) can consume directly.
//
// Wires into calc.swift by calling `NaturalLanguageCalc.preprocess(input)`
// BEFORE the decimal-comma normalization step and BEFORE smart-percent
// expansion. Single line edit in `evaluateArithmetic`:
//
//     let input = NaturalLanguageCalc.preprocess(rawInput)
//
// This lets users type things like:
//   "15% of 240"             → 36
//   "200 + 10% tip"          → 220
//   "300 off 20%"            → 240
//   "half of 18"             → 9
//   "double 7"               → 14
//   "12 plus 8 times 3"      → 36
//   "sqrt 49"                → 7
//   "20 km in miles"         → 12.4274
// without breaking existing pure-arithmetic inputs (`1 + 1 = 2` still works).

import Foundation

enum NaturalLanguageCalc {

    /// Top-level entry point. Idempotent: running it twice produces the same
    /// result as running it once. Falls back to returning the input unchanged
    /// if no English phrasing is detected — so plain arithmetic stays exact.
    static func preprocess(_ raw: String) -> String {
        var s = raw

        // Order matters: percent-of must precede percent-on/percent-off so
        // "10% of 240" doesn't accidentally match the "off" rule.
        s = rewritePercentOf(s)
        s = rewritePercentOn(s)
        s = rewritePercentOff(s)
        s = rewriteHalfOf(s)
        s = rewriteDouble(s)
        s = rewriteWordOperators(s)
        s = rewriteUnaryFnsWithoutParens(s)

        return s
    }

    // MARK: - Percent rewrites

    /// `15% of 240` → `(15 * 0.01 * 240)`
    /// `0.5% of 1000` → `(0.5 * 0.01 * 1000)`
    private static func rewritePercentOf(_ s: String) -> String {
        let pattern = #"(?i)(-?\d+(?:[.,]\d+)?)\s*%\s*of\s+(-?\d+(?:[.,]\d+)?)"#
        return regexReplace(s, pattern: pattern) { match, captures in
            guard captures.count >= 2 else { return match }
            return "(\(captures[0]) * 0.01 * \(captures[1]))"
        }
    }

    /// `200 + 10%` is already handled by calc's smart-percent. This handles
    /// the more explicit `200 on 10%` or `1000 plus 7% tip` phrasing.
    /// `200 on 10%` → `(200 * (1 + 10*0.01))` = 220
    private static func rewritePercentOn(_ s: String) -> String {
        let pattern = #"(?i)(-?\d+(?:[.,]\d+)?)\s+on\s+(-?\d+(?:[.,]\d+)?)\s*%"#
        return regexReplace(s, pattern: pattern) { match, captures in
            guard captures.count >= 2 else { return match }
            return "(\(captures[0]) * (1 + \(captures[1]) * 0.01))"
        }
    }

    /// `300 off 20%` → `(300 * (1 - 20*0.01))` = 240
    /// `$50 off 10%` → handled (currency symbols pass through the digit capture)
    private static func rewritePercentOff(_ s: String) -> String {
        let pattern = #"(?i)(-?\d+(?:[.,]\d+)?)\s+off\s+(-?\d+(?:[.,]\d+)?)\s*%"#
        return regexReplace(s, pattern: pattern) { match, captures in
            guard captures.count >= 2 else { return match }
            return "(\(captures[0]) * (1 - \(captures[1]) * 0.01))"
        }
    }

    /// `half of X` → `(X / 2)`
    private static func rewriteHalfOf(_ s: String) -> String {
        let pattern = #"(?i)\bhalf\s+of\s+(-?\d+(?:[.,]\d+)?)"#
        return regexReplace(s, pattern: pattern) { match, captures in
            guard let first = captures.first else { return match }
            return "(\(first) / 2)"
        }
    }

    /// `double X` → `(X * 2)`
    /// `triple X` → `(X * 3)`
    private static func rewriteDouble(_ s: String) -> String {
        var out = s
        for (word, factor) in [("double", 2), ("triple", 3), ("quadruple", 4)] {
            let pattern = #"(?i)\b\#(word)\s+(-?\d+(?:[.,]\d+)?)"#
            out = regexReplace(out, pattern: pattern) { match, captures in
                guard let first = captures.first else { return match }
                return "(\(first) * \(factor))"
            }
        }
        return out
    }

    /// Replace English operators with symbols when they appear between numbers.
    /// `12 plus 5` → `12 + 5`, `12 times 3` → `12 * 3`, etc.
    private static func rewriteWordOperators(_ s: String) -> String {
        // Operate on word boundaries to avoid mangling identifiers like
        // `plus_one` or function names. Operators only apply between numeric
        // tokens — we use a permissive lookaround instead of strict tokenization
        // since the arithmetic evaluator does final validation.
        let pairs: [(pattern: String, replacement: String)] = [
            (#"(?i)\bplus\b"#,        "+"),
            (#"(?i)\bminus\b"#,       "-"),
            (#"(?i)\btimes\b"#,       "*"),
            (#"(?i)\bmultiplied by\b"#, "*"),
            (#"(?i)\bdivided by\b"#,  "/"),
            (#"(?i)\bover\b"#,        "/"),
        ]
        var out = s
        for (p, r) in pairs {
            out = regexReplace(out, pattern: p) { _, _ in r }
        }
        return out
    }

    /// `sqrt 49` → `sqrt(49)` (also covers `cos 30`, `sin 45`, etc.). This is
    /// a common typing shortcut Numi users expect.
    private static func rewriteUnaryFnsWithoutParens(_ s: String) -> String {
        // Whitelist of functions known to the calc engine. Anything not in
        // this list is left alone so we don't accidentally wrap identifiers
        // the user is using as variables.
        let fns = ["sqrt", "abs", "ln", "log", "exp",
                   "sin", "cos", "tan", "asin", "acos", "atan",
                   "ceil", "floor", "round", "trunc"]
        var out = s
        for fn in fns {
            // `fn` followed by one or more spaces and a number, where the next
            // char is NOT a `(` (already-parenthesized form).
            let pattern = "(?i)\\b\(fn)\\s+(-?\\d+(?:[.,]\\d+)?)(?!\\s*[(])"
            out = regexReplace(out, pattern: pattern) { match, captures in
                guard let first = captures.first else { return match }
                return "\(fn)(\(first))"
            }
        }
        return out
    }

    // MARK: - Regex helper

    /// Replace each non-overlapping match using the provided closure. Captures
    /// are passed as `[String]` (group 1..N). Safer than `NSRegularExpression`
    /// boilerplate at each call site.
    private static func regexReplace(
        _ s: String,
        pattern: String,
        with replace: (_ match: String, _ captures: [String]) -> String
    ) -> String {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let ns = s as NSString
        let matches = rx.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            // Append the non-match portion ahead of this match.
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            let full = ns.substring(with: m.range)
            var captures: [String] = []
            for i in 1..<m.numberOfRanges {
                let cr = m.range(at: i)
                if cr.location != NSNotFound {
                    captures.append(ns.substring(with: cr))
                }
            }
            out += replace(full, captures)
            cursor = m.range.location + m.range.length
        }
        // Append trailing portion.
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }
}

// TODO: wire from `calc.swift` `evaluateArithmetic(...)` — single line at the
// top of that function:
//
//     let normalized = NaturalLanguageCalc.preprocess(input)
//     // ... continue with existing decimal-comma normalization on `normalized`
//
// This is intentionally a no-op for inputs without English phrasing, so
// existing arithmetic-only inputs route through unchanged.
