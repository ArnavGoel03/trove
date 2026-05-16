// Trove — Log pane (friendly wrapper around `log show` / `log stream`).
//   • Filter row: time-range, level, subsystem, process, message-contains.
//   • Mode picker: Fetch (paged 500/page) vs Stream (live tail, FIFO cap 5000).
//   • Six baked-in presets for common diagnostic queries (crashes, network, …).
//   • Color-coded results by level; expand-on-click for full message + meta.
//   • "Send to Stage" pipes the visible rows out as text into SharedStore.stage.
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Foundation
import Darwin   // SIGTERM
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Model
// ===========================================================================

/// Mirrors the `messageType` numeric values that `/usr/bin/log` emits in
/// `--style ndjson`. We map them to a friendly enum so the UI doesn't leak
/// magic numbers.
///
/// Reference (from `man log`): default=0, info=1, debug=2, error=16, fault=17.
enum LogLevel: Int, CaseIterable, Hashable, Identifiable {
    case `default` = 0
    case info      = 1
    case debug     = 2
    case error     = 16
    case fault     = 17

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .default: return "Default"
        case .info:    return "Info"
        case .debug:   return "Debug"
        case .error:   return "Error"
        case .fault:   return "Fault"
        }
    }

    var tint: Color {
        switch self {
        case .fault:   return .red
        case .error:   return .orange
        case .info:    return .blue
        case .debug:   return .secondary
        case .default: return .primary.opacity(0.7)
        }
    }

    /// String the `log` CLI uses when classifying a row (its `messageType`
    /// field is sometimes a number, sometimes a word — observed in the wild
    /// on 13.x vs 14.x). We accept both.
    static func parse(_ raw: Any?) -> LogLevel {
        if let n = raw as? Int, let lv = LogLevel(rawValue: n) { return lv }
        if let s = raw as? String {
            switch s.lowercased() {
            case "default":          return .default
            case "info":             return .info
            case "debug":            return .debug
            case "error":            return .error
            case "fault":            return .fault
            default: break
            }
            if let n = Int(s), let lv = LogLevel(rawValue: n) { return lv }
        }
        return .default
    }
}

/// One row parsed from a single NDJSON line emitted by `log`.
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let process: String
    let pid: Int
    let subsystem: String
    let category: String
    let message: String

    /// One-line collapsed form used in the table.
    var oneLine: String {
        message.replacingOccurrences(of: "\n", with: " ")
    }

    /// Format for "Send to Stage" / clipboard copy.
    func plainText() -> String {
        let ts = LogFormatters.full.string(from: timestamp)
        let proc = pid > 0 ? "\(process)[\(pid)]" : process
        var meta: [String] = []
        if !subsystem.isEmpty { meta.append(subsystem) }
        if !category.isEmpty  { meta.append(category)  }
        let metaStr = meta.isEmpty ? "" : " (\(meta.joined(separator: "/")))"
        return "\(ts) \(level.label.uppercased()) \(proc)\(metaStr): \(message)"
    }
}

enum LogFormatters {
    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let hms: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// ===========================================================================
// MARK: - Time range
// ===========================================================================

enum LogTimeRange: String, CaseIterable, Identifiable, Hashable {
    case m5     = "Last 5m"
    case h1     = "Last 1h"
    case h24    = "Last 24h"
    case custom = "Custom"

    var id: String { rawValue }

    /// What we pass to `log show --last`. `nil` means use --start/--end instead.
    var lastFlag: String? {
        switch self {
        case .m5:     return "5m"
        case .h1:     return "1h"
        case .h24:    return "24h"
        case .custom: return nil
        }
    }
}

// ===========================================================================
// MARK: - Predicate builder (input validated; passed via argv, never concatenated)
// ===========================================================================

enum LogPredicate {

    /// Bracket-balance + escape sanity for a user-typed predicate fragment.
    /// We *don't* try to parse NSPredicate grammar — only reject inputs that
    /// would obviously corrupt our generated string (unbalanced quotes,
    /// embedded backslashes that could escape our wrapping quotes).
    ///
    /// `strict=true` additionally rejects boolean-operator injection (AND/OR
    /// at the top level) — for the structured `subsystem` and `process`
    /// fields where such tokens have no business. The free-text "contains"
    /// field uses `strict=false` since the user's input is wrapped in quotes
    /// and matched via `CONTAINS[c]`, where embedded `AND`/`OR` are just text.
    ///
    /// Returns the cleaned string, or `nil` if the input is too sketchy.
    // red-team-sec #1: previously only rejected `"` and `\`. Smart quotes
    // (U+201C/D, U+2018/9), CR/LF/NEL/LS/PS, NUL, and other control chars
    // could all sneak past and either inject predicate clauses (newline +
    // `OR 1=1`) or terminate the literal early (smart quotes are *displayed*
    // as quotes but treated as text by NSPredicate — defensive however).
    // red-team-sec #1c: also length-cap the input. NSPredicate parsing of a
    // 50k-char string is O(n) but a 50 MB paste from clipboard would hang
    // the predicate compiler and the UI alike. 4 KB is comfortably above any
    // legitimate subsystem/process/contains value.
    static func sanitize(_ raw: String, strict: Bool = true) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.utf8.count > 4096 { return nil }
        // Bracket balance — paren and quote pairs.
        var paren = 0
        var dquote = 0
        for ch in s {
            switch ch {
            case "(": paren += 1
            case ")": paren -= 1; if paren < 0 { return nil }
            case "\"": dquote += 1
            default: break
            }
        }
        if paren != 0 || dquote % 2 != 0 { return nil }
        // Free-text "contains" gets wrapped in quotes; embedded `"` or `\` would
        // close our literal early. Reject those in every mode.
        if s.contains("\"") { return nil }
        if s.contains("\\") { return nil }
        // red-team-sec #1: reject any control char (incl. NUL, LF, CR, NEL,
        // LS, PS, vertical tab, etc.) and curly/smart quotes that look like
        // `"` to a user but aren't caught by the ASCII check above.
        for sc in s.unicodeScalars {
            // Control chars: C0 (0x00-0x1F), DEL (0x7F), C1 (0x80-0x9F).
            if sc.value < 0x20 || sc.value == 0x7F || (sc.value >= 0x80 && sc.value <= 0x9F) {
                return nil
            }
            // Unicode line/paragraph separators.
            if sc.value == 0x2028 || sc.value == 0x2029 { return nil }
            // Smart quotes — coerce-to-ASCII would let them through; cheaper
            // to refuse outright than to normalize.
            switch sc.value {
            case 0x201C, 0x201D, 0x201E, 0x201F,    // “ ” „ ‟
                 0x2018, 0x2019, 0x201A, 0x201B,    // ‘ ’ ‚ ‛
                 0x00AB, 0x00BB,                     // « »
                 0x2039, 0x203A:                     // ‹ ›
                return nil
            default: break
            }
        }
        if strict {
            // Reject explicit boolean-operator injection — our builder owns AND/OR.
            let lower = s.lowercased()
            if lower.contains("&&") || lower.contains("||") { return nil }
            if lower.range(of: #"\b(and|or|not)\b"#, options: .regularExpression) != nil { return nil }
        }
        return s
    }

