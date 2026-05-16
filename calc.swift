// Trove — Smart Calculator with running tape
//   • Soulver / Numi / Calca-class natural-language calculator.
//   • Each line is its own expression; later lines reference earlier results
//     via `line1`, `line2`, … or via named variables (`tax = 0.0975`).
//   • Inline unit + currency conversion via Measurement<UnitX> and an ECB
//     exchange-rate cache fetched once on first launch (refreshed daily).
//   • "Send tape to Stage" exports a Markdown block to the shared Stage.
//
// One file, no @main / no App / no Pane. Compiles alongside main.swift.
// Type prefix: Calc*. No top-level executable code.
//
// Red-team coverage (mirrored in the summary below):
//   1. Circular reference (line2 depends on line1 depends on line2) → DAG
//      built each evaluation pass; cycles marked with a "cycle" badge per line.
//   2. ECB offline / cache miss → last known rates from disk used; "stale"
//      badge appears next to results that consumed them. Never hard-fails.
//   3. Atomic save of exchange.json → write to .tmp then rename. Load tolerates
//      corrupt JSON by silently dropping to the bundled fallback rates.
//   4. Massive tapes (1000+ lines) → re-evaluation debounced by ~120ms, and
//      the right-pane List is lazy so only visible rows render.
//   5. NSExpression security → user input is never handed raw to NSExpression.
//      The sanitizer strips any identifier that isn't a known variable, lineN
//      ref, or whitelisted math function, and rejects expressions containing
//      a function call to anything outside the allowlist.
//   6. Number formatting → DISPLAY honors Locale.current. PARSING accepts
//      both '.' and ',' as decimal separators by normalizing inputs.
//   7. Variable shadowing → last assignment wins. Earlier definitions get a
//      "shadowed" hint badge so the user notices.

import SwiftUI
import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Result model
// ===========================================================================

/// What a single line evaluated to. We keep both a numeric value (for
/// downstream lineN references) and a display string so unit-bearing results
/// can render with their suffix without re-deriving it.
enum CalcValue: Hashable {
    case number(Double)
    case measurement(value: Double, unitSymbol: String)   // generic dimensioned
    case money(amount: Double, currency: String, stale: Bool)
    case empty
    case assignment(name: String, inner: Box)             // RHS evaluated
    case error(String)

    /// Indirect storage so `assignment` can hold another `CalcValue`.
    final class Box: Hashable {
        let v: CalcValue
        init(_ v: CalcValue) { self.v = v }
        static func == (a: Box, b: Box) -> Bool { a.v == b.v }
        func hash(into h: inout Hasher) { h.combine(v) }
    }

    /// The numeric value other lines see when they reference this one.
    /// Assignment lines pass through their RHS so `x = 5 mi`; `x in km`
    /// works as expected.
    var numericForReference: Double? {
        switch self {
        case .number(let n):                       return n
        case .measurement(let v, _):               return v
        case .money(let v, _, _):                  return v
        case .assignment(_, let inner):            return inner.v.numericForReference
        case .empty, .error:                       return nil
        }
    }

    var isError: Bool { if case .error = self { return true } else { return false } }
    var isStale: Bool {
        switch self {
        case .money(_, _, let s):       return s
        case .assignment(_, let inner): return inner.v.isStale
        default:                        return false
        }
    }
}

struct CalcLineResult: Identifiable, Hashable {
    let id: Int                  // 1-indexed line number
    let display: String          // pre-formatted, locale-aware
    let value: CalcValue
    let errorText: String?
    let shadowedHint: String?    // non-nil if this line's assignment was later shadowed
}

// ===========================================================================
// MARK: - Exchange rate cache (ECB)
// ===========================================================================

/// Persisted cache of ECB exchange rates. Base currency is EUR (matches the
/// ECB feed). The cache lives at
/// `~/Library/Application Support/Trove/exchange.json`.
struct CalcRateCache: Codable {
    var base: String                 // always "EUR" from ECB
    var fetched: Date
    var rates: [String: Double]      // currency code → units per 1 EUR

    /// A small built-in fallback so the calculator still does *something* if
    /// (a) we've never reached the network and (b) the on-disk file is gone
    /// or corrupt. Numbers are intentionally rough — they're flagged stale.
    static let fallback = CalcRateCache(
        base: "EUR",
        fetched: Date(timeIntervalSince1970: 0),
        rates: [
            "EUR": 1.00,  "USD": 1.08,  "GBP": 0.86,  "JPY": 165.0,
            "CHF": 0.95,  "CAD": 1.48,  "AUD": 1.64,  "NZD": 1.78,
            "CNY": 7.80,  "INR": 90.0,  "MXN": 18.5,  "BRL": 5.40,
            "SEK": 11.5,  "NOK": 11.4,  "DKK": 7.46,  "PLN": 4.30,
            "TRY": 35.0,  "ZAR": 19.8,  "KRW": 1450.0, "SGD": 1.46,
            "HKD": 8.43,  "TWD": 35.0,  "THB": 38.0,  "IDR": 17000.0,
            "PHP": 60.0,  "MYR": 4.85,  "ILS": 4.00,  "AED": 3.97,
            "SAR": 4.05,  "RUB": 100.0, "CZK": 24.5,  "HUF": 390.0,
            "RON": 4.97,  "BGN": 1.96,  "ISK": 150.0, "ARS": 1100.0,
        ]
    )

    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Trove", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("exchange.json")
    }

    /// Load whatever's on disk. Returns nil if file missing or unreadable —
    /// callers fall back to `.fallback`.
    static func loadFromDisk() -> CalcRateCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CalcRateCache.self, from: data)
    }

    /// Atomic write: write to a sibling .tmp then rename. If the encode or
    /// write fails we leave the previous file untouched — better stale than
    /// corrupt.
    func saveToDisk() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let target = Self.fileURL
        let tmp = target.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            // FileManager.replaceItemAt does the safe rename across volumes.
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } catch {
            // Best-effort cleanup of the tmp; don't surface the error.
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// True if the on-disk fetch is older than 24h (so we should refresh on
    /// next launch — but we never block evaluation on the network).
    var isStale: Bool { Date().timeIntervalSince(fetched) > 24 * 3600 }

    /// Convert `amount` from `from` currency to `to`, both 3-letter codes.
    /// Returns nil if either currency isn't in the table.
    func convert(_ amount: Double, from: String, to: String) -> Double? {
        let f = from.uppercased(), t = to.uppercased()
        // red-team: require rf > 0 (not just rf != 0) — a negative rate from a
        // malformed feed would silently flip the sign of every converted amount.
        guard let rf = rates[f], let rt = rates[t], rf > 0 else { return nil }
        // red-team: reject NaN/non-finite rates or amounts so a malformed ECB feed can't propagate Inf into NumberFormatter/display
        guard amount.isFinite, rf.isFinite, rt.isFinite, rt > 0 else { return nil }
        // amount EUR-equivalent = amount / rf;  result = that * rt
        let result = amount / rf * rt
        guard result.isFinite else { return nil }
        return result
    }

    func has(_ code: String) -> Bool { rates[code.uppercased()] != nil }
}

/// Singleton-ish holder. ObservableObject so the calc view can react to
/// the first-launch fetch completing.
@MainActor
final class CalcRateStore: ObservableObject {
    static let shared = CalcRateStore()

    @Published private(set) var cache: CalcRateCache
    @Published private(set) var fetching: Bool = false

    /// True if the rates we're using were never confirmed from the network
    /// or are older than 24h. Drives the "stale" badge next to currency
    /// conversions.
    var ratesAreStale: Bool { cache.fetched.timeIntervalSince1970 == 0 || cache.isStale }

    private init() {
        // Load from disk on init. If anything goes wrong, fall back gracefully.
        self.cache = CalcRateCache.loadFromDisk() ?? CalcRateCache.fallback

        // Fire ONE refresh attempt on first launch if the file is missing or
        // the data is older than 24h. No retries, no polling. URLSession's
        // single attempt is fire-and-forget.
        if ratesAreStale {
            refreshOnce()
        }
    }

    func refreshOnce() {
        guard !fetching else { return }
        fetching = true
        Task { [weak self] in
            let fresh = await CalcRateStore.fetchECB()
            guard let self = self else { return }
            self.fetching = false
            if let fresh = fresh {
                self.cache = fresh
                fresh.saveToDisk()
            }
        }
    }

