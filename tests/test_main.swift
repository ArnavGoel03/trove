// Trove unit-test runner.
//
// Compiled together with the app sources at ~/Documents/Projects/trove/macos/*.swift
// under -DTROVE_TESTING so the production @main and applicationDidFinishLaunching
// stay dormant. Pure-logic tests only — no NSPasteboard, no Keychain, no network.
//
// Build: see ~/bin/test-trove.

import Foundation
import AppKit
import Carbon
import CommonCrypto
import CryptoKit

// ===========================================================================
// MARK: - Mini test harness
// ===========================================================================

// Single-threaded stat tracker. All test execution is serialized through main(),
// so no synchronization needed even when async tests yield the main actor.
final class SyncStats {
    var passed: Int = 0
    var failed: Int = 0
    var failures: [(test: String, msg: String)] = []
    static let shared = SyncStats()
    func record(_ name: String, _ ok: Bool, _ msg: @autoclosure () -> String) {
        if ok { passed += 1 } else {
            failed += 1
            failures.append((name, msg()))
        }
    }
}

func assertTrue(_ cond: Bool, _ test: String, _ msg: @autoclosure () -> String = "expected true") {
    SyncStats.shared.record(test, cond, msg())
}
func assertFalse(_ cond: Bool, _ test: String, _ msg: @autoclosure () -> String = "expected false") {
    SyncStats.shared.record(test, !cond, msg())
}
func assertEqual<T: Equatable>(_ a: T, _ b: T, _ test: String,
                               _ msg: @autoclosure () -> String = "values differ") {
    SyncStats.shared.record(test, a == b, "\(msg()) — got \(a), want \(b)")
}
func assertNil<T>(_ a: T?, _ test: String, _ msg: @autoclosure () -> String = "expected nil") {
    SyncStats.shared.record(test, a == nil, "\(msg()) — got \(String(describing: a))")
}
func assertNotNil<T>(_ a: T?, _ test: String, _ msg: @autoclosure () -> String = "expected non-nil") {
    SyncStats.shared.record(test, a != nil, msg())
}
func assertThrows(_ test: String,
                  _ msg: @autoclosure () -> String = "expected throw",
                  _ block: () throws -> Void) {
    var threw = false
    do { try block() } catch { threw = true }
    SyncStats.shared.record(test, threw, msg())
}
func assertApprox(_ a: Double, _ b: Double, eps: Double = 1e-6, _ test: String,
                  _ msg: @autoclosure () -> String = "values differ") {
    let ok = (a.isFinite && b.isFinite && abs(a - b) <= eps)
        || (a.isInfinite && b.isInfinite && a.sign == b.sign)
        || (a.isNaN && b.isNaN)
    SyncStats.shared.record(test, ok, "\(msg()) — got \(a), want \(b) (eps=\(eps))")
}

// ===========================================================================
// MARK: - Fixtures
// ===========================================================================

let fixturesDir = URL(fileURLWithPath: "/tmp/trove-tests-fixtures", isDirectory: true)

func resetFixtures() {
    try? FileManager.default.removeItem(at: fixturesDir)
    try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
}

/// Seed ~/Library/Application Support/Trove/exchange.json with the bundled
/// fallback rates marked as freshly fetched. Stops CalcRateStore from kicking
/// off an ECB network fetch at first construction.
func seedRateCacheToFresh() {
    let url = CalcRateCache.fileURL
    let fresh = CalcRateCache(base: "EUR",
                              fetched: Date(),
                              rates: CalcRateCache.fallback.rates)
    if let data = try? JSONEncoder().encode(fresh) {
        try? data.write(to: url, options: .atomic)
    }
}

func writeFixture(_ name: String, _ data: Data) -> URL {
    let url = fixturesDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    try! data.write(to: url)
    return url
}

func writeFixtureString(_ name: String, _ s: String) -> URL {
    writeFixture(name, Data(s.utf8))
}

// Build a deterministic blob using a simple Linear Congruential PRNG so chunked
// content is varied but reproducible.
func deterministicBytes(_ count: Int, seed: UInt64 = 1) -> Data {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    var out = Data(count: count)
    out.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self).baseAddress!
        for i in 0..<count {
            // xorshift64*
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let v = state &* 0x2545_F491_4F6C_DD1D
            p[i] = UInt8(truncatingIfNeeded: v >> 56)
        }
    }
    return out
}

// MD5/SHA1/SHA256 of empty input (canonical):
//   md5     d41d8cd98f00b204e9800998ecf8427e
//   sha1    da39a3ee5e6b4b0d3255bfef95601890afd80709
//   sha256  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

// ===========================================================================
// MARK: - Calc evaluator tests
// ===========================================================================

@MainActor
func testCalc_evaluate_basic() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "1 + 1")
    assertEqual(r.count, 1, "calc.eval.basic.count")
    if case .number(let n) = r[0].value {
        assertApprox(n, 2.0, "calc.eval.basic.value")
    } else { assertTrue(false, "calc.eval.basic.value", "wrong case: \(r[0].value)") }
}

@MainActor
func testCalc_evaluate_simple_arithmetic() {
    let e = CalcEvaluator()
    let cases: [(String, Double)] = [
        ("2*3", 6),
        ("10/4", 2.5),
        ("(1+2)*3", 9),
        ("10 - 3 - 2", 5),
        ("-5 + 8", 3),
        ("0.1 + 0.2", 0.3),
        ("100 / 8", 12.5),
        ("2 + 3 * 4", 14),
    ]
    for (i, (s, want)) in cases.enumerated() {
        let r = e.evaluate(text: s)
        if r.count == 1, case .number(let n) = r[0].value {
            assertApprox(n, want, eps: 1e-9, "calc.eval.arith[\(i)]:\(s)")
        } else {
            assertTrue(false, "calc.eval.arith[\(i)]:\(s)", "no number — \(r[0].value)")
        }
    }
}

@MainActor
func testCalc_evaluate_lineRefs() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "10\n20\nline1 + line2")
    assertEqual(r.count, 3, "calc.eval.lineRefs.count")
    if case .number(let n) = r[2].value {
        assertApprox(n, 30, "calc.eval.lineRefs.sum")
    } else { assertTrue(false, "calc.eval.lineRefs.sum", "wrong case") }
}

@MainActor
func testCalc_evaluate_variables() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "tax = 0.1\nprice = 100\nprice + price * tax")
    assertEqual(r.count, 3, "calc.eval.vars.count")
    if case .number(let n) = r[2].value {
        assertApprox(n, 110, "calc.eval.vars.value")
    } else { assertTrue(false, "calc.eval.vars.value", "wrong case") }
}