    /// Escape a value to be embedded inside a double-quoted NSPredicate literal.
    /// After `sanitize` we know there are no `"` or `\\` in `v`, but defense in depth.
    private static func quoted(_ v: String) -> String {
        let escaped = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Build the NSPredicate string `log` expects. Returns `nil` if any of
    /// the user fields fail validation (caller surfaces a flash).
    /// Note: each clause is ANDed; level filter is built from the picker, so
    /// it bypasses sanitize. `extraLevelClause` lets the caller inject a
    /// non-equality match (e.g. `messageType >= 16` for Errors + Faults).
    static func build(level: LogLevel?,
                      extraLevelClause: String? = nil,
                      subsystem: String,
                      process: String,
                      contains: String) -> String? {
        var clauses: [String] = []

        if let lvl = level {
            clauses.append("messageType == \(lvl.rawValue)")
        } else if let extra = extraLevelClause {
            clauses.append(extra)
        }

        guard let subC = sanitize(subsystem) else { return nil }
        if !subC.isEmpty {
            clauses.append("subsystem == \(quoted(subC))")
        }
        guard let procC = sanitize(process) else { return nil }
        if !procC.isEmpty {
            // ENDSWITH so the user can type "Trove" rather than the full
            // /Applications/Trove.app/Contents/MacOS/Trove path.
            clauses.append("processImagePath ENDSWITH[c] \(quoted("/\(procC)"))")
        }
        guard let msgC = sanitize(contains, strict: false) else { return nil }
        if !msgC.isEmpty {
            clauses.append("eventMessage CONTAINS[c] \(quoted(msgC))")
        }

        if clauses.isEmpty { return "" }
        return clauses.joined(separator: " AND ")
    }

    /// red-team #5: a "filter" that's just an `extraLevelClause` like
    /// `messageType > 0` (or no clauses at all) would fetch gigabytes on a
    /// busy machine in stream mode. Caller checks this before launching to
    /// give the user a clear "add a real filter" message.
    static func isTrivial(predicate: String,
                          level: LogLevel?,
                          subsystem: String,
                          process: String,
                          contains: String) -> Bool {
        let hasField = !subsystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !process.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !contains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasField { return false }
        if level != nil { return false }   // single concrete level is OK
        // No specific level, no fields → trivial unless we have the
        // errors-and-faults extra clause (which IS tight enough to allow).
        if predicate == "messageType >= 16" { return false }
        return true
    }
}

// ===========================================================================
// MARK: - Presets
// ===========================================================================

struct LogPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let blurb: String
    let level: LogLevelChoice
    let subsystem: String
    let process: String
    let contains: String

    static let all: [LogPreset] = [
        LogPreset(id: "faults", title: "Crashes & faults",
                  icon: "exclamationmark.octagon.fill",
                  blurb: "Errors + faults across the system",
                  level: .errorsAndFaults, subsystem: "", process: "", contains: ""),
        LogPreset(id: "network", title: "Network",
                  icon: "network",
                  blurb: "com.apple.network",
                  level: .all, subsystem: "com.apple.network", process: "", contains: ""),
        LogPreset(id: "kernel", title: "Kernel",
                  icon: "cpu",
                  blurb: "com.apple.kernel",
                  level: .all, subsystem: "com.apple.kernel", process: "", contains: ""),
        LogPreset(id: "power", title: "Power",
                  icon: "battery.100.bolt",
                  blurb: "IOPMrootDomain — sleep/wake",
                  level: .all, subsystem: "com.apple.iokit.IOPMrootDomain", process: "", contains: ""),
        LogPreset(id: "display", title: "Display / WindowServer",
                  icon: "display",
                  blurb: "com.apple.windowserver",
                  level: .all, subsystem: "com.apple.windowserver", process: "", contains: ""),
        LogPreset(id: "self", title: "Trove itself",
                  icon: "wrench.and.screwdriver.fill",
                  blurb: "process Trove",
                  level: .all, subsystem: "", process: "Trove", contains: ""),
    ]
}

// ===========================================================================
// MARK: - Runner
// ===========================================================================

/// Drives `/usr/bin/log` in both one-shot (`show`) and live (`stream`) modes.
/// All published state is mutated on the main queue (we route through
/// `DispatchQueue.main.async` explicitly rather than relying on `@MainActor`,
/// to match the dispatch style used elsewhere in Trove).
final class LogRunner: ObservableObject {

    @Published var entries: [LogEntry] = []
    @Published var isRunning: Bool = false
    @Published var status: String = "Idle"
    @Published var errorText: String? = nil
    @Published var skipped: Int = 0     // NDJSON parse failures, surfaced as count

    // red-team: cap at 5000 to keep RAM bounded. In stream mode we FIFO-evict.
    static let maxEntries = 5000

    /// red-team #2/#3: per-line size cap. A single 50 MB NDJSON line would
    /// OOM both `String(data:encoding:)` and `JSONSerialization`. We refuse
    /// any line longer than this and surface it as a skipped count.
    static let maxLineBytes = 1 * 1024 * 1024     // 1 MB
    /// Hard cap on the streaming leftover buffer. If a malformed source
    /// stops emitting newlines we'd grow forever; instead we drop the buffer
    /// and resync at the next newline.
    static let maxStreamBufferBytes = 4 * 1024 * 1024  // 4 MB

    /// Buffered tail of partial NDJSON line in stream mode.
    private var streamLeftover: Data = Data()

    /// red-team #4: wallclock of last successful stream-row arrival. If a
    /// gap >30 s opens up, surface "stream paused while system slept" hint.
    /// Polled by a Timer set up alongside the stream process.
    private var lastStreamRowAt: Date?
    private var streamGapTimer: Timer?
    private var didReportStreamGap: Bool = false
    static let streamGapThreshold: TimeInterval = 30

    /// Currently running process (stream OR show). Single source of truth so
    /// `stop()` always tears down exactly one thing.
    private var proc: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stderrDrainQ = DispatchQueue(label: "trove.log.stderr")
    private var stderrBox = LogDrainBox()