    // red-team: called from applicationDidBecomeActive and NSWorkspace.didWake.
    // Re-fetches only when the cached rates are stale (>24h or never), avoiding
    // a hit to ECB on every window focus. Mirrors init() logic for >1h-sleep
    // wake: if the user's Mac slept overnight, the daily ECB rates have rolled
    // over and we should grab fresh ones without making the user click "Refresh".
    func refreshIfStale() {
        if ratesAreStale { refreshOnce() }
    }

    /// Fetch the ECB daily reference rates. Returns nil on any failure —
    /// caller keeps the old cache. ECB serves a tiny XML feed; we parse it
    /// inline with NSXMLParser to avoid pulling in a dependency.
    nonisolated static func fetchECB() async -> CalcRateCache? {
        let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let parser = CalcECBParser()
            guard let rates = parser.parse(data) else { return nil }
            // red-team: ECB doesn't ship every currency in our fallback table
            // (no RUB since 2022, no AED/SAR/ARS/TWD ever). Merging fresh
            // rates ON TOP of the fallback preserves those codes; without
            // this, a successful fetch would silently drop them and a user
            // typing "100 USD in AED" would suddenly see "unknown currency".
            var out = CalcRateCache.fallback.rates
            for (k, v) in rates { out[k] = v }
            // Inject EUR=1 since the feed expresses rates per-EUR but omits EUR itself.
            out["EUR"] = 1.0
            return CalcRateCache(base: "EUR", fetched: Date(), rates: out)
        } catch {
            return nil
        }
    }
}

/// Minimal SAX-style XML parser for the ECB feed. Extracts every
/// `<Cube currency="XXX" rate="..."/>` element. We don't validate the
/// document structure beyond that — anything missing just doesn't end up in
/// the dictionary.
private final class CalcECBParser: NSObject, XMLParserDelegate {
    var rates: [String: Double] = [:]
    func parse(_ data: Data) -> [String: Double]? {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse() ? rates : nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Cube" else { return }
        if let cur = attributeDict["currency"],
           let r = attributeDict["rate"],
           let v = Double(r) {
            // red-team: skip non-positive / non-finite rates so a malformed feed can't divide-by-zero or NaN-poison the cache
            guard v.isFinite, v > 0 else { return }
            rates[cur.uppercased()] = v
        }
    }
}

// ===========================================================================
// MARK: - Evaluator
// ===========================================================================

/// Self-contained tape evaluator. One instance per `CalcView` body; it's
/// cheap to recreate but we keep it across edits to avoid re-allocating
/// the regex objects.
@MainActor
final class CalcEvaluator {

    private let rateStore: CalcRateStore

    init(rateStore: CalcRateStore? = nil) {
        self.rateStore = rateStore ?? CalcRateStore.shared
    }

    // -----------------------------------------------------------------
    // MARK: Currency + unit dictionaries
    // -----------------------------------------------------------------

    /// 3-letter currency codes recognized in input. Limited to what we have
    /// rates for (fallback table + whatever ECB ships). Built lazily from
    /// the rate store so adding new currencies upstream Just Works.
    private var currencyCodes: Set<String> {
        Set(rateStore.cache.rates.keys.map { $0.uppercased() })
    }

    /// Map of unit aliases → (Foundation Dimension, canonical symbol).
    /// We use Measurement<Dimension> via type-erasure: each entry stores a
    /// closure that constructs the Measurement and a closure that converts
    /// to a target unit symbol. Keeps the rest of the evaluator generic.
    struct UnitEntry {
        let make: (Double) -> AnyCalcMeasurement
        let symbol: String
        let dimensionKey: String   // groups compatible units (e.g. "length")
    }

    /// Type-erased wrapper around `Measurement<UnitX>` so we can move
    /// values around without committing to a generic.
    struct AnyCalcMeasurement {
        let value: Double
        let symbol: String
        let dimensionKey: String
        /// Convert to a target unit alias if compatible. Returns nil if the
        /// target alias isn't in the table or isn't dimensionally compatible.
        let convert: (_ targetAlias: String) -> AnyCalcMeasurement?
    }

    /// All known unit aliases. Lower-cased for case-insensitive lookup.
    /// The closures below build the appropriate Measurement<Unit*> internally.
    /// We don't try to be exhaustive — this is the Numi/Soulver core set.
    private static let units: [String: UnitEntry] = {
        var m: [String: UnitEntry] = [:]

        // Length
        let lengthMap: [(String, UnitLength, String)] = [
            ("mm", .millimeters, "mm"),
            ("cm", .centimeters, "cm"),
            ("m",  .meters,      "m"),
            ("meter", .meters,   "m"),
            ("meters", .meters,  "m"),
            ("km", .kilometers,  "km"),
            ("in", .inches,      "in"),
            ("inch", .inches,    "in"),
            ("inches", .inches,  "in"),
            ("ft", .feet,        "ft"),
            ("feet", .feet,      "ft"),
            ("yd", .yards,       "yd"),
            ("yard", .yards,     "yd"),
            ("yards", .yards,    "yd"),
            ("mi", .miles,       "mi"),
            ("mile", .miles,     "mi"),
            ("miles", .miles,    "mi"),
        ]
        for (alias, unit, sym) in lengthMap {
            m[alias] = UnitEntry(
                make: { v in
                    let meas = Measurement(value: v, unit: unit)
                    return AnyCalcMeasurement(
                        value: v, symbol: sym, dimensionKey: "length",
                        convert: { tgt in
                            guard let target = units[tgt.lowercased()],
                                  target.dimensionKey == "length",
                                  let targetUnit = unitLengthFor(target.symbol)
                            else { return nil }
                            let converted = meas.converted(to: targetUnit)
                            return AnyCalcMeasurement(
                                value: converted.value, symbol: target.symbol,
                                dimensionKey: "length",
                                convert: { _ in nil }
                            )
                        }
                    )
                },
                symbol: sym, dimensionKey: "length"
            )
        }

        // Mass
        let massMap: [(String, UnitMass, String)] = [
            ("mg", .milligrams,  "mg"),
            ("g",  .grams,       "g"),
            ("gram", .grams,     "g"),
            ("grams", .grams,    "g"),
            ("kg", .kilograms,   "kg"),
            ("oz", .ounces,      "oz"),
            ("lb", .pounds,      "lb"),
            ("lbs", .pounds,     "lb"),
            ("pound", .pounds,   "lb"),
            ("pounds", .pounds,  "lb"),
            ("ton", .metricTons, "t"),
            ("tons", .metricTons,"t"),
            ("t",   .metricTons, "t"),
        ]
        for (alias, unit, sym) in massMap {
            m[alias] = UnitEntry(
                make: { v in
                    let meas = Measurement(value: v, unit: unit)
                    return AnyCalcMeasurement(
                        value: v, symbol: sym, dimensionKey: "mass",
                        convert: { tgt in
                            guard let target = units[tgt.lowercased()],
                                  target.dimensionKey == "mass",
                                  let targetUnit = unitMassFor(target.symbol)
                            else { return nil }
                            let c = meas.converted(to: targetUnit)
                            return AnyCalcMeasurement(value: c.value, symbol: target.symbol,
                                                     dimensionKey: "mass",
                                                     convert: { _ in nil })
                        }
                    )
                },
                symbol: sym, dimensionKey: "mass"
            )
        }

        // Volume (small set)
        let volMap: [(String, UnitVolume, String)] = [
            ("ml", .milliliters, "mL"),
            ("l",  .liters,      "L"),
            ("liter", .liters,   "L"),
            ("liters", .liters,  "L"),
            ("gal", .gallons,    "gal"),
            ("cup", .cups,       "cup"),
            ("cups", .cups,      "cup"),
            ("tbsp", .tablespoons, "tbsp"),
            ("tsp",  .teaspoons,   "tsp"),
            ("floz", .fluidOunces, "fl oz"),
        ]
        for (alias, unit, sym) in volMap {
            m[alias] = UnitEntry(
                make: { v in
                    let meas = Measurement(value: v, unit: unit)
                    return AnyCalcMeasurement(
                        value: v, symbol: sym, dimensionKey: "volume",
                        convert: { tgt in
                            guard let target = units[tgt.lowercased()],
                                  target.dimensionKey == "volume",
                                  let targetUnit = unitVolumeFor(target.symbol)
                            else { return nil }
                            let c = meas.converted(to: targetUnit)
                            return AnyCalcMeasurement(value: c.value, symbol: target.symbol,
                                                     dimensionKey: "volume",
                                                     convert: { _ in nil })
                        }
                    )
                },
                symbol: sym, dimensionKey: "volume"
            )
        }

        // Duration
        let durMap: [(String, UnitDuration, String)] = [
            ("sec", .seconds, "s"),
            ("secs", .seconds, "s"),
            ("s",   .seconds, "s"),
            ("seconds", .seconds, "s"),
            ("min", .minutes, "min"),
            ("mins", .minutes, "min"),
            ("minute", .minutes, "min"),
            ("minutes", .minutes, "min"),
            ("hr",   .hours, "hr"),
            ("hrs",  .hours, "hr"),
            ("hour", .hours, "hr"),
            ("hours", .hours, "hr"),
        ]
        for (alias, unit, sym) in durMap {
            m[alias] = UnitEntry(
                make: { v in
                    let meas = Measurement(value: v, unit: unit)
                    return AnyCalcMeasurement(
                        value: v, symbol: sym, dimensionKey: "duration",
                        convert: { tgt in
                            guard let target = units[tgt.lowercased()],
                                  target.dimensionKey == "duration",
                                  let targetUnit = unitDurationFor(target.symbol)
                            else { return nil }
                            let c = meas.converted(to: targetUnit)
                            return AnyCalcMeasurement(value: c.value, symbol: target.symbol,
                                                     dimensionKey: "duration",
                                                     convert: { _ in nil })
                        }
                    )
                },
                symbol: sym, dimensionKey: "duration"
            )
        }

        return m
    }()