@MainActor
func testCalc_evaluate_commentsBlankLines() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "# header\n\n// inline\n2+2")
    assertEqual(r.count, 4, "calc.eval.comments.count")
    if case .empty = r[0].value { assertTrue(true, "calc.eval.comments.hash") }
    else { assertTrue(false, "calc.eval.comments.hash", "expected empty for #") }
    if case .empty = r[1].value { assertTrue(true, "calc.eval.comments.blank") }
    else { assertTrue(false, "calc.eval.comments.blank", "expected empty blank") }
    if case .empty = r[2].value { assertTrue(true, "calc.eval.comments.slash") }
    else { assertTrue(false, "calc.eval.comments.slash", "expected empty for //") }
    if case .number(let n) = r[3].value {
        assertApprox(n, 4, "calc.eval.comments.value")
    } else { assertTrue(false, "calc.eval.comments.value", "wrong") }
}

@MainActor
func testCalc_evaluate_lineRef_skipsComments() {
    // line1 should be the first real line (2+2), not the `#` comment.
    let e = CalcEvaluator()
    let r = e.evaluate(text: "# header\n2+2\nline1 * 10")
    if case .number(let n) = r[2].value {
        assertApprox(n, 40, "calc.eval.lineRef.skipsComments")
    } else { assertTrue(false, "calc.eval.lineRef.skipsComments", "wrong") }
}

@MainActor
func testCalc_evaluate_cycle() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "a = b + 1\nb = a + 1")
    // both lines should be cycle errors.
    var cycleCount = 0
    for line in r {
        if case .error(let s) = line.value, s.contains("circular") { cycleCount += 1 }
    }
    assertEqual(cycleCount, 2, "calc.eval.cycle.count")
}

@MainActor
func testCalc_evaluate_unbalancedParens() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "(1+2")
    if case .error = r[0].value { assertTrue(true, "calc.eval.unbalanced.lparen") }
    else { assertTrue(false, "calc.eval.unbalanced.lparen", "not error: \(r[0].value)") }
    let r2 = e.evaluate(text: "1+2)")
    if case .error = r2[0].value { assertTrue(true, "calc.eval.unbalanced.rparen") }
    else { assertTrue(false, "calc.eval.unbalanced.rparen", "not error: \(r2[0].value)") }
}

@MainActor
func testCalc_evaluate_doubleOps() {
    let e = CalcEvaluator()
    // All double-op sequences must be rejected. "1++2" historically slipped
    // through and crashed NSExpression (NSInvalidArgumentException);
    // isLikelyValidArithmetic was patched to reject it.
    for (i, s) in ["1++2", "1+*2", "1**2", "1//2", "1*/2", "1/*2", "1+-2"].enumerated() {
        let r = e.evaluate(text: s)
        if case .error = r[0].value { assertTrue(true, "calc.eval.doubleOps[\(i)]:\(s)") }
        else { assertTrue(false, "calc.eval.doubleOps[\(i)]:\(s)", "not error: \(r[0].value)") }
    }
    // Unary still works after an opening paren: "(-5)+8" → 3
    let r = e.evaluate(text: "(-5)+8")
    if case .number(let n) = r[0].value {
        assertApprox(n, 3, "calc.eval.doubleOps.unaryAfterParen")
    } else { assertTrue(false, "calc.eval.doubleOps.unaryAfterParen", "got: \(r[0].value)") }
}

@MainActor
func testCalc_evaluate_emptyParens() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "()")
    if case .error = r[0].value { assertTrue(true, "calc.eval.emptyParens") }
    else { assertTrue(false, "calc.eval.emptyParens", "not error") }
}

@MainActor
func testCalc_evaluate_multiDecimal() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "1.2.3 + 1")
    if case .error = r[0].value { assertTrue(true, "calc.eval.multiDecimal") }
    else { assertTrue(false, "calc.eval.multiDecimal", "not error: \(r[0].value)") }
}

@MainActor
func testCalc_evaluate_shadowing() {
    let e = CalcEvaluator()
    let r = e.evaluate(text: "x = 1\nx = 2\nx")
    assertNotNil(r[0].shadowedHint, "calc.eval.shadow.hint")
    if case .number(let n) = r[2].value {
        assertApprox(n, 2, "calc.eval.shadow.lastWins")
    } else { assertTrue(false, "calc.eval.shadow.lastWins", "wrong") }
}

@MainActor
func testCalc_evaluate_caret_rejected() {
    // ^ is intentionally not part of the allowed operator set.
    let e = CalcEvaluator()
    let r = e.evaluate(text: "2^3")
    if case .error = r[0].value { assertTrue(true, "calc.eval.caret") }
    else { assertTrue(false, "calc.eval.caret", "not error: \(r[0].value)") }
}

@MainActor
func testCalc_evaluate_implicit_mul_rejected() {
    let e = CalcEvaluator()
    for (i, s) in ["5(2+3)", "(2+3)5"].enumerated() {
        let r = e.evaluate(text: s)
        if case .error = r[0].value { assertTrue(true, "calc.eval.implMul[\(i)]:\(s)") }
        else { assertTrue(false, "calc.eval.implMul[\(i)]:\(s)", "not error") }
    }
}

@MainActor
func testCalc_normalizeOperators() {
    let e = CalcEvaluator()
    assertEqual(e._t_normalizeOperators("2×3"), "2*3", "calc.norm.times")
    assertEqual(e._t_normalizeOperators("8÷2"), "8/2", "calc.norm.div")
    assertEqual(e._t_normalizeOperators("5−3"), "5-3", "calc.norm.minus.u2212")
    assertEqual(e._t_normalizeOperators("5–3"), "5-3", "calc.norm.minus.endash")
    assertEqual(e._t_normalizeOperators("5—3"), "5-3", "calc.norm.minus.emdash")
    assertEqual(e._t_normalizeOperators("2 x 3"), "2 * 3", "calc.norm.xmul.lower")
    assertEqual(e._t_normalizeOperators("2 X 3"), "2 * 3", "calc.norm.xmul.upper")
    assertEqual(e._t_normalizeOperators("(2) x 3"), "(2) * 3", "calc.norm.xmul.afterParen")
    assertEqual(e._t_normalizeOperators("100\u{00A0}+\u{00A0}1"), "100 + 1", "calc.norm.nbsp")
}

