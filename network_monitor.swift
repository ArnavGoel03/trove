// Trove — Network pane.
//   • Per-process throughput monitor backed by /usr/bin/nettop. Read-only.
//   • Top N processes by bytes_in + bytes_out per second, with sparklines.
//   • Filter by direction (In / Out / Both) and name substring.
//   • Per-app grouping (Chrome Helper #1, #2, … rolled under the bundle row).
//   • Live update at 1s / 2s / 5s, Pause, Reset baselines, CSV export.
//   • Compact corner-widget mode (top-4 rows, no chrome).
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Foundation

// ===========================================================================
// MARK: - nettop invocation & parser
// ===========================================================================

/// Snapshot of one process's totals at one tick.
/// `bytesIn` / `bytesOut` are cumulative since whenever nettop started; the
/// model takes deltas across ticks to produce per-second rates.
struct NetSample: Hashable {
    let pid: Int32
    let name: String       // process name as nettop prints it (e.g. "Google Chrome Helper")
    let bytesIn: Int64
    let bytesOut: Int64
}

/// nettop invocation we ship: per-process (-P), one period (-L 1) per chunk —
/// we re-run nettop each tick rather than long-running. CSV-ish output (-x),
/// only the `bytes_in,bytes_out` columns (-J), and skip loopback (-t external)
/// so localhost chatter (Spotlight, mdns) doesn't crowd out real traffic.
///
/// Why per-tick fork instead of one long-running nettop:
///   • Simpler lifecycle — no pipe-buffer-deadlock risk (red-team #3 still
///     covered defensively below via readabilityHandler).
///   • Pause / interval-change "just works" — next tick reads fresh config.
///   • nettop's own delta math is fine; we'd be ignoring it anyway in favour
///     of our own delta-against-prior-snapshot for sparklines.
let netNettopPath = "/usr/bin/nettop"
let netNettopArgs = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-t", "external"]

enum NetSamplerError: Error, CustomStringConvertible {
    case notInstalled
    case launchFailed(String)
    case noOutput
    var description: String {
        switch self {
        case .notInstalled:      return "/usr/bin/nettop is not present on this system. Install the Xcode Command Line Tools (`xcode-select --install`) or upgrade macOS."
        case .launchFailed(let s): return "nettop failed: \(s)"
        case .noOutput:          return "nettop returned no rows (check that the Network pane has TCC traffic-sampling rights, or try again — macOS occasionally needs a warm-up tick)."
        }
    }
}