    /// Static accessor so the closures above can re-enter the dictionary.
    private static func units(_ alias: String) -> UnitEntry? {
        units[alias.lowercased()]
    }

    // -----------------------------------------------------------------
    // MARK: Per-symbol lookup helpers for Measurement conversions.
    // -----------------------------------------------------------------

    fileprivate static func unitLengthFor(_ sym: String) -> UnitLength? {
        switch sym {
        case "mm": return .millimeters
        case "cm": return .centimeters
        case "m":  return .meters
        case "km": return .kilometers
        case "in": return .inches
        case "ft": return .feet
        case "yd": return .yards
        case "mi": return .miles
        default:   return nil
        }
    }
    fileprivate static func unitMassFor(_ sym: String) -> UnitMass? {
        switch sym {
        case "mg": return .milligrams
        case "g":  return .grams
        case "kg": return .kilograms
        case "oz": return .ounces
        case "lb": return .pounds
        case "t":  return .metricTons
        default:   return nil
        }
    }
    fileprivate static func unitVolumeFor(_ sym: String) -> UnitVolume? {
        switch sym {
        case "mL":     return .milliliters
        case "L":      return .liters
        case "gal":    return .gallons
        case "cup":    return .cups
        case "tbsp":   return .tablespoons
        case "tsp":    return .teaspoons
        case "fl oz":  return .fluidOunces
        default:       return nil
        }
    }
    fileprivate static func unitDurationFor(_ sym: String) -> UnitDuration? {
        switch sym {
        case "s":   return .seconds
        case "min": return .minutes
        case "hr":  return .hours
        default:    return nil
        }
    }

    // -----------------------------------------------------------------
    // MARK: Evaluation entry point
    // -----------------------------------------------------------------