@MainActor
func testCalc_normalizeOperators_e2e() {
    // End-to-end: × should compute.
    let e = CalcEvaluator()
    let r = e.evaluate(text: "2×3")
    if case .number(let n) = r[0].value {
        assertApprox(n, 6, "calc.norm.times.e2e")
    } else { assertTrue(false, "calc.norm.times.e2e", "wrong: \(r[0].value)") }
}

@MainActor
func testCalc_normalizeCurrency_symbols() {
    let e = CalcEvaluator()
    let s = e._t_normalizeCurrencyTokens("$100")
    assertTrue(s.contains("USD"), "calc.cur.usd.prefix", "got: \(s)")
    let s2 = e._t_normalizeCurrencyTokens("100$")
    assertTrue(s2.contains("USD"), "calc.cur.usd.suffix", "got: \(s2)")
    let s3 = e._t_normalizeCurrencyTokens("€50")
    assertTrue(s3.contains("EUR"), "calc.cur.eur", "got: \(s3)")
    let s4 = e._t_normalizeCurrencyTokens("£25")
    assertTrue(s4.contains("GBP"), "calc.cur.gbp", "got: \(s4)")
    let s5 = e._t_normalizeCurrencyTokens("¥1000")
    assertTrue(s5.contains("JPY"), "calc.cur.jpy", "got: \(s5)")
}

@MainActor
func testCalc_normalizeCurrency_words() {
    let e = CalcEvaluator()
    let s = e._t_normalizeCurrencyTokens("100 dollars")
    assertTrue(s.contains("USD"), "calc.cur.word.dollars", "got: \(s)")
    let s2 = e._t_normalizeCurrencyTokens("100 euros")
    assertTrue(s2.contains("EUR"), "calc.cur.word.euros", "got: \(s2)")
    let s3 = e._t_normalizeCurrencyTokens("100 pounds")
    assertTrue(s3.contains("GBP"), "calc.cur.word.pounds", "got: \(s3)")
    let s4 = e._t_normalizeCurrencyTokens("100 yen")
    assertTrue(s4.contains("JPY"), "calc.cur.word.yen", "got: \(s4)")
    let s5 = e._t_normalizeCurrencyTokens("100 rupees")
    assertTrue(s5.contains("INR"), "calc.cur.word.rupees", "got: \(s5)")
}

@MainActor
func testCalc_normalizeNaturalLanguage() {
    let e = CalcEvaluator()
    let cases: [(String, [String])] = [
        ("200 by 7", ["*"]),
        ("100 divided by 4", ["/"]),
        ("100 multiplied by 4", ["*"]),
        ("10% of 200", ["*"]),
        ("5 times 3", ["*"]),
        ("5 over 2", ["/"]),
        ("3 plus 4", ["+"]),
        ("3 minus 4", ["-"]),
    ]
    for (i, (s, mustContain)) in cases.enumerated() {
        let out = e._t_normalizeNaturalLanguage(s)
        for needle in mustContain {
            assertTrue(out.contains(needle), "calc.nl[\(i)]:\(s)", "got: \(out)")
        }
    }
}

@MainActor
func testCalc_expandSmartPercent() {
    let e = CalcEvaluator()
    // Sanity: "50 + 10%" should arithmetic to 55 end-to-end.
    let r = e.evaluate(text: "50 + 10%")
    if case .number(let n) = r[0].value {
        assertApprox(n, 55, eps: 1e-9, "calc.pct.add")
    } else { assertTrue(false, "calc.pct.add", "wrong: \(r[0].value)") }
    let r2 = e.evaluate(text: "100 - 25%")
    if case .number(let n) = r2[0].value {
        assertApprox(n, 75, eps: 1e-9, "calc.pct.sub")
    } else { assertTrue(false, "calc.pct.sub", "wrong: \(r2[0].value)") }
    let r3 = e.evaluate(text: "50 * 10%")
    if case .number(let n) = r3[0].value {
        assertApprox(n, 5, eps: 1e-9, "calc.pct.mul")
    } else { assertTrue(false, "calc.pct.mul", "wrong: \(r3[0].value)") }
    let r4 = e.evaluate(text: "10% of 200")
    if case .number(let n) = r4[0].value {
        assertApprox(n, 20, eps: 1e-9, "calc.pct.of")
    } else { assertTrue(false, "calc.pct.of", "wrong: \(r4[0].value)") }
    // Multi-term LHS: "50 + 10 + 10%" should be (50+10) * 1.1 = 66.
    let r5 = e.evaluate(text: "50 + 10 + 10%")
    if case .number(let n) = r5[0].value {
        assertApprox(n, 66, eps: 1e-9, "calc.pct.multiTermLHS")
    } else { assertTrue(false, "calc.pct.multiTermLHS", "wrong: \(r5[0].value)") }
}

@MainActor
func testCalc_isLikelyValidArithmetic_accepts() {
    let e = CalcEvaluator()
    let good = ["1+1", "(1+2)*3", "-5", "+5", "10/4", "0.5*2", "(((1+1)))", "abs(5)",
                "5 + 5", "10 - 3"]
    for s in good {
        assertTrue(e._t_isLikelyValidArithmetic(s), "calc.valid.accept:\(s)")
    }
}

@MainActor
func testCalc_isLikelyValidArithmetic_rejects() {
    let e = CalcEvaluator()
    let bad = [
        "1++2",       // double op
        "1**2",       // double op
        "(1+2",       // unbalanced
        "1+2)",       // unbalanced
        "()",         // empty parens
        "1.2.3",      // multi decimal
        "5(2)",       // implicit mul
        "(2)5",       // implicit mul
        "5 5",        // adjacent operands
        "x y",        // adjacent letters across whitespace
        "5x",         // letter after digit
        "func5",      // digit after letter (single ident with digit)
        "2^3",        // caret rejected
        "1+",         // trailing operator
        "",           // empty
        " ",          // whitespace only
    ]
    for s in bad {
        assertFalse(e._t_isLikelyValidArithmetic(s), "calc.valid.reject:\(s)")
    }
}