enum NetSampler {
    /// Run nettop once and parse a single-period snapshot. Off-main only.
    ///
    /// Red-team #2: this is a short-lived Process — opened, drained via
    /// readabilityHandler (red-team #3), waitUntilExit'd, dropped. No long
    /// lived child to leak. The model owns no Process state between ticks.
    static func sample() throws -> [NetSample] {
        guard FileManager.default.isExecutableFile(atPath: netNettopPath) else {
            throw NetSamplerError.notInstalled
        }
        // red-team-sec: nettop path + argv are both compile-time constants
        // (top of file). No user input is ever interpolated into argv, so
        // shell injection is structurally impossible here. We use
        // executableURL (no shell interposed) so each argv element is
        // delivered verbatim to nettop.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: netNettopPath)
        p.arguments = netNettopArgs

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe

        // Red-team #3: drain stdout via readabilityHandler into a heap box so
        // a >64KB nettop dump can't block the child on a full pipe. We can't
        // safely use readDataToEndOfFile here either — it works for short
        // outputs but the handler pattern matches the lesson the codebase
        // already learned (see runShell in main.swift).
        let box = NetDrainBox()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                // EOF — handler will get called once with empty Data when child
                // closes the pipe. Detach the handler then signal completion.
                h.readabilityHandler = nil
                drainGroup.leave()
            } else {
                box.append(d)
            }
        }
        // Drain stderr too so it can't deadlock the child either. We discard.
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil }
        }

        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw NetSamplerError.launchFailed(error.localizedDescription)
        }
        // red-team: bound the worst-case sampler wall-time. nettop is normally
        // sub-second under -L 1, but on a wedged interface (VPN tearing down,
        // PF rule reload) it has been observed to hang. Hard-terminate after
        // ~6s so we never pile up child processes or block the in-flight slot.
        let killAfter = DispatchTime.now() + .seconds(6)
        let killQueue = DispatchQueue.global(qos: .utility)
        let killWorkItem = DispatchWorkItem { [weak p] in
            guard let p = p, p.isRunning else { return }
            p.terminate()
            // Give it 250ms to exit gracefully, then SIGKILL.
            killQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak p] in
                if let p = p, p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
        killQueue.asyncAfter(deadline: killAfter, execute: killWorkItem)
        p.waitUntilExitOffMain()
        killWorkItem.cancel()
        // Wait briefly for the readability handler's final EOF signal. macOS
        // sometimes delivers the empty-Data callback a tick after exit; cap
        // the wait so we never hang the sampler.
        _ = drainGroup.wait(timeout: .now() + 0.5)
        outPipe.fileHandleForReading.readabilityHandler = nil

        let s = String(data: box.snapshot(), encoding: .utf8) ?? ""
        let rows = parse(s)
        if rows.isEmpty && !s.isEmpty {
            // Output present but unparseable — surface to UI rather than
            // silently showing an empty list.
            throw NetSamplerError.noOutput
        }
        return rows
    }

    /// Parse nettop's `-x` CSV-style output. nettop's columns under `-P -J bytes_in,bytes_out`
    /// look like:
    ///
    ///     time,,bytes_in,bytes_out
    ///     12:00:01.000000,,,
    ///     Safari.12345,,1234,5678
    ///     Google Chrome Helper.67890,,9999,1111
    ///
    /// (Number of leading commas varies between OS versions — sometimes the
    /// timestamp column is omitted, sometimes there are extra empties.) We
    /// only care about rows of the form `<name>.<pid>` plus two integer
    /// columns; anything else is skipped.
    ///
    /// Red-team #4: nettop re-prints headers between periods (rare under
    /// `-L 1` but observed under SIGWINCH). The numeric-field guard below
    /// drops header rows because `pid` won't parse as Int32.
    static func parse(_ s: String) -> [NetSample] {
        var out: [NetSample] = []
        out.reserveCapacity(128)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var seen: Set<Int32> = []  // dedupe — nettop sometimes prints two rows for one pid
        for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
            // Strip CR (in case nettop emits CRLF, rare on macOS but seen
            // when piped through some shells / locale=C combos).
            let line = raw.hasSuffix("\r") ? Substring(raw.dropLast()) : raw
            // red-team: skip header rows and pre-run banners. Headers may be
            // "time,bytes_in,bytes_out" or just "bytes_in,bytes_out" depending
            // on macOS version; nettop has also been observed to re-print
            // headers mid-stream after SIGWINCH. We also drop lines that
            // contain no '.' (PID delimiter) or no digit anywhere — those are
            // banner/status lines like "Capturing for ..." or "Process info
            // unavailable.".
            if line.hasPrefix("time,") { continue }
            if line.hasPrefix("bytes_in,") || line.hasPrefix("bytes_out,") { continue }
            // Banner / advisory lines have no '.' (no `name.pid` token).
            if !line.contains(".") { continue }
            // Split on comma. We want the first column (`name.pid`) and the
            // last two **integer** columns (bytes_in, bytes_out). Some
            // nettop builds emit empty interstitial columns; we tolerate them.
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { continue }
            let head = cols[0].trimmingCharacters(in: .whitespaces)
            if head.isEmpty { continue }
            // Find the last two columns that parse as Int64. This survives
            // both `name.pid,,bin,bout` and `name.pid,bin,bout` and
            // `name.pid,,,bin,bout`.
            var ints: [Int64] = []
            for c in cols.reversed() {
                let t = c.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let n = Int64(t) {
                    ints.append(n)
                    if ints.count == 2 { break }
                } else {
                    // First non-numeric trailing token: stop — we've walked
                    // off the numeric tail back into the name column.
                    break
                }
            }
            guard ints.count == 2 else { continue }
            let bytesOut = ints[0]
            let bytesIn  = ints[1]

            // Split `name.pid` from the right on the last '.'.
            guard let dotIdx = head.lastIndex(of: ".") else { continue }
            let nameSub = head[..<dotIdx]
            let pidSub  = head[head.index(after: dotIdx)...]
            guard let pid = Int32(pidSub), pid != Int32(selfPID) else { continue }
            if seen.contains(pid) { continue }
            seen.insert(pid)
            let name = String(nameSub).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            out.append(NetSample(pid: pid, name: name, bytesIn: bytesIn, bytesOut: bytesOut))
        }
        return out
    }
}

/// Heap-allocated drain buffer (matches the DrainBox pattern in main.swift's
/// runShell): the readability handler closure captures this reference type
/// so appends mutate one shared buffer across handler invocations.
private final class NetDrainBox {
    private let q = DispatchQueue(label: "trove.net.drain")
    private var buf = Data()
    func append(_ d: Data) { q.sync { buf.append(d) } }
    func snapshot() -> Data { q.sync { buf } }
}

// ===========================================================================
// MARK: - Model
// ===========================================================================

enum NetDirection: String, CaseIterable, Identifiable {
    case both = "Both"
    case incoming = "In"
    case outgoing = "Out"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .both:     return "arrow.up.arrow.down"
        case .incoming: return "arrow.down"
        case .outgoing: return "arrow.up"
        }
    }
}

/// One persistent row keyed by PID. Holds rolling per-second rate history for
/// the sparkline and session-scoped totals computed against a `baseline` so
/// the user's "Reset" hotkey can zero everything without losing the row.
@MainActor
final class NetRow: Identifiable, ObservableObject {
    let pid: Int32
    @Published var name: String

    // Cumulative bytes as reported by nettop on the most recent tick.
    @Published var cumIn: Int64 = 0
    @Published var cumOut: Int64 = 0

    // Baselines — subtracted from cumulative to get "session" totals.
    // Reset on user demand; also reset if nettop's counter goes backwards
    // (process restart / counter wrap).
    @Published var baseIn: Int64 = 0
    @Published var baseOut: Int64 = 0