    deinit {
        // Can't await main actor here; just signal the process if any.
        if let p = proc, p.isRunning { p.terminate() }
        // red-team #2: also drop readability handlers + invalidate the gap
        // timer. `tearDownProcess()` is @MainActor-isolated in spirit but the
        // operations here (setting handlers to nil, invalidating a Timer)
        // are safe to call off-main and the worst case is a no-op since
        // `proc` is already terminated above. Without this, the dispatch
        // queue managing the readability handler could keep `self` alive
        // long enough to outlive the deinit's caller frame.
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        streamGapTimer?.invalidate()
    }

    // ---------- Common process plumbing ----------

    /// Build argv for `/usr/bin/log show` or `log stream`. Predicate goes via
    /// argv (`--predicate <p>`) — never string-interpolated into the command.
    private func buildArgs(mode: LogMode,
                           timeRange: LogTimeRange,
                           startDate: Date,
                           endDate: Date,
                           includeInfoDebug: Bool,
                           predicate: String) -> [String] {
        var a: [String] = [mode == .stream ? "stream" : "show"]
        a.append("--style"); a.append("ndjson")

        if mode == .show {
            if let last = timeRange.lastFlag {
                a.append("--last"); a.append(last)
            } else {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                a.append("--start"); a.append(f.string(from: startDate))
                a.append("--end");   a.append(f.string(from: endDate))
            }
        }

        // red-team #1: --info / --debug make `log show --last 24h` produce
        // hundreds of MB on busy machines. We only opt in on demand.
        if includeInfoDebug {
            a.append("--info")
            if mode == .show { a.append("--debug") }
        }

        if !predicate.isEmpty {
            a.append("--predicate"); a.append(predicate)
        }
        return a
    }

    // ---------- Fetch (one-shot) ----------

    func fetch(timeRange: LogTimeRange,
               startDate: Date,
               endDate: Date,
               level: LogLevel?,
               extraLevelClause: String? = nil,
               subsystem: String,
               process: String,
               contains: String,
               includeInfoDebug: Bool,
               maxLines: Int = 5000) {
        stop()
        errorText = nil
        skipped = 0
        // red-team #5b: custom-range guard. The `.h24` trivial-filter check
        // catches the most common foot-gun, but a `.custom` range spanning
        // a week with no real filter would be far worse. Refuse any custom
        // window > 6h that has a trivial filter, and refuse end < start
        // (would make `log show --start ... --end ...` return nothing or
        // error — better to tell the user up front).
        if timeRange == .custom {
            if endDate <= startDate {
                errorText = "End date must be after start date."
                status = "Idle"
                return
            }
        }
        guard let predicate = LogPredicate.build(level: level,
                                                 extraLevelClause: extraLevelClause,
                                                 subsystem: subsystem,
                                                 process: process,
                                                 contains: contains) else {
            errorText = "Invalid filter — check for stray quotes or operators."
            status = "Idle"
            return
        }
        // red-team #5: an unfiltered fetch over 24h would also be massive.
        if timeRange == .h24 && LogPredicate.isTrivial(predicate: predicate,
                                                       level: level,
                                                       subsystem: subsystem,
                                                       process: process,
                                                       contains: contains) {
            errorText = "Add a subsystem, process, message-contains, or specific level before fetching 24h — an empty filter could pull gigabytes."
            status = "Idle"
            return
        }
        // red-team #5b: also gate custom ranges wider than 6 hours.
        if timeRange == .custom,
           endDate.timeIntervalSince(startDate) > 6 * 3600,
           LogPredicate.isTrivial(predicate: predicate,
                                  level: level,
                                  subsystem: subsystem,
                                  process: process,
                                  contains: contains) {
            errorText = "Add a subsystem, process, message-contains, or specific level before fetching a >6h custom range — an empty filter could pull gigabytes."
            status = "Idle"
            return
        }

        let args = buildArgs(mode: .show,
                             timeRange: timeRange,
                             startDate: startDate,
                             endDate: endDate,
                             includeInfoDebug: includeInfoDebug,
                             predicate: predicate)

        isRunning = true
        status = "Fetching…"
        entries = []

        // red-team-sec: switch from `launchPath` (deprecated; consults PATH
        // when the binary is missing) to `executableURL` so we always launch
        // exactly `/usr/bin/log` and never a shadowed binary earlier on a
        // wonky PATH. Belt-and-suspenders — predicate goes via argv, so this
        // isn't an injection vector, but the deprecation warning + the
        // PATH-search fallback are both worth eliminating.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            isRunning = false
            status = "Idle"
            errorText = "Failed to launch /usr/bin/log: \(error.localizedDescription)"
            return
        }
        self.proc = p