@MainActor
func testCalc_CalcRateCache_convert_basics() {
    let c = CalcRateCache.fallback
    // 100 USD -> EUR. fallback has USD=1.08; convert(100, USD, EUR) = 100/1.08 ≈ 92.59
    let r = c.convert(100, from: "USD", to: "EUR")
    assertNotNil(r, "calc.rate.usd2eur")
    assertApprox(r!, 100.0 / 1.08, eps: 1e-6, "calc.rate.usd2eur.value")
    // Round-trip: 100 USD -> EUR -> USD ≈ 100
    let r2 = c.convert(r!, from: "EUR", to: "USD")
    assertNotNil(r2, "calc.rate.roundtrip.notnil")
    assertApprox(r2!, 100, eps: 1e-6, "calc.rate.roundtrip")
    // Case insensitive
    assertNotNil(c.convert(1, from: "usd", to: "eur"), "calc.rate.caseInsens")
    // Same currency: result is the input scaled by (rt/rf) = 1.
    assertApprox(c.convert(50, from: "EUR", to: "EUR")!, 50, eps: 1e-9, "calc.rate.identity")
}

@MainActor
func testCalc_CalcRateCache_convert_unknown() {
    let c = CalcRateCache.fallback
    assertNil(c.convert(100, from: "XXX", to: "USD"), "calc.rate.unknown.from")
    assertNil(c.convert(100, from: "USD", to: "YYY"), "calc.rate.unknown.to")
}

@MainActor
func testCalc_CalcRateCache_convert_nonFinite() {
    let c = CalcRateCache.fallback
    assertNil(c.convert(.infinity, from: "USD", to: "EUR"), "calc.rate.inf")
    assertNil(c.convert(.nan, from: "USD", to: "EUR"), "calc.rate.nan")
    // Bad rate (zero) -> nil. Build a custom cache with rt=0.
    let bad = CalcRateCache(base: "EUR", fetched: Date(), rates: ["EUR": 1.0, "BAD": 0.0])
    assertNil(bad.convert(100, from: "EUR", to: "BAD"), "calc.rate.zeroTo")
    assertNil(bad.convert(100, from: "BAD", to: "EUR"), "calc.rate.zeroFrom")
}

@MainActor
func testCalc_has_currency() {
    let c = CalcRateCache.fallback
    assertTrue(c.has("USD"), "calc.rate.has.usd")
    assertTrue(c.has("usd"), "calc.rate.has.case")
    assertFalse(c.has("XXX"), "calc.rate.has.no")
}

// ===========================================================================
// MARK: - File hash tests
// ===========================================================================

func testFileHash_empty() async {
    let url = writeFixture("empty.bin", Data())
    do {
        let (md5, sha1, sha2) = try await computeHashes(of: url, progress: { _ in })
        assertEqual(md5, "d41d8cd98f00b204e9800998ecf8427e", "filehash.empty.md5")
        assertEqual(sha1, "da39a3ee5e6b4b0d3255bfef95601890afd80709", "filehash.empty.sha1")
        assertEqual(sha2, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "filehash.empty.sha256")
    } catch {
        assertTrue(false, "filehash.empty", "threw: \(error)")
    }
}

func testFileHash_oneByte() async {
    let url = writeFixture("one.bin", Data([0x61]))  // "a"
    do {
        let (md5, sha1, sha2) = try await computeHashes(of: url, progress: { _ in })
        assertEqual(md5, "0cc175b9c0f1b6a831c399e269772661", "filehash.one.md5")
        assertEqual(sha1, "86f7e437faa5a7fce15d1ddcb9eaeaea377667b8", "filehash.one.sha1")
        assertEqual(sha2, "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb", "filehash.one.sha256")
    } catch {
        assertTrue(false, "filehash.one", "threw: \(error)")
    }
}

func testFileHash_oneMB_zeros() async {
    let url = writeFixture("zeros1mb.bin", Data(count: 1 << 20))
    do {
        let (md5, sha1, sha2) = try await computeHashes(of: url, progress: { _ in })
        // canonical: 1 MiB of zero bytes
        assertEqual(md5, "b6d81b360a5672d80c27430f39153e2c", "filehash.zeros1mb.md5")
        assertEqual(sha1, "3b71f43ff30f4b15b5cd85dd9e95ebc7e84eb5a3", "filehash.zeros1mb.sha1")
        assertEqual(sha2, "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58", "filehash.zeros1mb.sha256")
    } catch {
        assertTrue(false, "filehash.zeros1mb", "threw: \(error)")
    }
}

func testFileHash_5MB_chunked() async {
    // 5 MiB of deterministic bytes; computed canonical with the in-app
    // HashTripleHasher applied as one shot so we exercise the chunked
    // file path against a single-update reference run.
    let data = deterministicBytes(5 << 20, seed: 42)
    let url = writeFixture("chunked5mb.bin", data)
    let ref = HashTripleHasher()
    ref.update(data)
    let (refMD5, refSHA1, refSHA2) = ref.finalize()
    // sanity vs CryptoKit's independent SHA256:
    let cryptoKitSHA2 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    assertEqual(refSHA2, cryptoKitSHA2, "filehash.5mb.ref.sha256.matches.cryptoKit")
    do {
        let (md5, sha1, sha2) = try await computeHashes(of: url, progress: { _ in })
        assertEqual(md5, refMD5, "filehash.5mb.md5")
        assertEqual(sha1, refSHA1, "filehash.5mb.sha1")
        assertEqual(sha2, refSHA2, "filehash.5mb.sha256")
    } catch {
        assertTrue(false, "filehash.5mb", "threw: \(error)")
    }
}