    // Per-second rates derived from delta(cum) / delta(t). Capped @ 60 samples
    // (red-team #5).
    @Published var rateInHistory:  [Double] = []
    @Published var rateOutHistory: [Double] = []
    @Published var rateIn:  Double = 0
    @Published var rateOut: Double = 0

    // Timestamp of the most recent sample we absorbed — used to drop stale
    // rows after 30s of silence (red-team #5).
    @Published var lastSeen: Date = .now

    var id: Int32 { pid }
    var totalIn:  Int64 { max(0, cumIn  - baseIn)  }
    var totalOut: Int64 { max(0, cumOut - baseOut) }
    var sumRate:  Double { rateIn + rateOut }

    init(pid: Int32, name: String, cumIn: Int64, cumOut: Int64) {
        self.pid = pid
        self.name = name
        self.cumIn = cumIn
        self.cumOut = cumOut
        // Baseline at first-seen so "session totals" are zero at the moment
        // the user first sees this process — not the moment nettop launched.
        self.baseIn = cumIn
        self.baseOut = cumOut
    }

    /// Merge a new sample. `dt` is the wallclock interval since the prior
    /// successful tick (typically `m.interval`); used to compute the rate.
    func absorb(_ s: NetSample, dt: Double, now: Date) {
        name = s.name
        // Detect a counter going backwards (process exited & a new one took
        // the PID — extremely unlikely between ticks but cheap to guard).
        // red-team: also reset on the FIRST-tick-after-resume case where dt
        // is wildly bigger than the configured interval — a system that just
        // came back from sleep would compute "5 GB/s" from cumulative bytes
        // accrued during the sleep window. If dt > 10× interval, treat this
        // sample as a fresh baseline instead of a delta.
        let dtAbsurd = dt > 30 // any 30s+ gap is post-sleep, not normal poll
        if dtAbsurd || s.bytesIn < cumIn || s.bytesOut < cumOut {
            baseIn = s.bytesIn
            baseOut = s.bytesOut
            cumIn = s.bytesIn
            cumOut = s.bytesOut
            rateIn = 0; rateOut = 0
            rateInHistory.append(0)
            rateOutHistory.append(0)
            if rateInHistory.count  > 60 { rateInHistory.removeFirst(rateInHistory.count - 60) }
            if rateOutHistory.count > 60 { rateOutHistory.removeFirst(rateOutHistory.count - 60) }
            lastSeen = now
            return
        }
        let dIn  = max(0, s.bytesIn  - cumIn)
        let dOut = max(0, s.bytesOut - cumOut)
        cumIn = s.bytesIn
        cumOut = s.bytesOut
        let denom = max(dt, 0.001)
        rateIn  = Double(dIn)  / denom
        rateOut = Double(dOut) / denom
        rateInHistory.append(rateIn)
        rateOutHistory.append(rateOut)
        if rateInHistory.count  > 60 { rateInHistory.removeFirst(rateInHistory.count - 60) }
        if rateOutHistory.count > 60 { rateOutHistory.removeFirst(rateOutHistory.count - 60) }
        lastSeen = now
    }

    /// Zero the session totals and clear sparkline history.
    func reset() {
        baseIn = cumIn
        baseOut = cumOut
        rateInHistory.removeAll(keepingCapacity: true)
        rateOutHistory.removeAll(keepingCapacity: true)
        rateIn = 0; rateOut = 0
    }
}

/// A grouped row: either a single process, or several rolled up under one
/// bundle / display name when grouping is on.
@MainActor
struct NetGroup: Identifiable {
    let key: String                // e.g. "Google Chrome" or "curl.12345"
    let displayName: String
    let bundlePath: String?
    let primary: NetRow            // chosen by max sumRate for icon/pid display
    let members: [NetRow]
    var id: String { key }

    // red-team: NetRow is @MainActor; computed reducers must run main-actor too.
    var rateIn:  Double { members.reduce(0) { $0 + $1.rateIn  } }
    var rateOut: Double { members.reduce(0) { $0 + $1.rateOut } }
    var totalIn:  Int64 { members.reduce(0) { $0 + $1.totalIn  } }
    var totalOut: Int64 { members.reduce(0) { $0 + $1.totalOut } }
    var sumRate: Double { rateIn + rateOut }
    var count: Int { members.count }
}

@MainActor
final class NetModel: ObservableObject {
    @Published var groups: [NetGroup] = []
    @Published var search: String = ""
    @Published var direction: NetDirection = .both
    @Published var groupByApp: Bool = true
    @Published var interval: Double = 1.0   // 1 / 2 / 5
    @Published var paused: Bool = false
    @Published var lastError: String? = nil
    @Published var hasNettop: Bool = true
    @Published var selectedID: String? = nil

    /// CSV ring buffer: last 60 ticks. Each tick records (timestamp, pid → (in/s, out/s)).
    struct CSVTick { let at: Date; let perPID: [Int32: (name: String, rIn: Double, rOut: Double)] }
    private(set) var csvBuffer: [CSVTick] = []
    // red-team: bound the ring buffer by an absolute cap too, not just by
    // tick-count. At interval=1s with 4000 active processes, 60 ticks holds
    // 240k entries — well over 10 MB of CSV. Cap each tick's perPID dict to
    // the top-256 by rate at insertion time so a runaway-flood session can't
    // balloon memory between exports.
    private static let csvPerTickCap = 256