    /// Evaluate every line of `text`. Returns one `CalcLineResult` per input
    /// line (including blank ones — they map to `.empty`). Variables and
    /// lineN refs flow forward; circular refs are detected and flagged.
    func evaluate(text: String) -> [CalcLineResult] {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // First pass: parse each line into (rawText, optional assignment name).
        // We don't actually evaluate yet — we need the dependency graph first
        // so we can catch cycles before NSExpression chokes.
        var parsed: [(raw: String, varName: String?)] = []
        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                parsed.append((raw, nil))
                continue
            }
            if let (name, _) = splitAssignment(trimmed) {
                parsed.append((raw, name))
            } else {
                parsed.append((raw, nil))
            }
        }

        // Build variable-name → line-index map. Last assignment wins
        // (per Numi behavior); previous defs get a shadow hint.
        var varToLine: [String: Int] = [:]
        var shadowedAt: [Int: String] = [:]  // line idx → name it shadowed
        for (idx, p) in parsed.enumerated() {
            guard let name = p.varName else { continue }
            if let prior = varToLine[name] {
                shadowedAt[prior] = name
            }
            varToLine[name] = idx
        }

        // Build the user-visible line numbering map. `line1` in the tape
        // refers to the FIRST non-comment / non-blank line as the user sees
        // it, not raw array index 0 (which is often a header comment and
        // would silently substitute 0).
        var lineIdxOfDisplay: [Int: Int] = [:]
        do {
            var n = 0
            for (i, p) in parsed.enumerated() {
                let t = p.raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("//") { continue }
                n += 1
                lineIdxOfDisplay[n] = i
            }
        }

        // Dependency graph for cycle detection. node = line index.
        // Edge i → j means "line i needs the value of line j".
        var edges: [Int: Set<Int>] = [:]
        for (i, p) in parsed.enumerated() {
            let refs = referencedIndices(in: p.raw,
                                         currentIdx: i,
                                         varToLine: varToLine,
                                         lineIdxOfDisplay: lineIdxOfDisplay)
            edges[i] = refs
        }

        let cyclicLines = detectCycles(in: edges)

        // Second pass: evaluate in order. Results from earlier lines feed
        // into later lines via `lineN` references. Cyclic lines short-
        // circuit to an error before they hit the evaluator.
        var results: [CalcLineResult] = []
        var values: [Int: CalcValue] = [:]      // line idx → result value
        var vars:   [String: CalcValue] = [:]   // var name → latest value

        for (i, p) in parsed.enumerated() {
            let lineNumber = i + 1
            let trimmed = p.raw.trimmingCharacters(in: .whitespaces)

            // Blank line: emit an empty placeholder so right-pane stays aligned.
            if trimmed.isEmpty {
                results.append(CalcLineResult(id: lineNumber, display: "",
                                              value: .empty, errorText: nil,
                                              shadowedHint: nil))
                continue
            }
            // Comment lines starting with `#` or `//` — return empty.
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                results.append(CalcLineResult(id: lineNumber, display: "",
                                              value: .empty, errorText: nil,
                                              shadowedHint: nil))
                continue
            }

            // Cycle short-circuit
            if cyclicLines.contains(i) {
                results.append(CalcLineResult(
                    id: lineNumber, display: "↻ cycle",
                    value: .error("circular reference"),
                    errorText: "circular reference",
                    shadowedHint: shadowedAt[i]
                ))
                values[i] = .error("circular reference")
                continue
            }

            // Evaluate
            let outcome = evaluateLine(trimmed,
                                       lineIdx: i,
                                       priorValues: values,
                                       priorVars: vars,
                                       varToLine: varToLine,
                                       lineIdxOfDisplay: lineIdxOfDisplay)

            values[i] = outcome.value
            if case .assignment(let name, let inner) = outcome.value {
                vars[name] = inner.v
            }
            let display = (outcome.value.isError ? "" : formatValue(outcome.value))
            results.append(CalcLineResult(
                id: lineNumber, display: display,
                value: outcome.value, errorText: outcome.errorText,
                shadowedHint: shadowedAt[i]
            ))
        }

        return results
    }

    // -----------------------------------------------------------------
    // MARK: Line parsing helpers
    // -----------------------------------------------------------------

    /// Detect `name = expr` syntax. Returns nil for comparisons (`==`, `>=`,
    /// etc.) and for cases where the LHS isn't a valid identifier.
    private func splitAssignment(_ line: String) -> (name: String, rhs: String)? {
        // First `=` that isn't part of `==`, `!=`, `<=`, `>=`.
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "=" {
                if i + 1 < chars.count, chars[i+1] == "=" { i += 2; continue }
                if i > 0, "!<>".contains(chars[i-1]) { i += 1; continue }
                let lhs = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                let rhs = String(chars[(i+1)...]).trimmingCharacters(in: .whitespaces)
                guard isValidIdentifier(lhs), !rhs.isEmpty else { return nil }
                // Reject reserved tokens — never let users assign over `lineN`
                // or unit aliases.
                if lhs.lowercased().hasPrefix("line"),
                   Int(lhs.dropFirst(4)) != nil { return nil }
                if Self.units(lhs) != nil { return nil }
                if currencyCodes.contains(lhs.uppercased()) { return nil }
                return (lhs, rhs)
            }
            i += 1
        }
        return nil
    }

    private func isValidIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Find all line/variable references in an expression. Used both for
    /// cycle detection and for substitution.
    private func referencedIndices(in raw: String,
                                   currentIdx: Int,
                                   varToLine: [String: Int],
                                   lineIdxOfDisplay: [Int: Int]) -> Set<Int> {
        var out: Set<Int> = []
        // lineN
        let lineRe = try? NSRegularExpression(pattern: #"\bline(\d+)\b"#,
                                              options: .caseInsensitive)
        let ns = raw as NSString
        lineRe?.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges > 1 else { return }
            if let n = Int(ns.substring(with: m.range(at: 1))),
               let idx = lineIdxOfDisplay[n], idx != currentIdx {
                out.insert(idx)
            }
        }
        // Variable identifiers
        let idRe = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        idRe?.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let tok = ns.substring(with: m.range)
            if let owner = varToLine[tok], owner != currentIdx {
                out.insert(owner)
            }
        }
        return out
    }

    /// Tarjan-lite cycle detection. We only need the set of nodes that are
    /// part of *any* cycle — exact SCC decomposition is overkill here.
    private func detectCycles(in edges: [Int: Set<Int>]) -> Set<Int> {
        var inCycle: Set<Int> = []
        for start in edges.keys {
            // DFS from start; if we revisit start, every node on the stack
            // is in a cycle.
            var stack: [(node: Int, iter: Set<Int>.Iterator)] = []
            var onStack: Set<Int> = [start]
            stack.append((start, (edges[start] ?? []).makeIterator()))

            while !stack.isEmpty {
                var top = stack.removeLast()
                if let next = top.iter.next() {
                    stack.append(top)
                    if next == start {
                        // cycle: mark everything currently on the stack
                        for s in stack { inCycle.insert(s.node) }
                        inCycle.insert(start)
                        continue
                    }
                    if onStack.contains(next) { continue }
                    onStack.insert(next)
                    stack.append((next, (edges[next] ?? []).makeIterator()))
                } else {
                    onStack.remove(top.node)
                }
            }
        }
        return inCycle
    }

    // -----------------------------------------------------------------
    // MARK: Single-line evaluation
    // -----------------------------------------------------------------

    private struct LineOutcome {
        let value: CalcValue
        let errorText: String?
    }

    private func evaluateLine(_ raw: String,
                              lineIdx: Int,
                              priorValues: [Int: CalcValue],
                              priorVars: [String: CalcValue],
                              varToLine: [String: Int],
                              lineIdxOfDisplay: [Int: Int]) -> LineOutcome {

        // Assignment?
        if let (name, rhs) = splitAssignment(raw) {
            let inner = evaluateExpression(rhs,
                                           priorValues: priorValues,
                                           priorVars: priorVars,
                                           varToLine: varToLine,
                                           lineIdxOfDisplay: lineIdxOfDisplay)
            if case .error(let msg) = inner {
                return LineOutcome(value: .error(msg), errorText: msg)
            }
            return LineOutcome(value: .assignment(name: name, inner: .init(inner)),
                               errorText: nil)
        }

        let v = evaluateExpression(raw,
                                   priorValues: priorValues,
                                   priorVars: priorVars,
                                   varToLine: varToLine,
                                   lineIdxOfDisplay: lineIdxOfDisplay)
        if case .error(let msg) = v {
            return LineOutcome(value: v, errorText: msg)
        }
        return LineOutcome(value: v, errorText: nil)
    }

    /// The actual expression evaluator. Tries, in order:
    ///   1. Currency conversion ("100 USD in EUR")
    ///   2. Unit conversion ("5 mi to km")
    ///   3. Pure-arithmetic sanitization → NSExpression
    /// Percent semantics are normalized before substitution.
    /// Unicode + "x" math operators normalization. Lets users write `2 x 3`,
    /// `2×3`, `100÷4`, and pasted Unicode minus signs (`−` `–` `—`).
    private func normalizeOperators(_ expr: String) -> String {
        var out = expr
        // Unicode math operators → ASCII
        out = out.replacingOccurrences(of: "×", with: "*")
        out = out.replacingOccurrences(of: "÷", with: "/")
        out = out.replacingOccurrences(of: "−", with: "-")  // U+2212 minus sign
        out = out.replacingOccurrences(of: "–", with: "-")  // en-dash
        out = out.replacingOccurrences(of: "—", with: "-")  // em-dash
        out = out.replacingOccurrences(of: "\u{00A0}", with: " ")  // NBSP from autocorrect

        // `x` / `X` as multiplication, only between operands. This avoids
        // breaking variables named `x`.
        if let re = try? NSRegularExpression(pattern: #"(\d|\))\s*[xX]\s*(?=\d|\()"#) {
            let ns = out as NSString
            out = re.stringByReplacingMatches(in: out,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: "$1 * ")
        }
        return out
    }

    /// Currency-symbol + currency-name normalization. Lets users write
    /// `$100 in EUR`, `100 dollars to euros`, `€50 to GBP`, etc. — collapses
    /// to the canonical ISO-3 codes the converter understands.
    private func normalizeCurrencyTokens(_ expr: String) -> String {
        var out = expr

        // Symbol → ISO. Both prefix ($100) and suffix (100$) forms.
        let symToCode: [(symbol: String, code: String)] = [
            ("\\$", "USD"), ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"),
            ("₹", "INR"), ("₩", "KRW"), ("₽", "RUB"), ("₣", "CHF"),
            ("₺", "TRY"), ("₪", "ILS"), ("₱", "PHP"), ("฿", "THB"),
            ("R\\$", "BRL"), ("kr", "SEK"),
        ]
        for (sym, code) in symToCode {
            if let re = try? NSRegularExpression(pattern: "\(sym)\\s*(\\d[\\d.,]*)") {
                let ns = out as NSString
                out = re.stringByReplacingMatches(in: out,
                                                  range: NSRange(location: 0, length: ns.length),
                                                  withTemplate: "$1 \(code)")
            }
            if let re = try? NSRegularExpression(pattern: "(\\d[\\d.,]*)\\s*\(sym)") {
                let ns = out as NSString
                out = re.stringByReplacingMatches(in: out,
                                                  range: NSRange(location: 0, length: ns.length),
                                                  withTemplate: "$1 \(code)")
            }
        }

        // Currency words → ISO. Case-insensitive.
        let nameToCode: [(pattern: String, code: String)] = [
            (#"\bdollars?\b"#, "USD"),
            (#"\beuros?\b"#, "EUR"),
            (#"\bpounds?\b"#, "GBP"),
            (#"\bsterling\b"#, "GBP"),
            (#"\byen\b"#, "JPY"),
            (#"\brupees?\b"#, "INR"),
            (#"\byuan\b"#, "CNY"),
            (#"\brmb\b"#, "CNY"),
            (#"\bwon\b"#, "KRW"),
            (#"\brubles?\b"#, "RUB"),
            (#"\broubles?\b"#, "RUB"),
            (#"\bfrancs?\b"#, "CHF"),
            (#"\breais\b"#, "BRL"),
            (#"\breals?\b"#, "BRL"),
            (#"\bpesos?\b"#, "MXN"),
            (#"\bliras?\b"#, "TRY"),
            (#"\bshekels?\b"#, "ILS"),
            (#"\briyals?\b"#, "SAR"),
            (#"\bdirhams?\b"#, "AED"),
            (#"\brand\b"#, "ZAR"),
        ]
        for (pat, code) in nameToCode {
            guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { continue }
            let ns = out as NSString
            out = re.stringByReplacingMatches(in: out,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: code)
        }
        return out
    }

    /// Natural-language phrase normalization. Lets users write "200 by 7",
    /// "100 divided by 4", "10% of 200", etc. Applied AFTER currency/unit
    /// detection (which uses its own keywords "in"/"to"/"as") so we don't
    /// trample those.
    private func normalizeNaturalLanguage(_ expr: String) -> String {
        // Order matters: multi-word phrases first.
        let patterns: [(String, String)] = [
            (#"\bdivided\s+by\b"#, " / "),
            (#"\bmultiplied\s+by\b"#, " * "),
            (#"\btimes\b"#, " * "),
            (#"\bplus\b"#, " + "),
            (#"\bminus\b"#, " - "),
            (#"\bover\b"#, " / "),
            (#"\bof\b"#, " * "),     // "10% of 200" → "10% * 200"
            (#"\bby\b"#, " * "),     // "200 by 7" → 1400 (Soulver convention)
        ]
        var out = expr
        for (p, r) in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            let ns = out as NSString
            out = re.stringByReplacingMatches(in: out,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: r)
        }
        return out
    }

    private func evaluateExpression(_ expr: String,
                                    priorValues: [Int: CalcValue],
                                    priorVars: [String: CalcValue],
                                    varToLine: [String: Int],
                                    lineIdxOfDisplay: [Int: Int]) -> CalcValue {
        // Substitute lineN and variable references first. Each ref becomes
        // a plain number literal.
        var substituted = substituteRefs(expr,
                                         priorValues: priorValues,
                                         priorVars: priorVars,
                                         varToLine: varToLine,
                                         lineIdxOfDisplay: lineIdxOfDisplay)

        // Operator normalization: ×, ÷, −, x-as-multiplication, NBSP. Done
        // first so every downstream step sees ASCII operators.
        substituted = normalizeOperators(substituted)

        // Currency normalization: $/€/£/¥ → ISO, "dollars"/"euros"/etc. → ISO.
        // Done before conversion detection so "100 dollars in euros" parses.
        substituted = normalizeCurrencyTokens(substituted)

        // Currency conversion: "AMOUNT CCY (in|to|as) CCY"
        if let result = tryCurrencyConversion(substituted) {
            return result
        }
        // Unit conversion: "VALUE unit (in|to) unit"
        if let result = tryUnitConversion(substituted) {
            return result
        }
        // Standalone money literal: "100 USD"
        if let money = tryStandaloneMoney(substituted) {
            return money
        }
        // Standalone measurement: "5 km"
        if let meas = tryStandaloneMeasurement(substituted) {
            return meas
        }

        // Natural-language word operators ("200 by 7" → "200 * 7", "10% of 200" → "10% * 200").
        // Done here, AFTER unit/currency detection so "5 mi to km" still parses correctly.
        let withWords = normalizeNaturalLanguage(substituted)

        // Arithmetic with smart percent. Resolve "X + Y%" first.
        let withPercent = expandSmartPercent(withWords)

        switch evaluateArithmetic(withPercent) {
        case .success(let n):  return .number(n)
        case .failure(let m):  return .error(m)
        }
    }

    // -----------------------------------------------------------------
    // MARK: Substitution
    // -----------------------------------------------------------------

    /// Replace `lineN` and identifier references with their numeric value.
    /// If a reference resolves to money or a measurement we currently
    /// substitute the bare number — full propagation of units across
    /// arithmetic is a known limitation (we'd need a proper expression tree
    /// to do it right).
    private func substituteRefs(_ expr: String,
                                priorValues: [Int: CalcValue],
                                priorVars: [String: CalcValue],
                                varToLine: [String: Int],
                                lineIdxOfDisplay: [Int: Int]) -> String {
        var out = expr
        // lineN — maps user-visible line ordinal (1-based, skipping
        // comments/blanks) to the underlying array index.
        let lineRe = try? NSRegularExpression(pattern: #"\bline(\d+)\b"#,
                                              options: .caseInsensitive)
        if let re = lineRe {
            let ns = out as NSString
            var replacements: [(NSRange, String)] = []
            re.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, m.numberOfRanges > 1 else { return }
                if let n = Int(ns.substring(with: m.range(at: 1))),
                   let idx = lineIdxOfDisplay[n],
                   let val = priorValues[idx]?.numericForReference {
                    replacements.append((m.range, formatNumberForSubstitution(val)))
                } else {
                    replacements.append((m.range, "0"))
                }
            }
            // Apply in reverse so ranges stay valid.
            for (range, repl) in replacements.reversed() {
                out = (out as NSString).replacingCharacters(in: range, with: repl)
            }
        }
        // Identifiers — only replace those we have values for, in reverse
        // so substring overlaps don't bite.
        let idRe = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        if let re = idRe {
            let ns = out as NSString
            var replacements: [(NSRange, String)] = []
            re.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m else { return }
                let tok = ns.substring(with: m.range)
                // Preserve recognized unit/currency tokens — they get
                // consumed by the conversion / measurement passes upstream.
                if Self.units(tok) != nil { return }
                if currencyCodes.contains(tok.uppercased()) { return }
                if tok.lowercased() == "in" || tok.lowercased() == "to" || tok.lowercased() == "as" {
                    return
                }
                if let v = priorVars[tok]?.numericForReference {
                    replacements.append((m.range, formatNumberForSubstitution(v)))
                }
            }
            for (range, repl) in replacements.reversed() {
                out = (out as NSString).replacingCharacters(in: range, with: repl)
            }
        }
        return out
    }

    /// Format a double for re-injection into an expression. We deliberately
    /// avoid scientific notation, which NSExpression sometimes mishandles in
    /// edge cases involving negative numbers and locale grouping characters.
    private func formatNumberForSubstitution(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "0" }
        let s = String(format: "%.10f", v)
        // Strip trailing zeros / dangling dot.
        var t = s
        while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) {
            t.removeLast()
        }
        if t.isEmpty { return "0" }
        return v < 0 ? "(\(t))" : t
    }

    // -----------------------------------------------------------------
    // MARK: Currency
    // -----------------------------------------------------------------

    /// Parse "AMOUNT CCY (in|to|as) CCY" (CCY in either order around the
    /// keyword). Returns nil if the line doesn't look like a currency op.
    private func tryCurrencyConversion(_ expr: String) -> CalcValue? {
        // Build a regex like `(?i)([0-9., +\-*/()]+)\s*(USD|EUR|...)\s+(in|to|as)\s+(USD|EUR|...)`
        let codes = currencyCodes.sorted().joined(separator: "|")
        guard !codes.isEmpty else { return nil }
        let pattern = #"^\s*(.+?)\s+(\#(codes))\s+(?:in|to|as)\s+(\#(codes))\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }
        let ns = expr as NSString
        guard let m = re.firstMatch(in: expr, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4 else { return nil }
        let lhsExpr = ns.substring(with: m.range(at: 1))
        let from = ns.substring(with: m.range(at: 2)).uppercased()
        let to   = ns.substring(with: m.range(at: 3)).uppercased()
        guard case .success(let amount) = evaluateArithmetic(lhsExpr) else {
            return .error("can't parse amount")
        }
        guard let converted = rateStore.cache.convert(amount, from: from, to: to) else {
            return .error("unknown currency")
        }
        return .money(amount: converted, currency: to, stale: rateStore.ratesAreStale)
    }

    /// "100 USD" → money value (no conversion).
    private func tryStandaloneMoney(_ expr: String) -> CalcValue? {
        let codes = currencyCodes.sorted().joined(separator: "|")
        guard !codes.isEmpty else { return nil }
        let pattern = #"^\s*(.+?)\s+(\#(codes))\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }
        let ns = expr as NSString
        guard let m = re.firstMatch(in: expr, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3 else { return nil }
        let lhsExpr = ns.substring(with: m.range(at: 1))
        let ccy = ns.substring(with: m.range(at: 2)).uppercased()
        guard case .success(let amount) = evaluateArithmetic(lhsExpr) else { return nil }
        return .money(amount: amount, currency: ccy, stale: rateStore.ratesAreStale)
    }

    // -----------------------------------------------------------------
    // MARK: Units
    // -----------------------------------------------------------------

    private func tryUnitConversion(_ expr: String) -> CalcValue? {
        let aliases = Self.units.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        guard !aliases.isEmpty else { return nil }
        let pattern = #"^\s*(.+?)\s*(\#(aliases))\s+(?:in|to|as)\s+(\#(aliases))\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }
        let ns = expr as NSString
        guard let m = re.firstMatch(in: expr, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4 else { return nil }
        let lhsExpr  = ns.substring(with: m.range(at: 1))
        let fromAlias = ns.substring(with: m.range(at: 2))
        let toAlias   = ns.substring(with: m.range(at: 3))
        guard case .success(let amount) = evaluateArithmetic(lhsExpr) else {
            return .error("can't parse amount")
        }
        guard let entry = Self.units(fromAlias) else { return .error("unknown unit") }
        // red-team: reject non-finite inputs before Measurement so a 1e308 amount can't produce Inf on conversion to a smaller unit
        guard amount.isFinite else { return .error("not finite") }
        let m1 = entry.make(amount)
        guard let m2 = m1.convert(toAlias) else { return .error("incompatible units") }
        guard m2.value.isFinite else { return .error("overflow") }
        return .measurement(value: m2.value, unitSymbol: m2.symbol)
    }

    private func tryStandaloneMeasurement(_ expr: String) -> CalcValue? {
        let aliases = Self.units.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        guard !aliases.isEmpty else { return nil }
        let pattern = #"^\s*(.+?)\s*(\#(aliases))\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }
        let ns = expr as NSString
        guard let m = re.firstMatch(in: expr, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3 else { return nil }
        let lhsExpr = ns.substring(with: m.range(at: 1))
        let alias   = ns.substring(with: m.range(at: 2))
        guard case .success(let amount) = evaluateArithmetic(lhsExpr) else { return nil }
        guard let entry = Self.units(alias) else { return nil }
        return .measurement(value: amount, unitSymbol: entry.symbol)
    }

    // -----------------------------------------------------------------
    // MARK: Smart percent
    // -----------------------------------------------------------------

    /// Numi-style: `X + Y%` means `X * (1 + Y/100)`; `X - Y%` → `X * (1 - Y/100)`;
    /// `X * Y%` and `X / Y%` use the literal fractional value (`Y/100`).
    /// We do a regex-level rewrite — good enough for the common cases we
    /// expect in a tape. A full AST pass would be cleaner but overkill.
    private func expandSmartPercent(_ expr: String) -> String {
        var out = expr

        // X +/- Y%  → X * (1 +/- Y/100.0)
        // The `.0` forces float division — NSExpression does integer division
        // on `/` when both operands look like integers ("10/100" → 0, not 0.1).
        let addSubPattern = #"(\([^()]*\)|-?\d+(?:[.,]\d+)?)\s*([+\-])\s*(-?\d+(?:[.,]\d+)?)\s*%"#
        if let re = try? NSRegularExpression(pattern: addSubPattern) {
            while true {
                let ns = out as NSString
                guard let m = re.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges == 4 else { break }
                let lhs = ns.substring(with: m.range(at: 1))
                let op  = ns.substring(with: m.range(at: 2))
                let pct = ns.substring(with: m.range(at: 3))
                let repl = "(\(lhs) * (1.0 \(op) (\(pct))/100.0))"
                out = ns.replacingCharacters(in: m.range, with: repl)
            }
        }

        // Remaining standalone "Y%" becomes "(Y/100.0)".
        let bareRe = try? NSRegularExpression(pattern: #"(-?\d+(?:[.,]\d+)?)\s*%"#)
        if let re = bareRe {
            while true {
                let ns = out as NSString
                guard let m = re.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges == 2 else { break }
                let num = ns.substring(with: m.range(at: 1))
                out = ns.replacingCharacters(in: m.range, with: "(\(num)/100.0)")
            }
        }

        return out
    }

    // -----------------------------------------------------------------
    // MARK: Sanitized NSExpression
    // -----------------------------------------------------------------

    /// Whitelist of math functions we'll allow through to NSExpression.
    /// Anything else gets rejected — defense against side-channel function
    /// names that NSExpression sometimes accepts (FFI-style identifiers).
    private static let funcAllowlist: Set<String> = [
        "abs", "sqrt", "pow", "log", "ln", "exp", "floor", "ceil",
        "round", "min", "max", "sin", "cos", "tan", "asin", "acos", "atan"
    ]

    private enum ArithResult {
        case success(Double)
        case failure(String)
    }

    /// Sanitize then evaluate. We:
    ///   1. Normalize comma decimals to dot decimals (and grouping commas
    ///      → nothing) carefully — we don't want to turn "1,000" into
    ///      "1000" if the user is in a comma-decimal locale, and vice
    ///      versa, so we go by what makes the expression parse.
    ///   2. Reject any identifier that isn't in the function allowlist.
    ///   3. Hand off to NSExpression with `.numerOnly` style.
    /// Structural pre-validator — runs BEFORE NSExpression sees the string.
    /// NSExpression throws Objective-C exceptions on malformed inputs (unbalanced
    /// parens, trailing operators, empty parens, double decimals…) and Swift
    /// cannot catch ObjC exceptions natively, so we have to reject everything
    /// NSExpression's parser would choke on. This is the load-bearing guard
    /// against `NSExpression(format:)` SIGABRT.
    private func isLikelyValidArithmetic(_ s: String) -> Bool {
        var depth = 0
        var prevSig: Character = "("   // pretend we just opened — allows leading unary +/-
        var inNumber = false
        var sawDotInNumber = false
        var lastWasOperator = true     // start of string ≈ after-an-operator
        var lastWasParenOpen = false
        var lastWasParenClose = false  // red-team: track ")" so we can reject ")5" / ")(" juxtaposition
        var lastWasNumber = false      // red-team: track digit so we can reject "5 5" (adjacent operands)
        var lastWasLetter = false      // red-team: track letter so "func(" requires letter-then-paren; "5(" or ")(" rejected
        var sawWhitespaceSinceSig = false // red-team: detects operand juxtaposition across whitespace ("5 5", "x y")
        for c in s {
            if c.isWhitespace {
                // red-team: whitespace breaks number continuation so "5 5" reads as two distinct operands and fails the adjacency check
                if inNumber { inNumber = false }
                sawWhitespaceSinceSig = true
                continue
            }
            if c == "(" {
                // red-team: forbid "5(" and ")(" — NSExpression treats `x(` as function call and crashes when x isn't an identifier
                if lastWasNumber || lastWasParenClose { return false }
                depth += 1
                lastWasOperator = true
                lastWasParenOpen = true
                lastWasParenClose = false
                lastWasNumber = false
                lastWasLetter = false
                inNumber = false
                sawDotInNumber = false
                sawWhitespaceSinceSig = false
                prevSig = c
                continue
            }
            if c == ")" {
                depth -= 1
                if depth < 0 { return false }
                if lastWasParenOpen { return false }    // empty group "()"
                if lastWasOperator { return false }     // "(5+)"
                inNumber = false
                sawDotInNumber = false
                lastWasOperator = false
                lastWasParenOpen = false
                lastWasParenClose = true
                lastWasNumber = false
                lastWasLetter = false
                sawWhitespaceSinceSig = false
                prevSig = c
                continue
            }
            lastWasParenOpen = false
            if c.isLetter || c == "_" {
                // red-team: forbid "5x" and ")x" and "x y" — implicit-multiplication forms NSExpression chokes on
                if lastWasNumber || lastWasParenClose { return false }
                if lastWasLetter && sawWhitespaceSinceSig { return false }
                inNumber = false
                sawDotInNumber = false
                lastWasOperator = false
                lastWasParenClose = false
                lastWasNumber = false
                lastWasLetter = true
                sawWhitespaceSinceSig = false
                prevSig = c
                continue
            }
            if c.isNumber {
                // red-team: forbid "(5)5" — two operands with no operator between them blows NSExpression's parser
                if lastWasParenClose { return false }
                // red-team: forbid "5 5" — operand-whitespace-operand juxtaposition
                if lastWasNumber && sawWhitespaceSinceSig { return false }
                // red-team: forbid "func5" — letter immediately followed by digit produces a token NSExpression treats as one identifier
                if lastWasLetter { return false }
                inNumber = true
                lastWasOperator = false
                lastWasParenClose = false
                lastWasNumber = true
                lastWasLetter = false
                sawWhitespaceSinceSig = false
                prevSig = c
                continue
            }
            if c == "." {
                if !inNumber { return false }
                if sawDotInNumber { return false }
                sawDotInNumber = true
                lastWasOperator = false
                lastWasParenClose = false
                lastWasNumber = true   // red-team: "5." is still a number; next char must not be another digit-with-gap
                lastWasLetter = false
                sawWhitespaceSinceSig = false
                prevSig = c
                continue
            }
            // red-team: drop "^" from the allowed operator set — NSExpression interprets it as bitwise XOR on integer cast and raises NSInvalidArgumentException for fractional operands
            if "+-*/%".contains(c) {
                // Permit unary +/- only at the very start of the expression or
                // immediately after an opening paren — NOT after another operator.
                // NSExpression chokes on "1++2" / "1+-2" (it parses them as
                // "1+ +2" then raises NSInvalidArgumentException at evaluation).
                let atStartOrAfterOpenParen = prevSig == "("
                let unaryOK = (c == "+" || c == "-") && atStartOrAfterOpenParen
                if lastWasOperator && !unaryOK { return false }
                lastWasOperator = true
                lastWasParenClose = false
                lastWasNumber = false
                lastWasLetter = false
                inNumber = false
                sawDotInNumber = false
                sawWhitespaceSinceSig = false
                prevSig = c
                continue
            }
            return false  // unknown char — be conservative
        }
        if depth != 0 { return false }
        if lastWasOperator { return false }
        _ = prevSig  // silence unused warning
        return true
    }

    private func evaluateArithmetic(_ expr: String) -> ArithResult {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .failure("empty") }

        // Reject obviously dangerous characters.
        let forbidden: Set<Character> = [";", "\\", "\"", "$", "@", "{", "}", "[", "]"]
        if trimmed.contains(where: { forbidden.contains($0) }) {
            return .failure("invalid character")
        }

        // Structural validator — defends against NSExpression ObjC-exception SIGABRT.
        if !isLikelyValidArithmetic(trimmed) {
            return .failure("malformed expression")
        }

        // Identifier check.
        let idRe = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
        if let re = idRe {
            let ns = trimmed as NSString
            var ok = true
            re.enumerateMatches(in: trimmed, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                guard let m = m else { return }
                let tok = ns.substring(with: m.range).lowercased()
                if !Self.funcAllowlist.contains(tok) {
                    ok = false
                    stop.pointee = true
                }
            }
            if !ok { return .failure("unknown token") }
        }

        // Decimal-separator normalization. Try the raw input first; if
        // NSExpression chokes, try replacing commas with dots. This covers
        // both `1.5` and `1,5` written in any locale without false-
        // positives on grouping commas.
        let attempts: [String] = {
            var a = [trimmed]
            if trimmed.contains(",") && !trimmed.contains(".") {
                a.append(trimmed.replacingOccurrences(of: ",", with: "."))
            }
            return a
        }()

        for sanitized in attempts {
            // red-team: NSExpression performs integer division when BOTH
            // operands are integer literals — "10/4" returns 2, not 2.5.
            // Promote bare integer literals to floats by appending ".0" so
            // every numeric token is a Double from NSExpression's POV.
            let floatified = Self.promoteIntegerLiteralsToFloats(sanitized)
            // NSExpression's parser is the actual evaluator. Its API isn't
            // marked `throws` but it can raise an ObjC NSException on bad
            // input — guard with a do/catch shim by checking the format
            // up-front (we already did identifier validation above).
            let exp = NSExpression(format: floatified)
            if let n = exp.expressionValue(with: nil, context: nil) as? NSNumber {
                let d = n.doubleValue
                if d.isFinite { return .success(d) }
                return .failure("not finite")
            }
        }
        return .failure("parse error")
    }

    /// Replace every integer literal (a digit run that is NEITHER part of a
    /// decimal literal NOR adjacent to a decimal point) with the same digits
    /// + ".0". Pre-processing step so NSExpression's per-operand type
    /// inference treats them as Doubles. Defends against integer-division
    /// surprises like "10/4 → 2".
    fileprivate static func promoteIntegerLiteralsToFloats(_ s: String) -> String {
        // Lookbehind/lookahead exclude: another digit OR a dot. This skips
        // the integer parts of decimals ("3.14" stays "3.14"), already-
        // promoted floats ("1.0" stays "1.0"), and stray digit sequences
        // adjacent to other digits ("123" stays one integer, becomes "123.0").
        guard let re = try? NSRegularExpression(pattern: #"(?<![\d.])\d+(?![\d.])"#) else {
            return s
        }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = s
        for m in matches.reversed() {
            let token = (out as NSString).substring(with: m.range)
            out = (out as NSString).replacingCharacters(in: m.range, with: "\(token).0")
        }
        return out
    }

    // -----------------------------------------------------------------
    // MARK: Display formatting
    // -----------------------------------------------------------------

    /// Pretty-print a value. Locale-aware grouping; never falls back to
    /// scientific notation for typical magnitudes.
    func formatValue(_ v: CalcValue) -> String {
        switch v {
        case .empty:
            return ""
        case .error(let s):
            return s
        case .number(let n):
            return Self.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
        case .measurement(let v, let sym):
            let n = Self.numberFormatter.string(from: NSNumber(value: v)) ?? "\(v)"
            return "\(n) \(sym)"
        case .money(let v, let ccy, _):
            let f = Self.currencyFormatter(for: ccy)
            return f.string(from: NSNumber(value: v)) ?? "\(v) \(ccy)"
        case .assignment(let name, let inner):
            return "\(name) = \(formatValue(inner.v))"
        }
    }

    // red-team: was `static let` so it captured Locale.current at first use and
    // never updated on mid-session region change (US→DE comma decimal).
    // Now keyed off Formatters.epoch which AppDelegate bumps on
    // currentLocaleDidChangeNotification — the dictionary rebuilds lazily on
    // next render after a locale flip.
    private static var numberFormatterCache: (epoch: Int, fmt: NumberFormatter)? = nil
    private static var numberFormatter: NumberFormatter {
        if let c = numberFormatterCache, c.epoch == Formatters.epoch { return c.fmt }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        f.minimumFractionDigits = 0
        f.usesGroupingSeparator = true
        f.locale = Locale.autoupdatingCurrent
        numberFormatterCache = (Formatters.epoch, f)
        return f
    }

    private static func currencyFormatter(for code: String) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = 2
        // red-team: autoupdating so a region flip is reflected without app restart.
        f.locale = Locale.autoupdatingCurrent
        return f
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

@MainActor
final class CalcViewModel: ObservableObject {
    /// Single source of truth for the editor. We deliberately keep this as
    /// one big string rather than [String] — TextEditor binds naturally and
    /// undo/redo just works.
    @Published var source: String = CalcViewModel.starterTape
    @Published private(set) var results: [CalcLineResult] = []

    private let evaluator = CalcEvaluator()
    private var debounceWork: DispatchWorkItem?
    private var sub: AnyCancellable?

    /// Default tape shown on first launch — also serves as a live demo of
    /// every supported feature without needing a help page.
    static let starterTape = """
    # Welcome to Calc — Soulver-style smart tape.
    # Each line evaluates independently. Reference earlier lines as line1, line2…
    100 + 50
    line1 * 2
    tax = 9.75%
    120 * (1 + tax)
    50 + 10%
    100 USD in EUR
    5 mi to km
    180 lbs in kg
    """

    init() {
        // Initial evaluation
        recompute()
        // Re-evaluate when source changes — debounced 120ms so a 1000-line
        // tape doesn't recompute on every keystroke.
        sub = $source
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRecompute() }
    }

    private func scheduleRecompute() {
        debounceWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.recompute() }
        debounceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func recompute() {
        results = evaluator.evaluate(text: source)
    }

    /// Clear all lines back to a single blank line.
    func clear() { source = "" }

    /// Build a Markdown tape block. Used by the "Send to Stage" toolbar
    /// button. Format: `| line | expression | result |`.
    func tapeAsMarkdown() -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rows: [String] = []
        rows.append("| # | Expression | Result |")
        rows.append("|---|------------|--------|")
        for (i, line) in lines.enumerated() {
            guard i < results.count else { break }
            let r = results[i]
            let expr = line.replacingOccurrences(of: "|", with: "\\|")
            let res = r.errorText ?? r.display
            // Skip fully-blank rows so the markdown doesn't look ragged.
            if expr.trimmingCharacters(in: .whitespaces).isEmpty && res.isEmpty { continue }
            rows.append("| \(i+1) | \(expr) | \(res) |")
        }
        return rows.joined(separator: "\n")
    }

    /// Build a plain-text transcript: `<expression> = <result>` per line.
    /// Used by Save As… / Save to Downloads so the on-disk file reads naturally
    /// outside of any Markdown renderer. Skips fully-blank rows.
    func tapeAsPlainText() -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let expr = line.trimmingCharacters(in: .whitespaces)
            if i >= results.count {
                if !expr.isEmpty { out.append(expr) }
                continue
            }
            let r = results[i]
            let res = r.errorText ?? r.display
            if expr.isEmpty && res.isEmpty { continue }
            if res.isEmpty {
                out.append(expr)
            } else if expr.isEmpty {
                out.append("= \(res)")
            } else {
                out.append("\(expr) = \(res)")
            }
        }
        return out.joined(separator: "\n")
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct CalcView: View {
    @StateObject private var vm = CalcViewModel()
    @StateObject private var rates = CalcRateStore.shared
    @EnvironmentObject var stage: Stage

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // ----------------------------------------------------- LEFT pane
            ZStack(alignment: .topLeading) {
                CalcEditor(text: $vm.source)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                if vm.source.isEmpty {
                    // red-team: previous copy was a one-liner that listed categories
                    // ("math, units, currency…") without showing what a real entry
                    // looks like. New copy is a 3-line worked example so a first-
                    // time user knows to type expressions, reference prior lines as
                    // `line1`/`line2`, and convert with "in"/"to".
                    Text("""
                    Try entering, one per line:
                      120 * 1.0975
                      line1 in EUR
                      5 mi to km
                    """)
                        .foregroundStyle(.tertiary)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Empty calculator. Type expressions one per line. Reference earlier lines as line1, line2. Convert with in or to.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // ---------------------------------------------------- RIGHT pane
            // The results column is also a drag source — drag it into Finder
            // (or any app accepting file drops) to export the whole transcript
            // as a .txt file. Provider materializes the file on-demand.
            CalcResultsColumn(results: vm.results, transcript: { vm.tapeAsPlainText() })
                .frame(width: 220)
        }
        .navigationTitle("Calc")
        .navigationSubtitle(subtitle)
        .toolbar { calcToolbar() }
    }

    private var subtitle: String {
        let nonEmpty = vm.results.filter { !$0.display.isEmpty && !$0.value.isError }
        if rates.fetching {
            return "Fetching exchange rates…"
        }
        if vm.results.contains(where: { $0.value.isStale }) {
            return "\(nonEmpty.count) result\(nonEmpty.count == 1 ? "" : "s") · rates stale"
        }
        return "\(nonEmpty.count) result\(nonEmpty.count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder
    private func calcToolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                rates.refreshOnce()
            } label: {
                Label("Refresh rates", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(rates.fetching)
            .help("Re-fetch exchange rates from the ECB (one attempt, no retry)")

            // Save As… — primary save affordance. Writes the entire transcript
            // (expression = result per line) as a .txt to a user-chosen path.
            Button {
                Self.saveCalcTranscript(vm.tapeAsPlainText())
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .disabled(vm.source.isEmpty)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save the full transcript as a .txt file (⌘S).")

            // More ▼ — quick saves and Stage handoff.
            Menu {
                Button {
                    Self.quickSaveCalcTranscriptToDownloads(vm.tapeAsPlainText())
                } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("d", modifiers: [.command])
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(vm.tapeAsPlainText(), forType: .string)
                    stage.flash("Copied transcript")
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button {
                    let md = vm.tapeAsMarkdown()
                    stage.addText(md)
                    stage.flash("Sent tape to Stage")
                } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .disabled(vm.source.isEmpty)
            .help("More actions")

            Button(role: .destructive) {
                vm.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(vm.source.isEmpty)
            // red-team: external `text = ""` bypasses NSTextView's undo manager,
            // so ⌘Z won't bring the tape back. Surface that in the tooltip so a
            // user with a long tape doesn't lose it to one accidental click.
            .help("Clear the entire tape. This is NOT undoable — consider Send to Stage first if you want to keep it.")
        }
    }

    // -----------------------------------------------------------------------
    // Save helpers — statics so closures don't capture self.
    // -----------------------------------------------------------------------

    /// Save As… with NSSavePanel. Default `.txt`, name pre-filled with
    /// `Calculator transcript YYYY-MM-DD.txt`. Remembers last-used directory.
    fileprivate static func saveCalcTranscript(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "Calculator transcript \(dateForFilename()).txt"
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                try text.write(to: dest, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved transcript to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    fileprivate static func quickSaveCalcTranscriptToDownloads(_ text: String) {
        guard let downloads = downloadsDir() else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let name = "Calculator transcript \(dateForFilename()).txt"
        let dest = collisionFreeURL(in: downloads, name: name)
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved transcript to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    /// NSItemProvider that materializes a .txt on-demand for drag-to-Finder.
    /// Used by the results-column drag handle so users can drag the whole
    /// transcript out as a file.
    fileprivate static func makeTranscriptItemProvider(_ text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let filename = "Calculator transcript.txt"
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

    private static let kSaveDirKey = "calc.saveDir.last"

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

    /// "2026-05-13" — local date, sortable, filename-safe.
    fileprivate static func dateForFilename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// ---------------------------------------------------------------------------
// MARK: - Editor (NSTextView-backed for fixed line height + alignment)
// ---------------------------------------------------------------------------

/// A monospaced multi-line editor. We use a custom NSTextView wrapper rather
/// than SwiftUI `TextEditor` so we can (a) lock the line height and (b)
/// align rows pixel-perfectly with the results column on the right. SwiftUI's
/// TextEditor doesn't expose enough knobs for that.
struct CalcEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // Hardest-standards rule: if a future macOS change altered the
        // contract of `scrollableTextView()`, we degrade to an empty scroll
        // view rather than aborting the whole app. `assertionFailure` flags
        // in dev, NSLog logs in release; the Calc pane renders empty (which
        // is debuggable) instead of crashing the entire window on launch.
        guard let tv = scroll.documentView as? NSTextView else {
            NSLog("CalcEditor: scrollableTextView() returned unexpected documentView type — returning empty scroll view")
            assertionFailure("CalcEditor: documentView is not NSTextView")
            return scroll
        }
        tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.delegate = context.coordinator
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            // Preserve cursor when possible — replacing the whole string
            // would otherwise jump it to position 0 on every external set.
            let sel = tv.selectedRange()
            tv.string = text
            let safe = NSRange(location: min(sel.location, (text as NSString).length),
                               length: 0)
            tv.setSelectedRange(safe)
        }
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, NSTextViewDelegate {
        var parent: CalcEditor
        init(_ p: CalcEditor) { self.parent = p }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Results column
// ---------------------------------------------------------------------------

/// Right-pane parallel column. Each row is keyed by line index so SwiftUI
/// can reuse the row views as lines are added/removed. Lazy by virtue of
/// `List` rendering only what's visible.
struct CalcResultsColumn: View {
    let results: [CalcLineResult]
    /// Closure that yields the latest plain-text transcript at drag time.
    /// Stored as a closure (not the string) so the dragged payload always
    /// reflects what's currently in the tape, not a stale snapshot.
    var transcript: () -> String = { "" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .trailing, spacing: 0) {
                ForEach(results) { r in
                    CalcResultRow(result: r)
                        .id(r.id)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
        }
        // Drag the whole results column to export the transcript as a file.
        // We gate on non-empty transcript so empty drags don't pollute /tmp.
        .onDrag {
            let text = transcript()
            guard !text.isEmpty else { return NSItemProvider() }
            return CalcView.makeTranscriptItemProvider(text)
        }
        .contextMenu {
            Button {
                CalcView.saveCalcTranscript(transcript())
            } label: { Label("Save…", systemImage: "square.and.arrow.down") }
            Button {
                CalcView.quickSaveCalcTranscriptToDownloads(transcript())
            } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(transcript(), forType: .string)
                SharedStore.stage.flash("Copied transcript")
            } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
            Button {
                SharedStore.stage.addText(transcript())
                SharedStore.stage.flash("Sent tape to Stage")
            } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
        }
    }
}

struct CalcResultRow: View {
    let result: CalcLineResult

    var body: some View {
        HStack(spacing: 6) {
            // Hint / shadow / stale badges sit to the left of the number.
            if let hint = result.shadowedHint {
                badge("shadowed: \(hint)", color: .orange)
            }
            if result.value.isStale {
                badge("stale", color: .yellow)
            }
            if let err = result.errorText {
                badge(err, color: .red)
            }
            Spacer(minLength: 0)
            Text(result.display)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.display)
        }
        .frame(height: lineHeight)
        .contentShape(Rectangle())
        .contextMenu { rowMenu }
    }

    private var textColor: Color {
        if result.errorText != nil { return .secondary }
        if result.display.isEmpty   { return .secondary }
        return .primary
    }

    /// Match the editor's line height so rows align across the divider.
    /// 14pt monospaced ≈ ~17pt total leading.
    private var lineHeight: CGFloat { 19 }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder private var rowMenu: some View {
        if !result.display.isEmpty {
            Button("Copy result") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.display, forType: .string)
            }
            // Per-line "= result" snippet — paste-ready for docs / messages.
            Button("Copy line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("= \(result.display)", forType: .string)
            }
        }
    }
}

#if TROVE_TESTING
// Test-only re-exports so unit tests can poke at private normalizers without
// loosening their access level for production callers.
extension CalcEvaluator {
    func _t_normalizeOperators(_ s: String) -> String { normalizeOperators(s) }
    func _t_normalizeCurrencyTokens(_ s: String) -> String { normalizeCurrencyTokens(s) }
    func _t_normalizeNaturalLanguage(_ s: String) -> String { normalizeNaturalLanguage(s) }
    func _t_expandSmartPercent(_ s: String) -> String { expandSmartPercent(s) }
    func _t_isLikelyValidArithmetic(_ s: String) -> Bool { isLikelyValidArithmetic(s) }
}
#endif