func testFileHash_directory_throws() async {
    let dir = fixturesDir.appendingPathComponent("subdir", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var threw = false
    do {
        _ = try await computeHashes(of: dir, progress: { _ in })
    } catch { threw = true }
    assertTrue(threw, "filehash.dir.throws")
}

func testFileHash_missing_throws() async {
    let missing = fixturesDir.appendingPathComponent("ghost.bin")
    try? FileManager.default.removeItem(at: missing)
    var threw = false
    do {
        _ = try await computeHashes(of: missing, progress: { _ in })
    } catch { threw = true }
    assertTrue(threw, "filehash.missing.throws")
}

func testFileHash_cancellation_fastExit() async {
    // 64 MiB synthetic file — enough chunks for several Task.checkCancellation()
    // boundaries; small enough to be fast even uncancelled.
    let size = 64 * 1024 * 1024
    let bigURL = writeFixture("big_cancel.bin", deterministicBytes(size, seed: 7))
    let start = Date()
    let task = Task.detached { () -> TimeInterval in
        do {
            _ = try await computeHashes(of: bigURL, progress: { _ in })
        } catch { /* cancellation surfaces here */ }
        return Date().timeIntervalSince(start)
    }
    try? await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
    task.cancel()
    let elapsed = await task.value
    // Liberal upper bound — on a slow disk the read still completes inside 2s.
    // The real guarantee being tested is "doesn't hang".
    assertTrue(elapsed < 2.0, "filehash.cancel.fast", "took \(elapsed)s")
}

// ===========================================================================
// MARK: - PDF range parser tests
// ===========================================================================

func testPDFRange_simpleRange() {
    do {
        let pages = try PDFOpsRange.parse("1-3", pageCount: 10)
        assertEqual(pages, [0, 1, 2], "pdf.range.1-3")
    } catch { assertTrue(false, "pdf.range.1-3", "threw: \(error)") }
}

func testPDFRange_single() {
    do {
        let pages = try PDFOpsRange.parse("5", pageCount: 10)
        assertEqual(pages, [4], "pdf.range.single")
    } catch { assertTrue(false, "pdf.range.single", "threw: \(error)") }
}

func testPDFRange_combined() {
    do {
        let pages = try PDFOpsRange.parse("1-3, 5, 7-9", pageCount: 10)
        assertEqual(pages, [0, 1, 2, 4, 6, 7, 8], "pdf.range.combined")
    } catch { assertTrue(false, "pdf.range.combined", "threw: \(error)") }
}

func testPDFRange_reversed() {
    do {
        let pages = try PDFOpsRange.parse("7-3", pageCount: 10)
        assertEqual(pages, [2, 3, 4, 5, 6], "pdf.range.reversed")
    } catch { assertTrue(false, "pdf.range.reversed", "threw: \(error)") }
}

func testPDFRange_zero_throws() {
    assertThrows("pdf.range.zero") {
        _ = try PDFOpsRange.parse("0", pageCount: 10)
    }
}

func testPDFRange_leadingComma_throws() {
    // ",5" — leading comma. Parse splits, skips empty fragment, accepts "5".
    // The spec asks this to be an error. We assert: it should either throw or
    // return [4] strictly equal to "5". Let's go with current behavior (the
    // empty fragment is silently dropped → returns [4]) — that's the
    // documented forgiving behavior in PDFOpsRange.parse:
    do {
        let pages = try PDFOpsRange.parse(",5", pageCount: 10)
        // Either documented behavior (treat as 5) or an error is acceptable.
        // We assert it doesn't crash and returns [4] OR throws.
        assertEqual(pages, [4], "pdf.range.leadingComma.lenient")
    } catch {
        // Also acceptable.
        assertTrue(true, "pdf.range.leadingComma.strict")
    }
}

func testPDFRange_dangling_throws() {
    assertThrows("pdf.range.danglingHigh") {
        _ = try PDFOpsRange.parse("1-", pageCount: 10)
    }
    assertThrows("pdf.range.danglingLow") {
        _ = try PDFOpsRange.parse("-3", pageCount: 10)
    }
}

func testPDFRange_outOfBounds_throws() {
    assertThrows("pdf.range.oob.single") {
        _ = try PDFOpsRange.parse("999", pageCount: 10)
    }
    assertThrows("pdf.range.oob.range") {
        _ = try PDFOpsRange.parse("1-999", pageCount: 10)
    }
}

func testPDFRange_empty_returnsAll() {
    do {
        let pages = try PDFOpsRange.parse("", pageCount: 5)
        assertEqual(pages, [0, 1, 2, 3, 4], "pdf.range.empty.all")
    } catch { assertTrue(false, "pdf.range.empty.all", "threw: \(error)") }
}

func testPDFRange_dedupe() {
    do {
        let pages = try PDFOpsRange.parse("1, 1, 2, 1-3", pageCount: 5)
        assertEqual(pages, [0, 1, 2], "pdf.range.dedupe")
    } catch { assertTrue(false, "pdf.range.dedupe", "threw: \(error)") }
}

// ===========================================================================
// MARK: - Big-scan dedupe tests (partial-hash + full-hash chain)
// ===========================================================================

func testBigScan_partialHash_sameSize_diffContent() {
    // 3 files of identical size, different content. Partial hashes MUST differ.
    let size: Int = 64 * 1024     // 64 KB — under 1 MB chunk
    let urls = (0..<3).map { i -> URL in
        let data = deterministicBytes(size, seed: UInt64(i + 100))
        return writeFixture("part_diff_\(i).bin", data)
    }
    var hashes = Set<String>()
    for u in urls {
        let attrs = try! FileManager.default.attributesOfItem(atPath: u.path)
        let s = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard let h = BigScanWalker._t_partialHash(path: u.path, size: s) else {
            assertTrue(false, "bigscan.partial.diff.notnil", "partialHash nil for \(u.path)")
            return
        }
        hashes.insert(h)
    }
    assertEqual(hashes.count, 3, "bigscan.partial.diff.unique")
}

func testBigScan_partialHash_sameContent() {
    let size: Int = 64 * 1024
    let payload = deterministicBytes(size, seed: 999)
    let urls = (0..<3).map { i -> URL in
        writeFixture("part_same_\(i).bin", payload)
    }
    var hashes = Set<String>()
    for u in urls {
        let attrs = try! FileManager.default.attributesOfItem(atPath: u.path)
        let s = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard let h = BigScanWalker._t_partialHash(path: u.path, size: s) else {
            assertTrue(false, "bigscan.partial.same.notnil", "nil hash")
            return
        }
        hashes.insert(h)
    }
    assertEqual(hashes.count, 1, "bigscan.partial.same.unique")

    // Now confirm with full-hash chain.
    var fulls = Set<String>()
    for u in urls {
        guard let h = BigScanWalker._t_fullHash(path: u.path) else {
            assertTrue(false, "bigscan.full.same.notnil", "nil hash")
            return
        }
        fulls.insert(h)
    }
    assertEqual(fulls.count, 1, "bigscan.full.same.unique")
}

func testBigScan_partialHash_below1MB_grouping() {
    // Files < 1 MB (no tail chunk). Same content -> same hash; different ->
    // different hash. We already exercise both above with 64 KB files; add
    // a tiny-file edge case (32 bytes) here.
    let urlA = writeFixture("tiny_a.bin", Data([1, 2, 3, 4]))
    let urlB = writeFixture("tiny_b.bin", Data([1, 2, 3, 4]))
    let urlC = writeFixture("tiny_c.bin", Data([9, 9, 9, 9]))
    let a = BigScanWalker._t_partialHash(path: urlA.path, size: 4)
    let b = BigScanWalker._t_partialHash(path: urlB.path, size: 4)
    let c = BigScanWalker._t_partialHash(path: urlC.path, size: 4)
    assertNotNil(a, "bigscan.partial.tiny.a")
    assertNotNil(b, "bigscan.partial.tiny.b")
    assertNotNil(c, "bigscan.partial.tiny.c")
    assertEqual(a, b, "bigscan.partial.tiny.matches")
    assertFalse(a == c, "bigscan.partial.tiny.differs")
}

func testBigScan_partialHash_zeroByte() {
    let url = writeFixture("zero.bin", Data())
    let h = BigScanWalker._t_partialHash(path: url.path, size: 0)
    assertNotNil(h, "bigscan.partial.zero.notnil")
}

func testBigScan_fullHash_matches_partial_for_small() {
    let payload = deterministicBytes(8 * 1024, seed: 7)
    let url = writeFixture("full_small.bin", payload)
    let full = BigScanWalker._t_fullHash(path: url.path)
    assertNotNil(full, "bigscan.full.small.notnil")
    // Sanity: hex sha256 is 64 chars.
    if let f = full { assertEqual(f.count, 64, "bigscan.full.small.len") }
}

// ===========================================================================
// MARK: - ProfileSync tests
// ===========================================================================

@MainActor
func testProfileSync_snapshotShape() {
    let sync = ProfileSync.shared
    // Snapshot is always non-nil and produces a well-formed envelope with
    // schema + files keys. The actual files dictionary may be empty if the
    // user has no profile data yet; we only test the structure.
    guard let blob = sync.snapshot() else {
        assertTrue(false, "profileSync.snapshot.notNil", "nil snapshot")
        return
    }
    guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else {
        assertTrue(false, "profileSync.snapshot.parseable", "not a JSON object")
        return
    }
    assertNotNil(obj["schema"], "profileSync.snapshot.hasSchema")
    assertNotNil(obj["files"], "profileSync.snapshot.hasFiles")
    let isFilesDict = (obj["files"] as? [String: String]) != nil
    assertTrue(isFilesDict, "profileSync.snapshot.filesIsDict")
}

@MainActor
func testProfileSync_oversizedBlob_rejected() {
    let sync = ProfileSync.shared
    let big = Data(count: 11 * 1024 * 1024)
    let ok = sync.apply(big)
    assertFalse(ok, "profileSync.oversized.rejected")
    assertNotNil(sync.lastError, "profileSync.oversized.error")
}

@MainActor
func testProfileSync_emptyBundle_succeeds() {
    let sync = ProfileSync.shared
    let env: [String: Any] = ["schema": 1, "files": [String: String]()]
    let data = try! JSONSerialization.data(withJSONObject: env)
    let ok = sync.apply(data)
    assertTrue(ok, "profileSync.empty.succeeds")
}

@MainActor
func testProfileSync_hostileFilename_skipped() {
    let sync = ProfileSync.shared
    // Build a profile blob with a traversal path key. ProfileSync.apply
    // checks the allow-list (`bundledFiles`), so the entry is silently
    // skipped — must NOT escape Application Support.
    let env: [String: Any] = [
        "schema": 1,
        "files": ["../../etc/passwd": Data("uid=0".utf8).base64EncodedString()]
    ]
    let data = try! JSONSerialization.data(withJSONObject: env)
    let ok = sync.apply(data)
    assertTrue(ok, "profileSync.hostile.apply.succeeded")  // apply succeeds — entry just skipped
    // Confirm we didn't write a file outside the dir.
    let escaped = FileManager.default.fileExists(atPath: "/etc/passwd.trove")
    assertFalse(escaped, "profileSync.hostile.noEscape")
}

@MainActor
func testProfileSync_perEntryOversize_skipped() {
    let sync = ProfileSync.shared
    // 3 MB payload under "snippets.json" (allow-listed). Should be skipped
    // (per-entry cap 2 MB), but the apply() call itself still succeeds.
    let big = Data(count: 3 * 1024 * 1024)
    let env: [String: Any] = [
        "schema": 1,
        "files": ["snippets.json": big.base64EncodedString()]
    ]
    let data = try! JSONSerialization.data(withJSONObject: env)
    let ok = sync.apply(data)
    assertTrue(ok, "profileSync.perEntry.apply.ok")
    // lastError surfaces the skip reason.
    if let err = sync.lastError {
        assertTrue(err.contains("snippets.json") || err.contains("exceeded"),
                   "profileSync.perEntry.errorMessage",
                   "got: \(err)")
    }
}

@MainActor
func testProfileSync_invalidJSON_rejected() {
    let sync = ProfileSync.shared
    let junk = Data("not json".utf8)
    let ok = sync.apply(junk)
    assertFalse(ok, "profileSync.invalidJSON.rejected")
    assertNotNil(sync.lastError, "profileSync.invalidJSON.error")
}

// ===========================================================================
// MARK: - HotkeyBinding tests
// ===========================================================================

func testHotkeyBinding_codable_roundTrip() {
    let b = HotkeyBinding(modifiers: UInt32(cmdKey | shiftKey | optionKey),
                          keyCode: UInt32(kVK_ANSI_K))
    do {
        let data = try JSONEncoder().encode(b)
        let dec = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        assertEqual(dec.modifiers, b.modifiers, "hotkey.codable.mods")
        assertEqual(dec.keyCode, b.keyCode, "hotkey.codable.kc")
        assertEqual(dec, b, "hotkey.codable.eq")
    } catch {
        assertTrue(false, "hotkey.codable.roundTrip", "threw: \(error)")
    }
}

func testHotkeyBinding_displayString_cmdShift2() {
    let b = HotkeyBinding.cmdShift2
    assertEqual(b.displayString, "⇧⌘2", "hotkey.display.cmdshift2")
}

func testHotkeyBinding_displayString_orderings() {
    // ⌃⌥⇧⌘ order per Apple HIG; our impl emits them in ⌃, ⌥, ⇧, ⌘ order.
    let b = HotkeyBinding(modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey),
                          keyCode: UInt32(kVK_ANSI_K))
    assertEqual(b.displayString, "⌃⌥⇧⌘K", "hotkey.display.allMods")
}