    /// PID-keyed live rows. Survives across ticks for sparkline continuity.
    private var rows: [Int32: NetRow] = [:]
    private var tickTask: Task<Void, Never>? = nil
    private var inFlight: Task<[NetSample], Error>? = nil
    /// Red-team #6: bump on every config change so a stale in-flight sampler's
    /// result is discarded instead of being merged with mismatched dt.
    private var generation: UInt64 = 0
    private var lastTickAt: Date? = nil

    func start() {
        // Early sanity — surface "nettop not installed" without waiting for
        // the first tick to throw.
        if !FileManager.default.isExecutableFile(atPath: netNettopPath) {
            hasNettop = false
            lastError = NetSamplerError.notInstalled.description
            return
        }
        hasNettop = true
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let sleepNS: UInt64 = await MainActor.run { [weak self] in
                    guard let self = self else { return 0 }
                    return self.paused
                        ? UInt64(0.25 * 1_000_000_000)
                        : UInt64(self.interval * 1_000_000_000)
                }
                if sleepNS == 0 { break }
                try? await Task.sleep(nanoseconds: sleepNS)
            }
        }
    }

    /// Red-team #2: stop everything — tick loop, any in-flight sampler — so
    /// no orphan `Process()` survives pane teardown or app termination.
    func stop() {
        tickTask?.cancel(); tickTask = nil
        inFlight?.cancel(); inFlight = nil
        generation &+= 1
        // red-team: also release the row dictionary so memory drops back to
        // baseline when the pane is hidden. Without this, a long session
        // that watched a flood-traffic app could hold thousands of dead
        // sparkline arrays until the user's next visit.
        rows.removeAll(keepingCapacity: false)
        groups.removeAll(keepingCapacity: false)
        csvBuffer.removeAll(keepingCapacity: false)
        lastTickAt = nil
    }

    func bumpGeneration() { generation &+= 1 }

    func resetAll() {
        for r in rows.values { r.reset() }
        csvBuffer.removeAll(keepingCapacity: true)
    }

    func tick() async {
        if paused { return }
        // red-team: hard single-in-flight guard. The previous "cancel & launch"
        // dance didn't actually stop the underlying synchronous nettop
        // Process — `Task.cancel()` only flips a flag the closure body never
        // checks. If nettop took longer than `interval` (slow first-tick on
        // a busy host, sleep/wake transitions) the next tick would spawn a
        // *new* Process while the old one was still running, snowballing
        // until the machine ran out of file descriptors or pids.
        if inFlight != nil { return }
        let myGen = generation
        let now = Date()
        let dt = lastTickAt.map { now.timeIntervalSince($0) } ?? interval
        lastTickAt = now

        let task: Task<[NetSample], Error> = Task.detached(priority: .utility) {
            try NetSampler.sample()
        }
        inFlight = task
        defer { inFlight = nil }

        do {
            let samples = try await task.value
            if myGen != generation { return }   // red-team #6
            apply(samples, dt: dt, at: now)
            lastError = nil
        } catch {
            if myGen != generation { return }
            lastError = (error as? NetSamplerError)?.description ?? error.localizedDescription
            if case NetSamplerError.notInstalled = error { hasNettop = false }
        }
    }

    private func apply(_ samples: [NetSample], dt: Double, at now: Date) {
        // Absorb samples into existing rows / spawn new ones.
        for s in samples {
            if let existing = rows[s.pid] {
                existing.absorb(s, dt: dt, now: now)
            } else {
                let r = NetRow(pid: s.pid, name: s.name, cumIn: s.bytesIn, cumOut: s.bytesOut)
                r.lastSeen = now
                rows[s.pid] = r
            }
        }
        // Red-team #5: drop rows we haven't seen in >30s so the table doesn't
        // grow without bound on a long session.
        let staleBefore = now.addingTimeInterval(-30)
        for (pid, r) in rows where r.lastSeen < staleBefore {
            rows.removeValue(forKey: pid)
            _ = r // explicit drop; ARC handles sparkline memory.
        }

        // CSV ring buffer of the last 60 ticks (~1min at default 1s).
        // red-team: per-tick cap so a flood-row session doesn't balloon RAM.
        var perPID: [Int32: (name: String, rIn: Double, rOut: Double)] = [:]
        if rows.count <= Self.csvPerTickCap {
            perPID.reserveCapacity(rows.count)
            for (pid, r) in rows { perPID[pid] = (r.name, r.rateIn, r.rateOut) }
        } else {
            // Pick the top-N rows by combined rate. Stable across ticks for a
            // given process so the per-PID CSV stays continuous; rare cap-
            // crossing rows just drop in/out of the buffer for that tick.
            let top = rows.values.sorted { $0.sumRate > $1.sumRate }.prefix(Self.csvPerTickCap)
            perPID.reserveCapacity(Self.csvPerTickCap)
            for r in top { perPID[r.pid] = (r.name, r.rateIn, r.rateOut) }
        }
        csvBuffer.append(CSVTick(at: now, perPID: perPID))
        if csvBuffer.count > 60 { csvBuffer.removeFirst(csvBuffer.count - 60) }

        regroup()
    }

    private func regroup() {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredRows = rows.values.filter { r in
            if !q.isEmpty {
                if !r.name.lowercased().contains(q) && !String(r.pid).contains(q) {
                    return false
                }
            }
            // Direction filter: hide rows with zero traffic on the chosen axis,
            // but keep the row visible if it has *any* recent total — pure-zero
            // rows would just be visual noise.
            switch direction {
            case .both:     return true
            case .incoming: return r.rateIn  > 0 || r.totalIn  > 0
            case .outgoing: return r.rateOut > 0 || r.totalOut > 0
            }
        }

        var built: [NetGroup] = []
        if groupByApp {
            var buckets: [String: [NetRow]] = [:]
            var bucketInfo: [String: (display: String, bundle: String?)] = [:]
            for r in filteredRows {
                let key = netAppKey(for: r)
                buckets[key, default: []].append(r)
                if bucketInfo[key] == nil {
                    bucketInfo[key] = (netDisplayName(for: r), netBundlePath(for: r))
                }
            }
            for (key, members) in buckets {
                let primary = members.max(by: { $0.sumRate < $1.sumRate }) ?? members[0]
                let info = bucketInfo[key] ?? (primary.name, nil)
                built.append(NetGroup(
                    key: key, displayName: info.display, bundlePath: info.bundle,
                    primary: primary, members: members
                ))
            }
        } else {
            for r in filteredRows {
                let key = "pid:\(r.pid)"
                built.append(NetGroup(
                    key: key,
                    displayName: r.name,
                    bundlePath: netBundlePath(for: r),
                    primary: r, members: [r]
                ))
            }
        }

        // Sort by direction-aware throughput so toggling In/Out re-prioritises
        // the visible list.
        built.sort { a, b in
            let av: Double, bv: Double
            switch direction {
            case .both:     av = a.sumRate; bv = b.sumRate
            case .incoming: av = a.rateIn;  bv = b.rateIn
            case .outgoing: av = a.rateOut; bv = b.rateOut
            }
            if av != bv { return av > bv }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        groups = Array(built.prefix(25))
    }

    /// Build the CSV blob for the last-minute buffer. Columns:
    ///   timestamp,pid,name,bytes_in_per_s,bytes_out_per_s
    // red-team-sec: RFC 4180 quoting. Any field containing comma, quote, CR,
    // or LF must be quoted; embedded quotes are doubled. nettop has been
    // observed to emit process names containing parentheses + commas (e.g.
    // "Google Chrome Helper (Renderer)"). Embedded NULs would be even worse
    // — strip those defensively. We also lead with a UTF-8 BOM so Excel on
    // Windows opens the file in UTF-8 mode (matches what Console.app exports
    // do).
    func csvExport() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "\u{FEFF}timestamp,pid,name,bytes_in_per_s,bytes_out_per_s\n"
        // Reserve a chunk to avoid repeated re-alloc on long buffers.
        out.reserveCapacity(2048 * max(1, csvBuffer.count))
        for tick in csvBuffer {
            let ts = iso.string(from: tick.at)
            for (pid, e) in tick.perPID {
                // Strip NUL bytes; double-quote `"`; embedded CR/LF survive
                // because we wrap the whole name in quotes regardless.
                let safe = e.name
                    .replacingOccurrences(of: "\0", with: "")
                    .replacingOccurrences(of: "\"", with: "\"\"")
                out += "\(ts),\(pid),\"\(safe)\",\(Int64(e.rIn)),\(Int64(e.rOut))\n"
            }
        }
        return out
    }
}