        // red-team #6: drain stderr concurrently so the pipe never deadlocks.
        let errBox = self.stderrBox
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        stderrDrainQ.async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        // Drain stdout off-thread, then bounce parsed entries to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExitOffMain()
            drainGroup.wait()
            let (parsed, skipped) = LogRunner.parseNDJSON(data, max: maxLines)
            let code = p.terminationStatus
            let errBytes = errBox.data
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.entries = parsed
                self.skipped = skipped
                self.isRunning = false
                self.proc = nil
                if code != 0 {
                    let stderr = String(data: errBytes, encoding: .utf8) ?? ""
                    let head = stderr.split(separator: "\n").first.map(String.init) ?? "exit \(code)"
                    self.errorText = "log exited \(code): \(head)"
                    self.status = "Idle"
                } else {
                    let trimmed = parsed.count >= maxLines ? " (capped at \(maxLines))" : ""
                    self.status = "Fetched \(parsed.count) row\(parsed.count == 1 ? "" : "s")\(trimmed)"
                }
            }
        }
    }

    // ---------- Stream (live tail) ----------

    func stream(level: LogLevel?,
                extraLevelClause: String? = nil,
                subsystem: String,
                process: String,
                contains: String,
                includeInfoDebug: Bool) {
        stop()
        errorText = nil
        skipped = 0
        guard let predicate = LogPredicate.build(level: level,
                                                 extraLevelClause: extraLevelClause,
                                                 subsystem: subsystem,
                                                 process: process,
                                                 contains: contains) else {
            errorText = "Invalid filter — check for stray quotes or operators."
            return
        }
        // red-team #5: refuse a vacuous filter in stream mode — it would
        // pump every log line on the system through the pipe.
        if LogPredicate.isTrivial(predicate: predicate,
                                  level: level,
                                  subsystem: subsystem,
                                  process: process,
                                  contains: contains) {
            errorText = "Add a subsystem, process, message-contains, or specific level before streaming — an empty filter would tail the entire system log."
            return
        }

        let args = buildArgs(mode: .stream,
                             timeRange: .m5, // ignored in stream
                             startDate: Date(),
                             endDate: Date(),
                             includeInfoDebug: includeInfoDebug,
                             predicate: predicate)

        entries = []
        streamLeftover = Data()
        isRunning = true
        status = "Streaming…"

        // red-team-sec: see fetch() — executableURL instead of launchPath.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outFH = outPipe.fileHandleForReading
        let errFH = errPipe.fileHandleForReading
        self.stdoutHandle = outFH
        self.stderrHandle = errFH

        // red-team #6 again: stderr drained on its own queue. We also keep the
        // handle so `stop()` can null its readability handler.
        errFH.readabilityHandler = { [weak self] h in
            // Drop bytes; we surface the first stderr line only on a fatal exit.
            let d = h.availableData
            if d.isEmpty { return }
            self?.stderrDrainQ.async {
                self?.stderrBox.data.append(d)
            }
        }

        outFH.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return } // EOF; termination handled below.
            // Buffer + line-split on the thread we're called on, then hop to main.
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.streamLeftover.append(d)
                // red-team #3: bound the leftover buffer. If a remote source
                // stops emitting `\n` we won't grow without bound.
                if self.streamLeftover.count > LogRunner.maxStreamBufferBytes {
                    // Scan for the LAST newline and discard everything before
                    // it (best-effort resync); if none, blow the buffer away.
                    if let nlIdx = self.streamLeftover.lastIndex(of: 0x0A) {
                        let next = self.streamLeftover.index(after: nlIdx)
                        self.streamLeftover.removeSubrange(self.streamLeftover.startIndex..<next)
                    } else {
                        self.streamLeftover.removeAll(keepingCapacity: false)
                    }
                    self.skipped += 1
                }
                let (rows, leftover, skipped) = LogRunner.parseNDJSONStreaming(self.streamLeftover)
                self.streamLeftover = leftover
                if !rows.isEmpty {
                    self.entries.append(contentsOf: rows)
                    self.lastStreamRowAt = Date()
                    if self.didReportStreamGap {
                        // Clearing on resume; the gap UI will fade with status.
                        self.didReportStreamGap = false
                        self.status = "Streaming…"
                    }
                    // FIFO eviction once we cross the cap.
                    if self.entries.count > LogRunner.maxEntries {
                        self.entries.removeFirst(self.entries.count - LogRunner.maxEntries)
                    }
                }
                if skipped > 0 { self.skipped += skipped }
            }
        }

        // red-team #4: poll for sleep/wake gaps. We don't subscribe to
        // NSWorkspace willSleep because `log stream` doesn't always die on
        // sleep — sometimes it just pauses. The wallclock-gap heuristic is
        // simpler and catches both cases.
        lastStreamRowAt = Date()
        didReportStreamGap = false
        streamGapTimer?.invalidate()
        streamGapTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isRunning, let last = self.lastStreamRowAt else { return }
            let gap = Date().timeIntervalSince(last)
            if gap > LogRunner.streamGapThreshold && !self.didReportStreamGap {
                self.didReportStreamGap = true
                self.status = "Stream paused (no rows for \(Int(gap))s — likely sleep/wake)"
            }
        }

        p.terminationHandler = { [weak self] term in
            // Snapshot stderr through its own queue to avoid racing the
            // readability handler still flushing bytes.
            let snapshot: Data = {
                guard let self = self else { return Data() }
                var out = Data()
                self.stderrDrainQ.sync { out = self.stderrBox.data }
                return out
            }()
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Only flip to idle if we were the active process — defends
                // against late callbacks after a new run was launched.
                if self.proc === term {
                    self.tearDownProcess()
                    if term.terminationStatus != 0 && term.terminationStatus != SIGTERM {
                        let s = String(data: snapshot, encoding: .utf8) ?? ""
                        let head = s.split(separator: "\n").first.map(String.init) ?? "exit \(term.terminationStatus)"
                        self.errorText = "log stream ended: \(head)"
                    }
                    self.status = "Idle"
                    self.isRunning = false
                }
            }
        }

        do {
            try p.run()
            self.proc = p
        } catch {
            errorText = "Failed to launch /usr/bin/log stream: \(error.localizedDescription)"
            isRunning = false
            status = "Idle"
        }
    }

    func stop() {
        if let p = proc, p.isRunning {
            p.terminate()
        }
        tearDownProcess()
        streamGapTimer?.invalidate()
        streamGapTimer = nil
        lastStreamRowAt = nil
        didReportStreamGap = false
        if isRunning {
            isRunning = false
            status = "Idle"
        }
    }

    /// red-team #2: detach readability handlers BEFORE dropping the handle so
    /// the dispatch queue managing them doesn't keep `self` alive forever.
    private func tearDownProcess() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        proc = nil
    }

    // ---------- NDJSON parsing ----------

    /// Bulk parser for `log show` output. Returns (parsed rows, skipped count).
    /// red-team #2/#3: each malformed line is dropped, parse never fails the
    /// batch; lines over `maxLineBytes` are skipped (counted) so a runaway
    /// blob can't OOM either String(data:) or JSONSerialization.
    static func parseNDJSON(_ data: Data, max: Int) -> ([LogEntry], Int) {
        var out: [LogEntry] = []
        out.reserveCapacity(min(max, 1024))
        var skipped = 0
        // Walk on bytes so we can enforce a per-line cap WITHOUT first
        // turning the whole blob into a String (which would also OOM).
        var lineStart = 0
        let count = data.count
        data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < count {
                if base[i] == 0x0A {
                    if out.count >= max { return }
                    let lineLen = i - lineStart
                    if lineLen > 0 && lineLen <= maxLineBytes {
                        let lineData = data.subdata(in: lineStart..<i)
                        if let line = String(data: lineData, encoding: .utf8),
                           let e = parseLine(line) {
                            out.append(e)
                        } else {
                            skipped += 1
                        }
                    } else if lineLen > maxLineBytes {
                        skipped += 1
                    }
                    lineStart = i + 1
                }
                i += 1
            }
        }
        return (out, skipped)
    }

    /// Streaming parser. Holds a leftover buffer for partial last line.
    /// red-team #2/#3: enforces `maxLineBytes` per line; oversize lines are
    /// counted and discarded without ever being materialised as a String.
    static func parseNDJSONStreaming(_ buf: Data) -> ([LogEntry], Data, Int) {
        var rows: [LogEntry] = []
        var skipped = 0
        var lineStart = 0
        var cursor = 0
        let count = buf.count
        buf.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < count {
                if base[i] == 0x0A {
                    let lineLen = i - lineStart
                    if lineLen > 0 && lineLen <= maxLineBytes {
                        let lineData = buf.subdata(in: lineStart..<i)
                        if let line = String(data: lineData, encoding: .utf8),
                           let e = parseLine(line) {
                            rows.append(e)
                        } else {
                            skipped += 1
                        }
                    } else if lineLen > maxLineBytes {
                        skipped += 1
                    }
                    lineStart = i + 1
                    cursor = lineStart
                }
                i += 1
            }
        }
        // Defence: if the *partial* leftover already exceeds the cap, drop
        // it (caller will count via maxStreamBufferBytes too).
        let leftover = buf.subdata(in: cursor..<buf.count)
        if leftover.count > maxLineBytes {
            return (rows, Data(), skipped + 1)
        }
        return (rows, leftover, skipped)
    }

    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `/usr/bin/log` prints "Filtering the log data using …" preambles to
    /// stdout in some versions before the first row. Those start with `{` only
    /// on real NDJSON rows; everything else gets dropped here.
    private static func parseLine(_ line: String) -> LogEntry? {
        guard line.first == "{" else { return nil }
        guard let data = line.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { return nil }

        let msg = (obj["eventMessage"] as? String) ?? ""
        let subsystem = (obj["subsystem"] as? String) ?? ""
        let category = (obj["category"] as? String) ?? ""
        let process = (obj["processImagePath"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (obj["process"] as? String)
            ?? ""
        let pid = (obj["processID"] as? Int) ?? (obj["processIdentifier"] as? Int) ?? 0
        let level = LogLevel.parse(obj["messageType"])

        // timestamp: usually ISO8601 with fractional seconds; sometimes a
        // mach-style absolute that we'd rather not parse — fall back to now.
        var ts = Date()
        if let s = obj["timestamp"] as? String {
            if let d = isoFmt.date(from: s) {
                ts = d
            } else {
                // try without fractional seconds
                let alt = ISO8601DateFormatter()
                alt.formatOptions = [.withInternetDateTime]
                if let d = alt.date(from: s) { ts = d }
            }
        }

        return LogEntry(timestamp: ts,
                        level: level,
                        process: process,
                        pid: pid,
                        subsystem: subsystem,
                        category: category,
                        message: msg)
    }
}

enum LogMode: String, CaseIterable, Identifiable {
    case show   = "Fetch"
    case stream = "Stream"
    var id: String { rawValue }
}

private final class LogDrainBox { var data = Data() }

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct LogViewerView: View {

    public init() {}

    // Filter state.
    @State private var mode: LogMode = .show
    @State private var timeRange: LogTimeRange = .h1
    @State private var startDate: Date = Date().addingTimeInterval(-3600)
    @State private var endDate: Date = Date()
    @State private var levelSel: LogLevelChoice = .all
    @State private var subsystem: String = ""
    @State private var process: String = ""
    @State private var contains: String = ""
    @State private var includeInfoDebug: Bool = false
    @State private var autoScroll: Bool = true

    // Result UI state.
    @State private var expanded: Set<UUID> = []

    @StateObject private var runner = LogRunner()
    @ObservedObject private var exportController = LogExportController.shared

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LogFilterCard(mode: $mode,
                              timeRange: $timeRange,
                              startDate: $startDate,
                              endDate: $endDate,
                              levelSel: $levelSel,
                              subsystem: $subsystem,
                              process: $process,
                              contains: $contains,
                              includeInfoDebug: $includeInfoDebug,
                              autoScroll: $autoScroll)

                LogPresetsCard(apply: applyPreset)

                LogResultsCard(runner: runner,
                               expanded: $expanded,
                               autoScroll: $autoScroll,
                               isStreaming: mode == .stream && runner.isRunning)
            }
            .padding(16)
        }
        .navigationTitle("Log")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        .onDisappear { runner.stop() }
    }

    private var subtitle: String {
        if let e = runner.errorText { return e }
        var parts: [String] = []
        parts.append(runner.status)
        if runner.skipped > 0 { parts.append("\(runner.skipped) malformed line\(runner.skipped == 1 ? "" : "s") skipped") }
        return parts.joined(separator: " — ")
    }

    // ---------- Toolbar ----------

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if runner.isRunning {
                Button(role: .destructive) { runner.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop the running log command (Esc or ⌘.)")
                Button("") { runner.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            } else if exportController.exporting {
                Button(role: .destructive) { exportController.cancel() } label: {
                    Label("Cancel Export", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Cancel the running export (Esc or ⌘.)")
                Button("") { exportController.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            } else {
                Button { run() } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .help(mode == .stream ? "Start live tail (⌘⏎)" : "Fetch entries (⌘⏎)")
            }

            // Copy buffer as one big text blob — primary verb for log output.
            Button {
                copySelectedLines()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(runner.entries.isEmpty)
            .help("Copy all visible log lines to the clipboard")

            // Save As… → NSSavePanel default name "Console export <date>.log"
            // with predicate metadata as a header comment line.
            Button {
                LogSaveHelpers.saveAsLog(entries: runner.entries,
                                         predicate: predicateLabel(),
                                         rangeLabel: rangeLabel())
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .disabled(runner.entries.isEmpty)
            .help("Save the visible rows as a .log file")

            // Per-affordance-spec "More" — Save to Downloads + Save All
            // matching predicate (re-runs without the visible cap).
            Menu {
                Button {
                    LogSaveHelpers.saveToDownloads(entries: runner.entries,
                                                   predicate: predicateLabel(),
                                                   rangeLabel: rangeLabel())
                } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .disabled(runner.entries.isEmpty)

                Divider()

                Button {
                    saveAllMatchingPredicate()
                } label: {
                    Label("Save All matching predicate…", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(mode == .stream || runner.isRunning)
                .help("Re-fetch every line that currently matches the filter and write them to a file (no row cap).")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More save / export actions")

            Button {
                sendToStage()
            } label: {
                Label("Send to Stage", systemImage: "tray.and.arrow.down.fill")
            }
            .disabled(runner.entries.isEmpty)
            .help("Append the visible rows to the Stage as text")
        }
    }

    // ---------- Save / export action helpers ----------

    /// Concise predicate description for the file header comment.
    private func predicateLabel() -> String {
        var parts: [String] = []
        parts.append("level=\(levelSel.label)")
        let sub = subsystem.trimmingCharacters(in: .whitespacesAndNewlines)
        let proc = process.trimmingCharacters(in: .whitespacesAndNewlines)
        let cont = contains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sub.isEmpty  { parts.append("subsystem=\(sub)") }
        if !proc.isEmpty { parts.append("process=\(proc)") }
        if !cont.isEmpty { parts.append("contains=\(cont)") }
        if includeInfoDebug { parts.append("info+debug") }
        return parts.joined(separator: ", ")
    }

    private func rangeLabel() -> String {
        switch mode {
        case .stream: return "stream"
        case .show:
            if timeRange == .custom {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                return "\(f.string(from: startDate)) → \(f.string(from: endDate))"
            }
            return timeRange.rawValue
        }
    }

    private func copySelectedLines() {
        let blob = runner.entries.map { $0.plainText() }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(blob, forType: .string)
        SharedStore.stage.flash("Copied \(runner.entries.count) log line\(runner.entries.count == 1 ? "" : "s")")
    }

    /// "Save All matching predicate" — re-fetch without the 5000 cap and
    /// stream the entire matched set straight to a chosen file. We rebuild
    /// the predicate locally (same builder used by `run()`) and shell out to
    /// `/usr/bin/log show` directly so we never inflate the in-memory buffer.
    private func saveAllMatchingPredicate() {
        let lvl = levelSel.level
        let extra = levelSel.customPredicate
        guard let predicate = LogPredicate.build(level: lvl,
                                                 extraLevelClause: extra,
                                                 subsystem: subsystem,
                                                 process: process,
                                                 contains: contains) else {
            SharedStore.stage.flash("Invalid filter — check for stray quotes or operators.")
            return
        }
        // Reuse the same triviality guards as `fetch()` — a vacuous predicate
        // over 24h or a >6h custom range would dump gigabytes to disk.
        if mode == .stream {
            SharedStore.stage.flash("Save All matching predicate works in Fetch mode only")
            return
        }
        if timeRange == .h24 && LogPredicate.isTrivial(predicate: predicate,
                                                       level: lvl,
                                                       subsystem: subsystem,
                                                       process: process,
                                                       contains: contains) {
            SharedStore.stage.flash("Add a filter before exporting 24h — an empty filter could pull gigabytes.")
            return
        }
        if timeRange == .custom,
           endDate.timeIntervalSince(startDate) > 6 * 3600,
           LogPredicate.isTrivial(predicate: predicate,
                                  level: lvl,
                                  subsystem: subsystem,
                                  process: process,
                                  contains: contains) {
            SharedStore.stage.flash("Add a filter before exporting a >6h custom range — an empty filter could pull gigabytes.")
            return
        }
        if timeRange == .custom, endDate <= startDate {
            SharedStore.stage.flash("End date must be after start date.")
            return
        }
        LogSaveHelpers.saveAllMatching(timeRange: timeRange,
                                       startDate: startDate,
                                       endDate: endDate,
                                       includeInfoDebug: includeInfoDebug,
                                       predicate: predicate,
                                       predicateLabel: predicateLabel(),
                                       rangeLabel: rangeLabel())
    }

    // ---------- Actions ----------

    private func run() {
        let lvl = levelSel.level
        let extra = levelSel.customPredicate
        switch mode {
        case .show:
            runner.fetch(timeRange: timeRange,
                         startDate: startDate,
                         endDate: endDate,
                         level: lvl,
                         extraLevelClause: extra,
                         subsystem: subsystem,
                         process: process,
                         contains: contains,
                         includeInfoDebug: includeInfoDebug)
        case .stream:
            runner.stream(level: lvl,
                          extraLevelClause: extra,
                          subsystem: subsystem,
                          process: process,
                          contains: contains,
                          includeInfoDebug: includeInfoDebug)
        }
    }

    private func applyPreset(_ p: LogPreset) {
        levelSel = p.level
        subsystem = p.subsystem
        process = p.process
        contains = p.contains
        if !runner.isRunning { run() }
    }

    private func sendToStage() {
        let header = "# log — \(mode.rawValue) — \(runner.entries.count) row(s)"
        let body = runner.entries.map { $0.plainText() }.joined(separator: "\n")
        let blob = header + "\n" + body
        SharedStore.stage.addText(blob)
        SharedStore.stage.flash("Sent \(runner.entries.count) log row\(runner.entries.count == 1 ? "" : "s") to Stage")
    }
}

// ===========================================================================
// MARK: - Filter card
// ===========================================================================

/// Picker-friendly wrapper around `LogLevel?` (we need an "All" sentinel,
/// plus a combined "Errors+Faults" option for the crashes preset).
enum LogLevelChoice: Hashable, CaseIterable, Identifiable {
    case all, `default`, info, debug, error, fault, errorsAndFaults

    var id: Self { self }

    var label: String {
        switch self {
        case .all:             return "All"
        case .default:         return "Default"
        case .info:            return "Info"
        case .debug:           return "Debug"
        case .error:           return "Error"
        case .fault:           return "Fault"
        case .errorsAndFaults: return "Errors + Faults"
        }
    }

    /// For most choices we delegate to the simple single-level matcher in the
    /// runner. `.errorsAndFaults` is handled specially via `customPredicate`.
    var level: LogLevel? {
        switch self {
        case .all, .errorsAndFaults: return nil
        case .default: return .default
        case .info:    return .info
        case .debug:   return .debug
        case .error:   return .error
        case .fault:   return .fault
        }
    }

    /// Extra clause to AND into the predicate, or nil.
    var customPredicate: String? {
        switch self {
        case .errorsAndFaults: return "messageType >= 16"
        default:               return nil
        }
    }

    static func from(_ lvl: LogLevel?) -> LogLevelChoice {
        guard let l = lvl else { return .all }
        switch l {
        case .default: return .default
        case .info:    return .info
        case .debug:   return .debug
        case .error:   return .error
        case .fault:   return .fault
        }
    }
}

struct LogFilterCard: View {
    @Binding var mode: LogMode
    @Binding var timeRange: LogTimeRange
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var levelSel: LogLevelChoice
    @Binding var subsystem: String
    @Binding var process: String
    @Binding var contains: String
    @Binding var includeInfoDebug: Bool
    @Binding var autoScroll: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.tint)
                    Text("Filters").headerText()
                    Spacer()
                    Picker("", selection: $mode) {
                        ForEach(LogMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .labelsHidden()
                }

                // Row 1: time range + (custom date pickers) + level
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time range").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $timeRange) {
                            ForEach(LogTimeRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(mode == .stream)
                    }
                    .frame(width: 160)

                    if timeRange == .custom && mode == .show {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start").font(.caption).foregroundStyle(.secondary)
                            DatePicker("", selection: $startDate)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("End").font(.caption).foregroundStyle(.secondary)
                            DatePicker("", selection: $endDate)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Level").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $levelSel) {
                            ForEach(LogLevelChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                    }
                    .frame(width: 140)

                    Spacer()
                }

                // Row 2: subsystem + process + contains
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subsystem").font(.caption).foregroundStyle(.secondary)
                        TextField("com.apple.WindowServer", text: $subsystem)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Process").font(.caption).foregroundStyle(.secondary)
                        TextField("Trove", text: $process)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Message contains").font(.caption).foregroundStyle(.secondary)
                        TextField("crashed", text: $contains)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // Row 3: toggles
                HStack(spacing: 16) {
                    Toggle("Include info / debug", isOn: $includeInfoDebug)
                        .toggleStyle(.switch)
                        .help("Off by default — `--info`/`--debug` can produce hundreds of MB on `log show --last 24h`.")
                    if mode == .stream {
                        Toggle("Auto-scroll", isOn: $autoScroll)
                            .toggleStyle(.switch)
                    }
                    Spacer()
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Presets card
// ===========================================================================

struct LogPresetsCard: View {
    let apply: (LogPreset) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 10)
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                    Text("Saved presets").headerText()
                    Spacer()
                    Text("Click to apply + run").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(LogPreset.all) { p in
                        Button { apply(p) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: p.icon)
                                    .frame(width: 18)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).font(.body.weight(.medium))
                                    Text(p.blurb)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Results card
// ===========================================================================

struct LogResultsCard: View {
    @ObservedObject var runner: LogRunner
    @Binding var expanded: Set<UUID>
    @Binding var autoScroll: Bool
    let isStreaming: Bool
    // Fix 25: gate auto-scroll animation on reduceMotion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.tint)
                    Text("Results").headerText()
                    Spacer()
                    if runner.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text("\(runner.entries.count) row\(runner.entries.count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if runner.entries.isEmpty {
                    LogEmptyState(isRunning: runner.isRunning, error: runner.errorText)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(runner.entries) { e in
                                    LogRow(entry: e,
                                           expanded: expanded.contains(e.id),
                                           toggle: { toggle(e.id) })
                                        .id(e.id)
                                    Divider().opacity(0.4)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(minHeight: 320, maxHeight: 560)
                        .background(.background.tertiary,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                        )
                        .onChange(of: runner.entries.count) { _ in
                            if isStreaming && autoScroll,
                               let last = runner.entries.last?.id {
                                // Fix 25: skip animation when reduceMotion is set.
                                if reduceMotion {
                                    proxy.scrollTo(last, anchor: .bottom)
                                } else {
                                    withAnimation(.linear(duration: 0.08)) {
                                        proxy.scrollTo(last, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

struct LogEmptyState: View {
    let isRunning: Bool
    let error: String?
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: error != nil ? "exclamationmark.triangle"
                            : (isRunning ? "ellipsis" : "doc.text.magnifyingglass"))
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(error
                 ?? (isRunning
                     ? "Waiting for entries…"
                     : "Run a fetch or stream to see entries here."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct LogRow: View {
    let entry: LogEntry
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(LogFormatters.hms.string(from: entry.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                Text(processLabel)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)
                LogLevelPill(level: entry.level)
                Text(entry.oneLine)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(entry.level.tint)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .contextMenu {
                Button("Copy line") { copyLine() }
                Button("Copy message only") { copyMessage() }
                Divider()
                Button("Save line as…") {
                    LogSaveHelpers.saveAsLog(entries: [entry],
                                             predicate: "single row",
                                             rangeLabel: "")
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if !entry.subsystem.isEmpty {
                        Text("subsystem: \(entry.subsystem)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !entry.category.isEmpty {
                        Text("category: \(entry.category)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 110)
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var processLabel: String {
        let proc = entry.process.isEmpty ? "?" : entry.process
        return entry.pid > 0 ? "\(proc)[\(entry.pid)]" : proc
    }

    private func copyLine() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.plainText(), forType: .string)
    }
    private func copyMessage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.message, forType: .string)
    }
}

struct LogLevelPill: View {
    let level: LogLevel
    var body: some View {
        Text(level.label.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(level.tint)
            .background(level.tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(level.tint.opacity(0.35), lineWidth: 0.5)
            )
            .frame(width: 56, alignment: .leading)
    }
}

// ===========================================================================
// MARK: - Save helpers (statics — no captured view state)
// ===========================================================================

/// Tracks the in-flight `Save All matching predicate` export so the toolbar
/// can render a Cancel button and the parent view can keep `Stop` visible
/// while the background `/usr/bin/log show` shell-out is draining stdout.
@MainActor
final class LogExportController: ObservableObject {
    static let shared = LogExportController()
    @Published var exporting: Bool = false

    /// Guarded mutable shared state lives on a separate `@unchecked Sendable`
    /// box so the off-main drain loop can poll cancellation and the main-
    /// actor cancel() can terminate the child without crossing isolation.
    private let state = LogExportControllerState()

    nonisolated func register(_ p: Process) { state.register(p) }
    nonisolated func clear() { state.clear() }
    nonisolated func isCancelled() -> Bool { state.isCancelled() }
    func cancel() { state.cancel() }
}

/// Lock-protected box for the LogExportController's child-process handle.
/// Lives outside the MainActor class so non-isolated callers (the background
/// drain queue) can read/write it without an actor hop. Mirrors the
/// `DiskSpeedCancelFlag` pattern.
final class LogExportControllerState: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var proc: Process?
    private var cancelled: Bool = false

    func register(_ p: Process) {
        os_unfair_lock_lock(&lock)
        proc = p
        cancelled = false
        os_unfair_lock_unlock(&lock)
    }
    func clear() {
        os_unfair_lock_lock(&lock)
        proc = nil
        os_unfair_lock_unlock(&lock)
    }
    func isCancelled() -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return cancelled
    }
    func cancel() {
        os_unfair_lock_lock(&lock)
        cancelled = true
        let p = proc
        os_unfair_lock_unlock(&lock)
        if let p = p, p.isRunning { p.terminate() }
    }
}

enum LogSaveHelpers {
    private static let kSaveDirKey = "log_viewer.saveDir.last"

    /// Build the file body: a header comment line plus one log line per row.
    /// Header format mirrors `console`-style banners so a downstream `grep`
    /// or `awk` can ignore it via `^#`.
    private static func body(entries: [LogEntry],
                             predicate: String,
                             rangeLabel: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        var parts: [String] = []
        parts.reserveCapacity(entries.count + 5)
        parts.append("# Trove — Console export")
        parts.append("# Exported: \(f.string(from: Date()))")
        if !predicate.isEmpty { parts.append("# Filter: \(predicate)") }
        if !rangeLabel.isEmpty { parts.append("# Range: \(rangeLabel)") }
        parts.append("# Rows: \(entries.count)")
        for e in entries { parts.append(e.plainText()) }
        return parts.joined(separator: "\n")
    }

    /// "Console export YYYY-MM-DD.log" — the file the user sees in NSSavePanel.
    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Console export \(f.string(from: Date())).log"
    }

    /// Save As… → NSSavePanel writes UTF-8 .log with a header comment line.
    static func saveAsLog(entries: [LogEntry], predicate: String, rangeLabel: String) {
        let blob = body(entries: entries, predicate: predicate, rangeLabel: rangeLabel)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName()
        if let logUT = UTType(filenameExtension: "log") {
            panel.allowedContentTypes = [logUT]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                try blob.data(using: .utf8)?.write(to: dest, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved \(dest.lastPathComponent)")
            } catch {
                LogViewerSaveTexts.flashSaveError(error)
            }
        }
    }

    /// One-click save into ~/Downloads with collision-safe naming.
    static func saveToDownloads(entries: [LogEntry], predicate: String, rangeLabel: String) {
        let blob = body(entries: entries, predicate: predicate, rangeLabel: rangeLabel)
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let dest = collisionFreeURL(in: downloads, name: defaultFileName())
        do {
            try blob.data(using: .utf8)?.write(to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved \(dest.lastPathComponent) to Downloads")
        } catch {
            LogViewerSaveTexts.flashSaveError(error)
        }
    }

    /// Save All matching predicate — re-runs `/usr/bin/log show` without the
    /// 5000-row UI cap and streams stdout directly to a chosen file. NDJSON
    /// is parsed line-by-line and serialised in the same plaintext shape as
    /// the in-app rows, so downstream tooling sees the same format.
    ///
    /// Heavy lifting (process + parse + write) runs off-main; the user is
    /// flashed when done. We re-use LogRunner.parseLine via a tiny shim — but
    /// that's a `private static`, so we parse inline here.
    static func saveAllMatching(timeRange: LogTimeRange,
                                startDate: Date,
                                endDate: Date,
                                includeInfoDebug: Bool,
                                predicate: String,
                                predicateLabel: String,
                                rangeLabel: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName()
        if let logUT = UTType(filenameExtension: "log") {
            panel.allowedContentTypes = [logUT]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.message = "Re-fetches every matching line — no row cap."
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            SharedStore.stage.flash("Exporting matching log lines…")
            let controller = LogExportController.shared
            Task { @MainActor in controller.exporting = true }
            DispatchQueue.global(qos: .userInitiated).async {
                // Build argv same way LogRunner.buildArgs does, but bypass the
                // 5000-row cap by parsing the entire stdout buffer.
                var a: [String] = ["show", "--style", "ndjson"]
                if let last = timeRange.lastFlag {
                    a.append("--last"); a.append(last)
                } else {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    f.locale = Locale(identifier: "en_US_POSIX")
                    a.append("--start"); a.append(f.string(from: startDate))
                    a.append("--end");   a.append(f.string(from: endDate))
                }
                if includeInfoDebug {
                    a.append("--info"); a.append("--debug")
                }
                if !predicate.isEmpty {
                    a.append("--predicate"); a.append(predicate)
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                p.arguments = a
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                // Register BEFORE run() so a near-instant cancel can still
                // terminate; clear on the way out so a future export starts
                // with a fresh handle.
                controller.register(p)
                defer {
                    controller.clear()
                    Task { @MainActor in controller.exporting = false }
                }
                do { try p.run() } catch {
                    DispatchQueue.main.async {
                        SharedStore.stage.flash("Failed to launch /usr/bin/log: \(error.localizedDescription)")
                    }
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExitOffMain()

                if controller.isCancelled() {
                    DispatchQueue.main.async {
                        SharedStore.stage.flash("Export cancelled", kind: .warning)
                    }
                    return
                }

                // Reuse LogRunner's bulk parser — it returns LogEntry rows.
                // We pass a generous cap; it's the "no UI cap" path.
                let (rows, _) = LogRunner.parseNDJSON(data, max: Int.max)
                let blob = body(entries: rows,
                                predicate: predicateLabel,
                                rangeLabel: rangeLabel)
                do {
                    try blob.data(using: .utf8)?.write(to: dest, options: .atomic)
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                        SharedStore.stage.flash("Saved \(rows.count) line\(rows.count == 1 ? "" : "s") to \(dest.lastPathComponent)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        SharedStore.stage.flash("Couldn't save export: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // ---- shared helpers -------------------------------------------------

    static func lastSaveDir() -> URL? {
        guard let p = UserDefaults.standard.string(forKey: kSaveDirKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }
    static func setLastSaveDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: kSaveDirKey)
    }
    static func downloadsDir() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
    static func collisionFreeURL(in dir: URL, name: String) -> URL {
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
}

// ===========================================================================
// MARK: - Save error → TCC deep-link bridge
// ===========================================================================

/// Surfaces save failures from the log viewer. When the underlying error is
/// a TCC-shaped write denial (Cocoa `NSFileWriteNoPermissionError` or POSIX
/// `EACCES/EPERM` against a TCC-walled folder like Documents/Desktop/
/// Downloads), we attach an "Open Settings" action that deep-links to the
/// Files & Folders Privacy pane so the user can grant access without
/// hunting through System Settings. All other errors fall back to a plain
/// warning toast — we never invent a misleading remediation.
enum LogViewerSaveTexts {
    static func flashSaveError(_ error: Error) {
        let ns = error as NSError
        let isPermissionShaped =
            (ns.domain == NSCocoaErrorDomain
             && (ns.code == NSFileWriteNoPermissionError
                 || ns.code == NSFileReadNoPermissionError)) ||
            (ns.domain == NSPOSIXErrorDomain
             && (ns.code == 1 /* EPERM */ || ns.code == 13 /* EACCES */))
        if isPermissionShaped {
            SharedStore.stage.flash(
                "Couldn't save: \(error.localizedDescription)",
                kind: .warning,
                actionLabel: "Open Settings") {
                TCCDeepLink.filesAndFolders.open()
            }
        } else {
            SharedStore.stage.flash("Couldn't save: \(error.localizedDescription)",
                                    kind: .error)
        }
    }
}