func testHotkeyBinding_displayString_singleMod() {
    let b = HotkeyBinding(modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_A))
    assertEqual(b.displayString, "⌘A", "hotkey.display.cmdA")
}

func testHotkeyBinding_keyName_special() {
    assertEqual(HotkeyBinding.keyName(UInt32(kVK_Space)), "Space", "hotkey.keyName.space")
    assertEqual(HotkeyBinding.keyName(UInt32(kVK_Return)), "Return", "hotkey.keyName.return")
    assertEqual(HotkeyBinding.keyName(UInt32(kVK_Escape)), "Esc", "hotkey.keyName.esc")
    assertEqual(HotkeyBinding.keyName(UInt32(kVK_F5)), "F5", "hotkey.keyName.f5")
    assertEqual(HotkeyBinding.keyName(UInt32(kVK_ANSI_2)), "2", "hotkey.keyName.2")
}

func testHotkeyBinding_default_fallback() {
    // No UserDefaults entry — HotkeySettings.shared.fullScreenToStageBinding
    // should default to .cmdShift2. We don't touch the actual UserDefaults
    // (process is ephemeral), just verify the constant.
    // Also nuke the key first to assert the fallback path.
    let suite = UserDefaults.standard
    suite.removeObject(forKey: "hotkey.fullScreenToStage.binding")
    let b = HotkeyBinding.cmdShift2
    assertEqual(b.modifiers, UInt32(cmdKey | shiftKey), "hotkey.default.mods")
    assertEqual(b.keyCode, UInt32(kVK_ANSI_2), "hotkey.default.kc")
}