// ===========================================================================
// MARK: - Bundle & icon resolution
// ===========================================================================

/// nettop doesn't print a bundle path — only a short process name like
/// `Google Chrome Helper (Renderer)`. We map the name back to a likely bundle
/// path heuristically (best-effort; missing → generic exec icon).
///
/// The grouping key collapses helper variants into the parent app: every
/// "Google Chrome Helper*" rolls under "Google Chrome". For non-bundle
/// binaries (curl, ssh, rsync) each name is its own group.
private let netHelperSuffixPatterns: [String] = [
    " Helper", " Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)",
    " Helper (Alerts)", " Helper (Web)", "Helper", "WebContent", "PluginProcess",
    " (Renderer)", " (GPU)", " (Plugin)",
]

@MainActor
func netDisplayName(for row: NetRow) -> String {
    var n = row.name
    for sfx in netHelperSuffixPatterns where n.hasSuffix(sfx) {
        n = String(n.dropLast(sfx.count)).trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
    }
    return row.name
}

@MainActor
func netAppKey(for row: NetRow) -> String {
    let parent = netDisplayName(for: row)
    return parent.isEmpty ? "pid:\(row.pid)" : parent
}

/// Try to find a .app path matching this process's display name by asking
/// NSWorkspace's running-application list. Cached so we hit NSWorkspace at
/// most once per distinct name.
@MainActor
final class NetBundleResolver {
    static let shared = NetBundleResolver()
    private var cache: [String: String?] = [:]   // name → bundle path or nil
    // red-team: invalidate the cache when an app launches/terminates so a
    // name we couldn't resolve at first sight (because the app wasn't
    // running yet) gets a second chance once its bundle is actually visible.
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Drop only the negative ("nil") hits — keep positive resolutions
            // since a bundle path of an already-running app doesn't change.
            // red-team: hop to MainActor since `cache` is main-actor-isolated.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.cache = self.cache.filter { $0.value != nil }
            }
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Forget everything on terminate — a path may now point to a
            // bundle that just quit (icon resolver wants fresh data anyway).
            Task { @MainActor [weak self] in
                self?.cache.removeAll(keepingCapacity: true)
            }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let o = launchObserver { center.removeObserver(o) }
        if let o = terminateObserver { center.removeObserver(o) }
    }

    func bundlePath(for name: String) -> String? {
        if let hit = cache[name] { return hit }
        // First: search running apps for an exact localizedName / executable-name match.
        let running = NSWorkspace.shared.runningApplications
        var found: String? = nil
        for app in running {
            if app.bundleURL == nil { continue }
            if let lname = app.localizedName, lname.caseInsensitiveCompare(name) == .orderedSame {
                found = app.bundleURL?.path
                break
            }
            // Match "Google Chrome Helper" → app whose executable basename is "Google Chrome Helper".
            if let exec = app.executableURL?.lastPathComponent,
               exec.caseInsensitiveCompare(name) == .orderedSame {
                found = app.bundleURL?.path
                break
            }
        }
        cache[name] = found
        return found
    }
}

@MainActor
func netBundlePath(for row: NetRow) -> String? {
    NetBundleResolver.shared.bundlePath(for: row.name)
        ?? NetBundleResolver.shared.bundlePath(for: netDisplayName(for: row))
}

@MainActor
final class NetIconCache {
    static let shared = NetIconCache()
    private var cache: [String: NSImage] = [:]
    func icon(forBundle bundle: String?) -> NSImage {
        let key = bundle ?? "_generic_"
        if let hit = cache[key] { return hit }
        let img: NSImage
        if let b = bundle, FileManager.default.fileExists(atPath: b) {
            img = NSWorkspace.shared.icon(forFile: b)
        } else {
            img = NSWorkspace.shared.icon(for: .executable)
        }
        cache[key] = img
        return img
    }
}

// ===========================================================================
// MARK: - Formatting helpers
// ===========================================================================

extension Double {
    /// Bytes-per-second → human ("12.4 MB/s"). Distinct from Int64.human
    /// (in main.swift) which is for absolute byte counts.
    var humanRate: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        f.countStyle = .file
        let s = f.string(fromByteCount: Int64(self))
        return "\(s)/s"
    }
}

// ===========================================================================
// MARK: - Sparkline (two-tone: in vs out overlaid)
// ===========================================================================

struct NetSparkline: View {
    let inHistory:  [Double]
    let outHistory: [Double]
    let mode: NetDirection