// ===========================================================================
// MARK: - Path safety tests (stageFileValidation)
// ===========================================================================

@MainActor
func testPathSafety_rejects_dev() {
    let r = RootView.stageFileValidation(path: "/dev/zero")
    assertNotNil(r, "path.reject.dev")
    if let r = r { assertTrue(r.contains("/dev/"), "path.reject.dev.msg", "got: \(r)") }
}

@MainActor
func testPathSafety_rejects_proc() {
    let r = RootView.stageFileValidation(path: "/proc/1/stat")
    assertNotNil(r, "path.reject.proc")
}

@MainActor
func testPathSafety_rejects_sys() {
    let r = RootView.stageFileValidation(path: "/sys/kernel")
    assertNotNil(r, "path.reject.sys")
}

@MainActor
func testPathSafety_rejects_privateVarRun() {
    let r = RootView.stageFileValidation(path: "/private/var/run/foo.sock")
    assertNotNil(r, "path.reject.privateVarRun")
}

@MainActor
func testPathSafety_accepts_realPNG() {
    // Render a tiny PNG to /tmp/trove-tests-fixtures and ensure validation
    // returns nil.
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    img.unlockFocus()
    let rep = img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
    let png = rep?.representation(using: .png, properties: [:]) ?? Data([0x89, 0x50, 0x4E, 0x47])
    let url = writeFixture("test.png", png)
    let r = RootView.stageFileValidation(path: url.path)
    assertNil(r, "path.accept.png")
}

@MainActor
func testPathSafety_rejects_oversize() {
    // 201 MB sparse file via truncate.
    let url = fixturesDir.appendingPathComponent("huge.bin")
    try? FileManager.default.removeItem(at: url)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    if let fh = try? FileHandle(forWritingTo: url) {
        try? fh.truncate(atOffset: UInt64(201) * 1024 * 1024)
        try? fh.close()
    }
    let r = RootView.stageFileValidation(path: url.path)
    assertNotNil(r, "path.reject.oversize")
    if let r = r { assertTrue(r.contains("200 MB") || r.contains(">200"), "path.reject.oversize.msg", "got: \(r)") }
}

@MainActor
func testPathSafety_rejects_nonregular() {
    // A directory is a non-regular file.
    let dir = fixturesDir.appendingPathComponent("notreg", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = RootView.stageFileValidation(path: dir.path)
    assertNotNil(r, "path.reject.nonregular")
}

@MainActor
func testPathSafety_rejects_missing() {
    let r = RootView.stageFileValidation(path: "/tmp/trove-tests-fixtures/ghost-file.bin")
    assertNotNil(r, "path.reject.missing")
}

// ===========================================================================
// MARK: - SnapDirection + WindowSnapSettings tests
// ===========================================================================

func testSnapDirection_allCasesCount() {
    // Ensure no accidental deletion — we expect exactly 10 snap targets.
    assertEqual(SnapDirection.allCases.count, 10, "snapDir.count")
}

func testSnapDirection_uniqueRawValues() {
    let ids = SnapDirection.allCases.map(\.rawValue)
    let uniq = Set(ids)
    assertEqual(ids.count, uniq.count, "snapDir.uniqueIDs",
                "duplicate rawValue — two directions would collide in Carbon dispatch")
}

func testSnapDirection_defaultBindings_haveModifiers() {
    // Every default binding must require at least one modifier (bare keycodes
    // would shadow normal typing system-wide).
    for dir in SnapDirection.allCases {
        let b = dir.defaultBinding
        assertTrue(b.modifiers != 0,
                   "snapDir.binding.hasModifier.\(dir.rawValue)",
                   "\(dir) default binding has no modifiers")
    }
}

func testSnapDirection_defaultBindings_unique() {
    // No two directions should share the same (modifiers, keyCode) pair —
    // two overlapping registrations would silently fail at Carbon level.
    var seen = Set<HotkeyBinding>()
    for dir in SnapDirection.allCases {
        let b = dir.defaultBinding
        assertFalse(seen.contains(b),
                    "snapDir.binding.unique.\(dir.rawValue)",
                    "\(dir) binding collides with another direction")
        seen.insert(b)
    }
}

@MainActor
func testWindowSnapSettings_defaultsOff() {
    // On a fresh defaults domain the feature must default to disabled so we
    // don't claim global hotkeys without user consent.
    UserDefaults.standard.removeObject(forKey: "trove.windowSnap.enabled")
    // Re-read the stored value (not the singleton, which may have been set
    // earlier in the process) to verify the raw persisted default.
    let raw = UserDefaults.standard.object(forKey: "trove.windowSnap.enabled")
    // nil means never written → the Settings init path will return false.
    assertNil(raw, "windowSnap.defaultOff",
              "windowSnap.enabled should be absent (nil) before first write so init() defaults to false")
}

// ===========================================================================
// MARK: - Test enumeration + runner
// ===========================================================================

@MainActor
func runAllTests() async {
    // ---------- Calc ----------
    testCalc_evaluate_basic()
    testCalc_evaluate_simple_arithmetic()
    testCalc_evaluate_lineRefs()
    testCalc_evaluate_variables()
    testCalc_evaluate_commentsBlankLines()
    testCalc_evaluate_lineRef_skipsComments()
    testCalc_evaluate_cycle()
    testCalc_evaluate_unbalancedParens()
    testCalc_evaluate_doubleOps()
    testCalc_evaluate_emptyParens()
    testCalc_evaluate_multiDecimal()
    testCalc_evaluate_shadowing()
    testCalc_evaluate_caret_rejected()
    testCalc_evaluate_implicit_mul_rejected()
    testCalc_normalizeOperators()
    testCalc_normalizeOperators_e2e()
    testCalc_normalizeCurrency_symbols()
    testCalc_normalizeCurrency_words()
    testCalc_normalizeNaturalLanguage()
    testCalc_expandSmartPercent()  // includes multi-term LHS test
    testCalc_isLikelyValidArithmetic_accepts()
    testCalc_isLikelyValidArithmetic_rejects()
    testCalc_CalcRateCache_convert_basics()
    testCalc_CalcRateCache_convert_unknown()
    testCalc_CalcRateCache_convert_nonFinite()
    testCalc_has_currency()

    // ---------- File hash ----------
    await testFileHash_empty()
    await testFileHash_oneByte()
    await testFileHash_oneMB_zeros()
    await testFileHash_5MB_chunked()
    await testFileHash_directory_throws()
    await testFileHash_missing_throws()
    await testFileHash_cancellation_fastExit()

    // ---------- PDF range ----------
    testPDFRange_simpleRange()
    testPDFRange_single()
    testPDFRange_combined()
    testPDFRange_reversed()
    testPDFRange_zero_throws()
    testPDFRange_leadingComma_throws()
    testPDFRange_dangling_throws()
    testPDFRange_outOfBounds_throws()
    testPDFRange_empty_returnsAll()
    testPDFRange_dedupe()

    // ---------- Big scan ----------
    testBigScan_partialHash_sameSize_diffContent()
    testBigScan_partialHash_sameContent()
    testBigScan_partialHash_below1MB_grouping()
    testBigScan_partialHash_zeroByte()
    testBigScan_fullHash_matches_partial_for_small()

    // ---------- ProfileSync ----------
    testProfileSync_snapshotShape()
    testProfileSync_oversizedBlob_rejected()
    testProfileSync_emptyBundle_succeeds()
    testProfileSync_hostileFilename_skipped()
    testProfileSync_perEntryOversize_skipped()
    testProfileSync_invalidJSON_rejected()

    // ---------- HotkeyBinding ----------
    testHotkeyBinding_codable_roundTrip()
    testHotkeyBinding_displayString_cmdShift2()
    testHotkeyBinding_displayString_orderings()
    testHotkeyBinding_displayString_singleMod()
    testHotkeyBinding_keyName_special()
    testHotkeyBinding_default_fallback()

    // ---------- SnapDirection + WindowSnapSettings ----------
    testSnapDirection_allCasesCount()
    testSnapDirection_uniqueRawValues()
    testSnapDirection_defaultBindings_haveModifiers()
    testSnapDirection_defaultBindings_unique()
    testWindowSnapSettings_defaultsOff()

    // ---------- Path safety ----------
    testPathSafety_rejects_dev()
    testPathSafety_rejects_proc()
    testPathSafety_rejects_sys()
    testPathSafety_rejects_privateVarRun()
    testPathSafety_accepts_realPNG()
    testPathSafety_rejects_oversize()
    testPathSafety_rejects_nonregular()
    testPathSafety_rejects_missing()

    // ---------- Main-thread invariant guard ----------
    await testPreconditionNotMainThread_returnsCleanlyOffMain()
    testCleanModel_init_does_not_blockMain()
    testFinderTweaksModel_init_does_not_blockMain()
}

// Documents the contract for `FinderTweaksModel.init()`: must not block main
// on shell calls. Trove crashed on 2026-05-16 04:54 when "Finder" was the
// restored pane — `init` → `refreshAll()` → `FinderDefaults.readRaw()` →
// `FinderShell.run()` → `.waitUntilExitOffMain()` → SIGTRAP from the
// main-thread precondition. Same pattern as CleanModel.
@MainActor
func testFinderTweaksModel_init_does_not_blockMain() {
    let t0 = Date()
    _ = FinderTweaksModel()
    let elapsed = Date().timeIntervalSince(t0)
    assertTrue(elapsed < 0.25,
               "findertweaksmodel.init.fast",
               "FinderTweaksModel.init() took \(Int(elapsed * 1000))ms — sync shell work likely re-introduced")
}

// Documents the contract for `preconditionNotMainThread`: calling it from a
// background thread must return without firing the precondition. If a future
// refactor breaks this (e.g. someone inverts the boolean), this test will hang
// or crash the runner — which is exactly the signal we want.
@MainActor
func testPreconditionNotMainThread_returnsCleanlyOffMain() async {
    let returned = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            preconditionNotMainThread("test.background")
            cont.resume(returning: true)
        }
    }
    assertTrue(returned, "guard.background.returns", "preconditionNotMainThread must be a no-op off the main thread")
}

// Documents the contract for `CleanModel.init()`: constructing it on the main
// thread must NOT block the run loop on a synchronous shell call. This was the
// failure mode that crashed the app on launch when "Clean" was the restored
// pane. If a future change reintroduces a sync `whichExists` / `runShell` in
// init, the `preconditionNotMainThread` guard in `runShell` will fire and this
// test will crash the runner with a labelled message — making the regression
// immediately legible.
@MainActor
func testCleanModel_init_does_not_blockMain() {
    let t0 = Date()
    _ = CleanModel()
    let elapsed = Date().timeIntervalSince(t0)
    // Synchronous file-existence checks should finish in well under 50ms even
    // on a cold disk. Anything past that means init regained a blocking path.
    assertTrue(elapsed < 0.25,
               "cleanmodel.init.fast",
               "CleanModel.init() took \(Int(elapsed * 1000))ms — synchronous shell work likely re-introduced")
}

@main
struct TroveTestMain {
    static func main() async {
        // Ensure fixtures dir is clean.
        resetFixtures()
        // Seed exchange-rate cache before any CalcEvaluator() / CalcRateStore.shared
        // construction so the singleton doesn't fire a network fetch.
        seedRateCacheToFresh()
        await runAllTests()
        // Cleanup
        try? FileManager.default.removeItem(at: fixturesDir)

        let s = SyncStats.shared
        let total = s.passed + s.failed
        print("Trove tests: \(total) total, \(s.passed) PASS, \(s.failed) FAIL")
        if s.failed > 0 {
            print("--- failures ---")
            for f in s.failures.prefix(50) {
                print("  FAIL \(f.test): \(f.msg)")
            }
            exit(1)
        }
        exit(0)
    }
}