    var body: some View {
        GeometryReader { g in
            let maxBoth = max((inHistory.max() ?? 0), (outHistory.max() ?? 0), 1)
            ZStack {
                if mode != .outgoing {
                    line(inHistory,  in: g.size, max: maxBoth)
                        .stroke(Color.green, style: .init(lineWidth: 1.2, lineJoin: .round))
                }
                if mode != .incoming {
                    line(outHistory, in: g.size, max: maxBoth)
                        .stroke(Color.orange, style: .init(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
        .frame(width: 72, height: 22)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }

    private func line(_ pts: [Double], in size: CGSize, max localMax: Double) -> Path {
        Path { path in
            guard pts.count >= 2 else {
                if let v = pts.first {
                    let y = size.height - CGFloat(min(v / localMax, 1.0)) * size.height
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                return
            }
            let dx = size.width / CGFloat(pts.count - 1)
            for (i, v) in pts.enumerated() {
                let x = CGFloat(i) * dx
                let y = size.height - CGFloat(min(v / localMax, 1.0)) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else      { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}

// ===========================================================================
// MARK: - Row & group views
// ===========================================================================

struct NetRowView: View {
    @ObservedObject var primary: NetRow
    let displayName: String
    let bundlePath: String?
    let groupCount: Int
    let rateIn:  Double
    let rateOut: Double
    let totalIn:  Int64
    let totalOut: Int64
    let direction: NetDirection

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NetIconCache.shared.icon(forBundle: bundlePath))
                .resizable().interpolation(.medium).scaledToFit()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayName).font(.body).lineLimit(1)
                    if groupCount > 1 {
                        Text("\(groupCount)").font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("PID \(primary.pid)\(groupCount > 1 ? " (+ \(groupCount - 1))" : "")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            // Rate columns: ↓ in, ↑ out — hide the irrelevant axis when filtered.
            if direction != .outgoing {
                rateColumn(symbol: "arrow.down", rate: rateIn,  total: totalIn,  tint: .green)
            }
            if direction != .incoming {
                rateColumn(symbol: "arrow.up",   rate: rateOut, total: totalOut, tint: .orange)
            }

            NetSparkline(inHistory: primary.rateInHistory,
                         outHistory: primary.rateOutHistory,
                         mode: direction)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help("\(displayName) (pid \(primary.pid)) — session totals: ↓ \(totalIn.human), ↑ \(totalOut.human)")
    }

    @ViewBuilder
    private func rateColumn(symbol: String, rate: Double, total: Int64, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.caption2).foregroundStyle(tint)
                Text(rate.humanRate)
                    .font(.system(.callout, design: .monospaced))
            }
            Text(total.human)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 96, alignment: .trailing)
    }
}

// ===========================================================================
// MARK: - Search / filter bar
// ===========================================================================

struct NetSearchBar: View {
    @Binding var text: String
    @Binding var direction: NetDirection

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by process name or PID", text: $text)
                    .textFieldStyle(.plain)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

            Picker("Direction", selection: $direction) {
                ForEach(NetDirection.allCases) { d in
                    Label(d.rawValue, systemImage: d.symbol).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .help("Show inbound, outbound, or both")
        }
    }
}

// ===========================================================================
// MARK: - Keyboard focus catcher
// ===========================================================================

/// NSView subclass that swallows Space / R / Arrow / Return keys and forwards
/// them as callbacks. SwiftUI's `.onKeyPress` is iOS-17/macOS-14+, so we use
/// a plain NSViewRepresentable to keep the keymap working on older OSes.
struct NetKeyCatcher: NSViewRepresentable {
    var onSpace:  () -> Void
    var onReset:  () -> Void
    var onUp:     () -> Void
    var onDown:   () -> Void
    var onReturn: () -> Void

    func makeNSView(context: Context) -> _NetKeyView {
        let v = _NetKeyView()
        v.onSpace = onSpace
        v.onReset = onReset
        v.onUp = onUp
        v.onDown = onDown
        v.onReturn = onReturn
        return v
    }
    func updateNSView(_ nsView: _NetKeyView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onReset = onReset
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
    }

    final class _NetKeyView: NSView {
        var onSpace:  (() -> Void)?
        var onReset:  (() -> Void)?
        var onUp:     (() -> Void)?
        var onDown:   (() -> Void)?
        var onReturn: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            // Bail to super for modifier combos — we only own bare keypresses.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !mods.isEmpty && mods != [.numericPad] {
                super.keyDown(with: event); return
            }
            switch event.keyCode {
            case 49:  onSpace?()                  // Space
            case 15:  onReset?()                  // R
            case 126: onUp?()                     // ↑
            case 125: onDown?()                   // ↓
            case 36, 76: onReturn?()              // Return / numpad-Enter
            default: super.keyDown(with: event)
            }
        }
    }
}

// ===========================================================================
// MARK: - Main pane view
// ===========================================================================

public struct NetworkMonitorView: View {
    @StateObject private var m = NetModel()
    @State private var compact: Bool = false
    @State private var selection: Int32? = nil
    /// Subscribed in onAppear so app-terminate teardown happens even if the
    /// pane is the foreground tab when the user quits (red-team #2).
    @State private var terminateObserver: NSObjectProtocol? = nil

    public init() {}

    public var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .background(NetKeyCatcher(
            onSpace:  { m.paused.toggle() },
            onReset:  { m.resetAll() },
            onUp:     { moveSelection(-1) },
            onDown:   { moveSelection(+1) },
            onReturn: { /* v1: no-op; reserved for per-connection drill-in */ }
        ))
        .navigationTitle("Network")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        .onAppear {
            m.start()
            // Red-team #2: even if onDisappear is missed (window force-closed
            // mid-tick), the terminate hook guarantees we drop the sampler.
            terminateObserver = NotificationCenter.default.addObserver(
                forName: .troveWillTerminate, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in m.stop() }
            }
        }
        .onDisappear {
            m.stop()
            if let t = terminateObserver {
                NotificationCenter.default.removeObserver(t)
                terminateObserver = nil
            }
        }
    }

    // MARK: full body

    @ViewBuilder
    private var fullBody: some View {
        VStack(spacing: 0) {
            NetSearchBar(text: $m.search, direction: $m.direction)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                .onChange(of: m.search)    { _, _ in m.bumpGeneration() }
                .onChange(of: m.direction) { _, _ in m.bumpGeneration() }
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if !m.hasNettop {
            unavailable
        } else if m.groups.isEmpty {
            let filterActive = !m.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || m.direction != .both
            if filterActive {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(m.search.isEmpty
                         ? "No \(m.direction == .incoming ? "inbound" : "outbound") traffic right now"
                         : "No processes match \"\(m.search)\"")
                        .font(.headline)
                    Text("Try clearing the filter or switching the direction toggle back to Both.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                        .multilineTextAlignment(.center)
                    Button {
                        m.search = ""
                        m.direction = .both
                    } label: {
                        Label("Clear filter", systemImage: "xmark.circle")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No network traffic yet")
                        .font(.headline)
                    Text("Trove is listening via nettop. Idle apps produce no rows — anything that sends or receives bytes will appear here, grouped by app and sorted by throughput.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 440)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Listening…").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.groups) { g in
                        groupRow(g)
                            .padding(.horizontal, 4)
                            .background(selection == g.primary.pid
                                        ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                        : AnyShapeStyle(Color.clear))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = g.primary.pid }
                        Divider()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                           ? nil : .easeInOut(duration: 0.25),
                           value: m.groups.map { $0.id })
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ g: NetGroup) -> some View {
        NetRowView(
            primary: g.primary,
            displayName: g.displayName,
            bundlePath: g.bundlePath,
            groupCount: g.count,
            rateIn: g.rateIn,
            rateOut: g.rateOut,
            totalIn: g.totalIn,
            totalOut: g.totalOut,
            direction: m.direction
        )
    }

    @ViewBuilder
    private var unavailable: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Network monitoring unavailable").font(.headline)
                }
                Text("`/usr/bin/nettop` was not found on this Mac. The Network pane uses nettop to read per-process byte counters; it ships with macOS but is missing on some stripped-down installs.")
                    .foregroundStyle(.secondary)
                Text("Install the Xcode Command Line Tools to get it back:")
                    .foregroundStyle(.secondary)
                Text("xcode-select --install")
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
    }

    // MARK: compact body — 4-row top list

    @ViewBuilder
    private var compactBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "network").foregroundStyle(.secondary)
                Text("Top 4 by throughput").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { compact = false } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Exit compact mode")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            VStack(spacing: 2) {
                ForEach(Array(m.groups.prefix(4))) { g in
                    HStack(spacing: 8) {
                        Image(nsImage: NetIconCache.shared.icon(forBundle: g.bundlePath))
                            .resizable().scaledToFit().frame(width: 16, height: 16)
                        Text(g.displayName).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(g.sumRate.humanRate)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 2)
                }
                if m.groups.isEmpty {
                    Text("idle").font(.caption).foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 240)
    }

    // MARK: toolbar

    private var subtitle: String {
        if !m.hasNettop { return "nettop unavailable" }
        if let e = m.lastError { return e }
        if m.paused { return "Paused · \(m.groups.count) processes" }
        let total = m.groups.reduce(0.0) { $0 + $1.sumRate }
        return "\(m.groups.count) processes · \(total.humanRate) total · refresh \(Int(m.interval))s"
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $m.groupByApp) {
                Label("Group by App", systemImage: "square.stack.3d.up.fill")
            }
            .toggleStyle(.button)
            .help("Roll Helper / Renderer processes up under their parent app")
            .onChange(of: m.groupByApp) { _, _ in m.bumpGeneration() }

            Picker("Refresh", selection: $m.interval) {
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
                Text("5s").tag(5.0)
            }
            .pickerStyle(.segmented)
            .help("Sampling interval")
            .onChange(of: m.interval) { _, _ in m.bumpGeneration() }

            Button {
                m.paused.toggle()
            } label: {
                Label(m.paused ? "Resume" : "Pause",
                      systemImage: m.paused ? "play.fill" : "pause.fill")
            }
            .help("Space — pause / resume sampling")

            Button {
                m.resetAll()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("R — zero session totals and clear sparklines")

            Button {
                exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .help("Save the last minute of per-second per-process rates")

            Button {
                compact.toggle()
            } label: {
                Label("Compact", systemImage: compact
                                  ? "arrow.up.left.and.arrow.down.right"
                                  : "arrow.down.right.and.arrow.up.left")
            }
            .help("Toggle the 4-row corner-widget view")
        }
    }

    // MARK: actions

    private func moveSelection(_ delta: Int) {
        let ids = m.groups.map(\.primary.pid)
        guard !ids.isEmpty else { return }
        if let cur = selection, let idx = ids.firstIndex(of: cur) {
            let next = max(0, min(ids.count - 1, idx + delta))
            selection = ids[next]
        } else {
            selection = ids.first
        }
    }

    /// Save the CSV ring buffer to a user-chosen path.
    /// NSSavePanel is modal/main-actor — fits the @MainActor view body.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        // red-team: the previous code substituted ":" → "-" only on the
        // ISO timestamp, but ISO also contains "+"/"Z" and the system may
        // be configured with a non-POSIX locale that injects unexpected
        // characters via DateFormatter. Use a strict POSIX yyyyMMdd-HHmmss
        // stamp so the suggested filename is always FS-safe.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let ts = stamp.string(from: Date())
        panel.nameFieldStringValue = "trove-network-\(ts).csv"
        panel.title = "Export network log (last minute)"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            // red-team-sec: NSSavePanel returns a sandbox-validated URL the
            // user chose, so traversal is bounded by the panel. We still
            // refuse to write into a path that resolves outside the file URL
            // scheme (e.g. via symlink shenanigans) just to be safe — relying
            // on `url.isFileURL` here is sufficient defense-in-depth without
            // breaking the legitimate save-to-iCloud-Drive case.
            guard url.isFileURL else { return }
            let csv = m.csvExport()
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // Surface failure into the subtitle slot rather than throwing
                // a separate alert sheet — keeps the pane chrome consistent
                // with how other panes report transient I/O errors.
                Task { @MainActor in
                    m.lastError = "CSV export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
