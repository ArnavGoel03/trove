// Trove — Process Inspector pane.
//   • Live top-N processes by CPU/RAM, refreshed on a user-pickable interval.
//   • Smart kill: SIGTERM → wait 2s → offer SIGKILL with confirm + admin escalation.
//   • Group by parent app, per-row sparkline of last 60 samples, search filter.
//   • Read-only side never needs admin; only kill -9 on root-owned procs prompts.
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Foundation
import Darwin   // kill(2), SIGTERM, SIGKILL, EPERM, ESRCH, errno

// ===========================================================================
// MARK: - Sampling
// ===========================================================================

/// One row out of `ps`. `comm` is the executable path / short name; `args` is
/// the full command line (used for app-bundle detection and tooltips).
struct ProcSample: Hashable {
    let pid: Int32
    let ppid: Int32
    let cpu: Double      // pcpu, 0..(N*100) on multicore
    let rssKB: Int64     // resident set size in KB
    let comm: String     // executable path (or short name when unknown)
    let args: String     // full argv joined

    var rssBytes: Int64 { rssKB * 1024 }
}

enum ProcSampler {
    /// Shell out to `ps` and parse. `-ww` disables column truncation (red-team #1)
    /// so we get the full argv even for processes with absurdly long flags.
    /// Returns an empty array on any parse / process failure rather than throwing —
    /// the UI prefers a stale list to a crash.
    static func sample() -> [ProcSample] {
        let p = Process()
        p.launchPath = "/bin/ps"
        // -A: every process. -ww: no truncation. -o: ordered columns.
        // pcpu/rss are the columns we care about; comm/args are last so any
        // whitespace inside args doesn't bleed into adjacent fields.
        p.arguments = ["-Awwo", "pid=,ppid=,pcpu=,rss=,comm=,args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExitOffMain()
        guard let s = String(data: data, encoding: .utf8) else { return [] }

        let self_pid = ProcessInfo.processInfo.processIdentifier
        var rows: [ProcSample] = []
        rows.reserveCapacity(512)
        // red-team: a process can have literal '\n' bytes in its argv (rare
        // but legal — Postgres workers sometimes do this for the title trick).
        // Splitting the whole ps output on '\n' chops such a row in two; the
        // tail half lacks numeric leading fields, so the Int32(pidS) guard
        // below filters it out. We rely on that fail-closed behaviour rather
        // than trying to reassemble multi-line records.
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            // First 4 fields are numeric, then `comm` (one token, possibly a
            // path with spaces? rare — ps emits the basename or full path
            // depending on launch), then `args` (everything else).
            // Strategy: split on whitespace lazily to peel off the 4 numerics,
            // then take the next single token as `comm`, then the rest as `args`.
            var idx = line.startIndex
            func nextField() -> Substring? {
                while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
                guard idx < line.endIndex else { return nil }
                let start = idx
                while idx < line.endIndex, line[idx] != " " { idx = line.index(after: idx) }
                return line[start..<idx]
            }
            guard let pidS = nextField(),
                  let ppidS = nextField(),
                  let cpuS = nextField(),
                  let rssS = nextField(),
                  let commS = nextField()
            else { continue }
            // Remainder is args (skip leading spaces).
            while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
            let argsS = line[idx..<line.endIndex]

            guard let pid = Int32(pidS), pid > 0, pid != Int32(self_pid),
                  let ppid = Int32(ppidS),
                  let cpu = Double(cpuS),
                  let rss = Int64(rssS) else { continue }
            // red-team: zombies show up with rss=0 and a comm of "(name)".
            // They're un-killable (already dead, waiting for parent reap)
            // and have no meaningful CPU/RAM to chart. Skip — listing them
            // would just clutter the top-20 with rows the user can't act on.
            let commStr = String(commS)
            if commStr.hasPrefix("(") && commStr.hasSuffix(")") && rss == 0 { continue }
            rows.append(ProcSample(
                pid: pid, ppid: ppid, cpu: cpu, rssKB: rss,
                comm: commStr, args: String(argsS)
            ))
        }
        return rows
    }
}

// ===========================================================================
// MARK: - Model
// ===========================================================================

/// A live row in the table. Identity is by PID — same PID across ticks updates
/// the same row (which keeps SwiftUI's diffing happy and lets sparklines accrete).
final class ProcRow: Identifiable, ObservableObject {
    let pid: Int32
    @Published var ppid: Int32
    @Published var comm: String
    @Published var args: String
    @Published var cpu: Double = 0
    @Published var rssBytes: Int64 = 0
    @Published var cpuHistory: [Double] = []   // capped at 60
    @Published var ramHistory: [Double] = []   // MB, capped at 60

    /// Cached blacklist result, invalidated when comm changes. Plain stored
    /// property (not @Published) — UI doesn't need to redraw on a cache fill.
    fileprivate var _blacklistCache: (commVersion: String, value: Bool)? = nil

    var id: Int32 { pid }

    init(_ s: ProcSample) {
        self.pid = s.pid
        self.ppid = s.ppid
        self.comm = s.comm
        self.args = s.args
        absorb(s)
    }

    /// Merge a new sample into this row and append to the circular buffers.
    /// Red-team #5: hard cap at 60 entries — `cpuHistory.append` then drop
    /// the head if oversized, so memory is bounded even for long sessions.
    func absorb(_ s: ProcSample) {
        ppid = s.ppid
        if comm != s.comm { _blacklistCache = nil }
        comm = s.comm
        args = s.args
        cpu = s.cpu
        rssBytes = s.rssBytes
        cpuHistory.append(s.cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
        let mb = Double(s.rssBytes) / 1_048_576.0
        ramHistory.append(mb)
        if ramHistory.count > 60 { ramHistory.removeFirst(ramHistory.count - 60) }
    }
}

/// A visual group: either a single process or an app cluster (parent + children
/// rolled up under one disclosure row). The "primary" is the row whose icon /
/// name we display; children are everything sharing the same bundle / parent.
struct ProcGroup: Identifiable {
    let key: String          // bundle path or comm path
    let primary: ProcRow
    let children: [ProcRow]  // does not include `primary`

    var id: String { key }
    var totalCPU: Double { primary.cpu + children.reduce(0) { $0 + $1.cpu } }
    var totalRSS: Int64 { primary.rssBytes + children.reduce(0) { $0 + $1.rssBytes } }
    var count: Int { 1 + children.count }
}

/// PIDs we refuse to kill from the UI. `launchd` (1) and `kernel_task` (0) are
/// the obvious ones — killing launchd reboots the box, kernel_task is unkillable
/// anyway and the attempt just logs noise. WindowServer / loginwindow are also
/// foot-guns. Red-team #3.
private let procKillBlacklistPIDs: Set<Int32> = [0, 1]
private let procKillBlacklistNames: Set<String> = [
    "kernel_task", "launchd", "WindowServer", "loginwindow",
    "logind", "coreaudiod", "systemstats", "powerd",
]

func procIsBlacklisted(_ row: ProcRow) -> Bool {
    // red-team: this is called from inside ProcRowView.body for every visible
    // row on every redraw. Cache the lookup on the row so we only do the
    // string work when comm actually changes.
    if let cached = row._blacklistCache, cached.commVersion == row.comm {
        return cached.value
    }
    let computed: Bool = {
        if procKillBlacklistPIDs.contains(row.pid) { return true }
        let base = (row.comm as NSString).lastPathComponent
        return procKillBlacklistNames.contains(base)
    }()
    row._blacklistCache = (row.comm, computed)
    return computed
}

/// Sort key for the live table. Tie-break by PID so equal-CPU rows don't
/// shuffle on every tick (red-team #6).
enum ProcSortKey: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case ram = "RAM"
    var id: String { rawValue }
}

@MainActor
final class ProcModel: ObservableObject {
    @Published var groups: [ProcGroup] = []
    @Published var search: String = "" {
        // red-team: previously typing into the filter only narrowed the table
        // on the next sample tick (up to 5s with 5s interval). Regroup
        // immediately from the existing row cache so filtering is instant.
        didSet { if oldValue != search { regroup() } }
    }
    @Published var sortKey: ProcSortKey = .cpu {
        // red-team: same issue for sort flips — sort change shouldn't wait
        // for the next sample to take visible effect.
        didSet { if oldValue != sortKey { regroup() } }
    }
    @Published var interval: Double = 1.0      // seconds; 1 / 2 / 5
    @Published var paused: Bool = false
    @Published var lastError: String? = nil

    /// PID → row. Survives across ticks so sparkline histories accrue.
    private var rows: [Int32: ProcRow] = [:]
    private var sampleTask: Task<[ProcSample], Never>? = nil
    private var tickTask: Task<Void, Never>? = nil
    /// Atomic-ish: only mutated on @MainActor, so reads from `tickTask` see
    /// the latest. Red-team #4: if user pauses mid-flight, we check this
    /// after the detached sample returns and discard the result if stale.
    private var generation: UInt64 = 0

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Read interval on the main actor; if paused, sleep a short
                // beat then re-check so resume is responsive.
                let sleepNS: UInt64 = await MainActor.run { [weak self] in
                    guard let self = self else { return UInt64(0) }
                    return self.paused
                        ? UInt64(0.25 * 1_000_000_000)
                        : UInt64(self.interval * 1_000_000_000)
                }
                if sleepNS == 0 { break }
                try? await Task.sleep(nanoseconds: sleepNS)
            }
        }
    }

    func stop() {
        tickTask?.cancel(); tickTask = nil
        sampleTask?.cancel(); sampleTask = nil
        generation &+= 1
    }

    /// One sampling pass: shell out off-main, merge into `rows`, regroup.
    func tick() async {
        if paused { return }
        let myGen = generation
        sampleTask?.cancel()
        let task = Task.detached(priority: .utility) { ProcSampler.sample() }
        sampleTask = task
        let samples = await task.value
        // Red-team #4: if generation changed (pause/resume/sort flip),
        // discard this sample so the user doesn't see a "blip".
        if myGen != generation { return }
        apply(samples)
    }

    private func apply(_ samples: [ProcSample]) {
        // Drop rows whose PID disappeared this tick — frees their sparkline
        // memory immediately (red-team #5).
        let alive = Set(samples.map(\.pid))
        for pid in rows.keys where !alive.contains(pid) { rows.removeValue(forKey: pid) }

        for s in samples {
            if let existing = rows[s.pid] {
                existing.absorb(s)
            } else {
                rows[s.pid] = ProcRow(s)
            }
        }
        regroup()
    }

    /// Build groups by parent app (or PPID fallback). The "primary" row in a
    /// group is the entry whose `comm` matches the .app bundle name; if none
    /// match, we pick the PPID-shared parent itself, otherwise the
    /// highest-CPU member.
    private func regroup() {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [ProcRow] = rows.values.filter { row in
            if q.isEmpty { return true }
            return row.comm.lowercased().contains(q)
                || row.args.lowercased().contains(q)
                || String(row.pid).contains(q)
        }

        // Bucket by "app key": the .app bundle path if we can find one in
        // `comm` or `args`; otherwise the comm path itself (so non-bundle
        // CLIs still group their own helper children by ppid below).
        var byKey: [String: [ProcRow]] = [:]
        for r in filtered {
            byKey[procAppKey(r), default: []].append(r)
        }

        // For each bucket, pick a primary deterministically: prefer the row
        // whose pid == bucket's min-ppid'd entry (the bundle's "main"
        // process), else the highest-CPU row, tiebreak by PID asc.
        var built: [ProcGroup] = []
        built.reserveCapacity(byKey.count)
        for (key, members) in byKey {
            let primary = members.min(by: procPrimaryOrder) ?? members[0]
            let children = members.filter { $0.pid != primary.pid }
                .sorted { ($0.cpu, $1.pid) > ($1.cpu, $0.pid) }
            built.append(ProcGroup(key: key, primary: primary, children: children))
        }

        // Top-20 by chosen metric. Red-team #6: secondary sort by PID asc so
        // ties don't jitter row order between ticks.
        built.sort { a, b in
            switch sortKey {
            case .cpu:
                if a.totalCPU != b.totalCPU { return a.totalCPU > b.totalCPU }
                return a.primary.pid < b.primary.pid
            case .ram:
                if a.totalRSS != b.totalRSS { return a.totalRSS > b.totalRSS }
                return a.primary.pid < b.primary.pid
            }
        }
        groups = Array(built.prefix(20))
    }

    /// Deterministic ordering for "which row is the bucket's primary".
    /// Lowest PID typically wins (the bundle's main process is usually older
    /// and thus has the lower PID); CPU is a soft tiebreak so a busy helper
    /// can still be the visible row in degenerate cases.
    private func procPrimaryOrder(_ a: ProcRow, _ b: ProcRow) -> Bool {
        // We want min() to surface the "best primary". Best = the one
        // whose comm matches the .app bundle's executable. If both match
        // (or neither), prefer lower PID.
        let ak = procIsBundleMain(a)
        let bk = procIsBundleMain(b)
        if ak != bk { return ak && !bk }
        return a.pid < b.pid
    }
}

// ===========================================================================
// MARK: - App icon & bundle resolution
// ===========================================================================

/// Returns the .app bundle path embedded in a `comm`/`args` path, if any.
/// Example: "/Applications/Foo.app/Contents/MacOS/Foo" → "/Applications/Foo.app".
func procBundlePath(for row: ProcRow) -> String? {
    let candidates = [row.comm, row.args.split(separator: " ").first.map(String.init) ?? ""]
    for c in candidates where !c.isEmpty {
        if let r = c.range(of: ".app/") {
            return String(c[..<r.upperBound].dropLast()) // drop trailing slash for cleanliness
        }
        if c.hasSuffix(".app") { return c }
    }
    return nil
}

/// Key used to bucket rows into app-groups.
func procAppKey(_ row: ProcRow) -> String {
    if let bundle = procBundlePath(for: row) { return bundle }
    // For non-bundle binaries (daemons, CLI tools), each unique comm is its
    // own group — we don't want every shell process to collapse into "/bin/zsh".
    return row.comm.isEmpty ? "pid:\(row.pid)" : row.comm
}

/// True iff this row looks like the main executable of its bundle (as opposed
/// to a "Helper" child). Heuristic: comm path is `…/Contents/MacOS/<X>` and
/// the bundle basename matches `<X>.app` (case-insensitive).
func procIsBundleMain(_ row: ProcRow) -> Bool {
    guard let bundle = procBundlePath(for: row) else { return false }
    let bundleName = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    let commName = (row.comm as NSString).lastPathComponent
    return bundleName.caseInsensitiveCompare(commName) == .orderedSame
}

/// Display name for the group's header row.
func procDisplayName(_ row: ProcRow) -> String {
    if let bundle = procBundlePath(for: row) {
        let n = (bundle as NSString).lastPathComponent
        if n.hasSuffix(".app") { return String(n.dropLast(4)) }
        return n
    }
    let base = (row.comm as NSString).lastPathComponent
    return base.isEmpty ? "pid \(row.pid)" : base
}

/// Tiny LRU-ish cache so we don't hit NSWorkspace 200 times per tick.
@MainActor
final class ProcIconCache {
    static let shared = ProcIconCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    func icon(forBundle bundle: String?) -> NSImage {
        let key = (bundle ?? "_generic_") as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img: NSImage
        if let b = bundle, FileManager.default.fileExists(atPath: b) {
            img = NSWorkspace.shared.icon(forFile: b)
        } else {
            img = NSWorkspace.shared.icon(for: .executable)
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

// ===========================================================================
// MARK: - Kill (with smart escalation)
// ===========================================================================

enum ProcKillResult {
    case sent                  // SIGTERM delivered, will recheck
    case alreadyGone           // ESRCH on kill(2)
    case permissionDenied      // EPERM — need admin
    case otherError(String)
}

/// Send a signal to a PID, returning a structured result.
/// Red-team #2: ESRCH (no such process) becomes `.alreadyGone` instead of an
/// error popup — the process exited between sampling and the click. EPERM
/// (kernel says no) becomes `.permissionDenied` so the UI can prompt for an
/// admin escalation rather than failing silently.
func procSendSignal(_ pid: Int32, _ sig: Int32) -> ProcKillResult {
    // red-team: capture errno on the same line as the syscall so the Swift
    // bridge can't slip an ObjC runtime call between them and clobber it.
    let r = kill(pid, sig); let err = errno
    if r == 0 { return .sent }
    switch err {
    case ESRCH: return .alreadyGone
    case EPERM: return .permissionDenied
    default:
        // red-team: strerror() returns a pointer to a non-thread-safe static
        // buffer; another thread could overwrite it before we copy. Use the
        // thread-safe strerror_r variant.
        var buf = [CChar](repeating: 0, count: 256)
        _ = buf.withUnsafeMutableBufferPointer { strerror_r(err, $0.baseAddress, $0.count) }
        let msg = String(cString: buf)
        return .otherError(msg)
    }
}

/// Wait up to `timeout` seconds for a PID to disappear. Polls via `kill(pid, 0)`
/// which is a noop that returns ESRCH once the process is gone.
func procWaitForExit(_ pid: Int32, timeout: TimeInterval) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        // red-team: snap errno immediately after kill() so the !=0 comparison
        // can't accidentally trigger code (e.g. printf during debug) that
        // resets it before we read it.
        let r = kill(pid, 0); let e = errno
        if r != 0 && e == ESRCH { return true }
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }
    return false
}

/// Escalate to `kill -9` via `osascript` admin prompt. This is the only
/// codepath that surfaces a TouchID / password dialog — and only when the
/// caller already chose to force-kill a process that ignored SIGTERM and that
/// our uid can't signal.
func procAdminKill(_ pid: Int32) async -> ProcKillResult {
    // red-team: create the Process inside the detached task. The old code
    // built `p` on the caller's actor then captured it across an isolation
    // boundary — Process isn't Sendable and that's a Swift 6 hard error /
    // Swift 5 warning. Building inside the task keeps the reference local.
    // Also handles "user cancelled the password prompt" gracefully — osascript
    // exits 1 and stderr contains "(-128)".
    return await Task.detached(priority: .userInitiated) { () -> ProcKillResult in
        // red-team: prior prompt was bare "osascript wants to run a command"
        // with no rationale — easy for a user to authenticate reflexively.
        // The `with prompt` clause tells macOS to show a real explanation in
        // the TouchID/password dialog so the user knows what they're approving.
        let prompt = "Trove needs administrator privileges to force-kill PID \(pid) (a process you don't own)."
        // red-team: escape any embedded quotes in the prompt before splicing
        // into the AppleScript literal. `pid` is Int32 so it has no special
        // chars, but treat all string interpolation into AS source uniformly.
        let safePrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"/bin/kill -9 \(pid)\" with prompt \"\(safePrompt)\" with administrator privileges"
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return .otherError(error.localizedDescription) }
        p.waitUntilExitOffMain()
        if p.terminationStatus == 0 { return .sent }
        let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                       encoding: .utf8) ?? ""
        if e.contains("(-128)") { return .otherError("Cancelled") }
        let trimmed = e.trimmingCharacters(in: .whitespacesAndNewlines)
        return .otherError(trimmed.isEmpty ? "Admin kill failed (exit \(p.terminationStatus))" : trimmed)
    }.value
}

// ===========================================================================
// MARK: - Sparkline view
// ===========================================================================

struct ProcSparkline: View {
    let values: [Double]
    let tint: Color
    /// If nil, auto-scale to local max. Useful to pin CPU to (Ncores * 100)
    /// so single-core spikes don't look like everything is on fire.
    let maxValue: Double?

    var body: some View {
        GeometryReader { g in
            let pts = values
            let n = max(pts.count, 2)
            let localMax = max(maxValue ?? (pts.max() ?? 1), 0.0001)
            Path { path in
                guard !pts.isEmpty else { return }
                let w = g.size.width
                let h = g.size.height
                let dx = w / CGFloat(n - 1)
                for (i, v) in pts.enumerated() {
                    let x = CGFloat(i) * dx
                    let y = h - CGFloat(min(v / localMax, 1.0)) * h
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else      { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(width: 56, height: 18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }
}

// ===========================================================================
// MARK: - Row views
// ===========================================================================

struct ProcRowView: View {
    @ObservedObject var row: ProcRow
    let isGroupHeader: Bool
    let groupCount: Int      // 1 for solo, >1 for header of a cluster
    let totalCPU: Double
    let totalRSS: Int64
    let killer: (ProcRow) -> Void

    private var blacklisted: Bool { procIsBlacklisted(row) }

    var body: some View {
        HStack(spacing: 10) {
            let bundle = procBundlePath(for: row)
            Image(nsImage: ProcIconCache.shared.icon(forBundle: bundle))
                .resizable().interpolation(.medium).scaledToFit()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(procDisplayName(row)).font(.body)
                    if isGroupHeader && groupCount > 1 {
                        Text("\(groupCount)").font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("PID \(row.pid)\(isGroupHeader && groupCount > 1 ? " (+ \(groupCount - 1) helpers)" : "")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            // CPU column: number + sparkline.
            HStack(spacing: 6) {
                Text(String(format: "%5.1f%%", totalCPU))
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(totalCPU > 50 ? Color.orange : .primary)
                ProcSparkline(values: row.cpuHistory,
                              tint: totalCPU > 50 ? .orange : .blue,
                              maxValue: nil)
            }

            // RAM column: MB + sparkline.
            HStack(spacing: 6) {
                Text(totalRSS.human)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 78, alignment: .trailing)
                ProcSparkline(values: row.ramHistory, tint: .purple, maxValue: nil)
            }

            Button(role: .destructive) {
                killer(row)
            } label: {
                Image(systemName: "xmark.octagon.fill")
            }
            .buttonStyle(.borderless)
            .disabled(blacklisted)
            .help(blacklisted
                  ? "System process — refusing to kill"
                  : "Send SIGTERM to \(row.pid). Escalates to SIGKILL if it lingers.")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(row.args.isEmpty ? row.comm : row.args)
    }
}

// ===========================================================================
// MARK: - Main view
// ===========================================================================

public struct ProcView: View {
    @StateObject private var m = ProcModel()
    @State private var expanded: Set<String> = []
    @State private var pendingKill: ProcKillTarget? = nil
    @State private var killStatus: String? = nil
    /// Red-team #7: don't sample when this pane isn't visible.
    @State private var visible = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ProcSearchBar(text: $m.search, sortKey: $m.sortKey)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            Divider()
            list
        }
        .navigationTitle("Processes")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        .onAppear {
            visible = true
            m.start()
        }
        .onDisappear {
            visible = false
            m.stop()
        }
        .alert(item: $pendingKill) { tgt in
            Alert(
                title: Text("Force kill \(procDisplayName(tgt.row))?"),
                message: Text("It didn't exit after SIGTERM. Send SIGKILL (kill -9, PID \(tgt.row.pid))?\(tgt.needsAdmin ? "\n\nThis process is owned by another user; macOS will prompt for an admin password." : "")"),
                primaryButton: .destructive(Text("Force Kill")) {
                    Task { await escalate(tgt) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var subtitle: String {
        if let e = m.lastError { return e }
        if let s = killStatus { return s }
        if m.paused { return "Paused · \(m.groups.count) groups" }
        return "Top \(m.groups.count) by \(m.sortKey.rawValue) · refresh \(Int(m.interval))s"
    }

    @ViewBuilder
    private var list: some View {
        if m.groups.isEmpty {
            if !m.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No processes match \"\(m.search)\"")
                        .font(.headline)
                    Text("Try a PID, a partial app name, or a launch-arg fragment. Clear the filter to see the top hogs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                        .multilineTextAlignment(.center)
                    Button {
                        m.search = ""
                    } label: {
                        Label("Clear filter", systemImage: "xmark.circle")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Sampling processes…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.groups) { g in
                        groupView(g)
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // Smooth position changes — red-team for the "jumpy reorder"
                // problem. The animation observes the list-of-PIDs only, so
                // value updates (CPU bouncing) don't trigger position anims.
                // red-team: also honor Reduce Motion — animated reordering
                // can be disorienting and the list updates every tick.
                .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                           ? nil : .easeInOut(duration: 0.25),
                           value: m.groups.map { $0.id })
            }
        }
    }

    @ViewBuilder
    private func groupView(_ g: ProcGroup) -> some View {
        let isOpen = expanded.contains(g.id)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if !g.children.isEmpty {
                    Button {
                        if isOpen { expanded.remove(g.id) } else { expanded.insert(g.id) }
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }
                ProcRowView(
                    row: g.primary,
                    isGroupHeader: true,
                    groupCount: g.count,
                    totalCPU: g.totalCPU,
                    totalRSS: g.totalRSS,
                    killer: { row in Task { await initiateKill(row) } }
                )
            }
            if isOpen {
                ForEach(g.children) { child in
                    HStack(spacing: 4) {
                        Spacer().frame(width: 28)
                        ProcRowView(
                            row: child,
                            isGroupHeader: false,
                            groupCount: 1,
                            totalCPU: child.cpu,
                            totalRSS: child.rssBytes,
                            killer: { row in Task { await initiateKill(row) } }
                        )
                    }
                    .background(.quaternary.opacity(0.25))
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Refresh", selection: $m.interval) {
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
                Text("5s").tag(5.0)
            }
            .pickerStyle(.segmented)
            .help("Sampling interval")

            Button {
                m.paused.toggle()
            } label: {
                Label(m.paused ? "Resume" : "Pause",
                      systemImage: m.paused ? "play.fill" : "pause.fill")
            }
            .help(m.paused ? "Resume live updates" : "Pause sampling")
        }
    }

    // MARK: kill flow

    @MainActor
    private func initiateKill(_ row: ProcRow) async {
        guard !procIsBlacklisted(row) else {
            killStatus = "Refused: \(procDisplayName(row)) is a protected system process."
            return
        }
        let name = procDisplayName(row)
        killStatus = "Sending SIGTERM to \(name) (\(row.pid))…"
        let res = procSendSignal(row.pid, SIGTERM)
        switch res {
        case .alreadyGone:
            killStatus = "\(name) (\(row.pid)) already exited."
            return
        case .permissionDenied:
            // Skip SIGTERM and offer the admin-escalated SIGKILL directly.
            pendingKill = ProcKillTarget(row: row, needsAdmin: true)
            return
        case .otherError(let e):
            killStatus = "kill \(row.pid): \(e)"
            return
        case .sent:
            break
        }
        // Wait up to 2s for graceful exit.
        let gone = await procWaitForExit(row.pid, timeout: 2.0)
        if gone {
            killStatus = "\(name) exited."
        } else {
            pendingKill = ProcKillTarget(row: row, needsAdmin: false)
        }
    }

    @MainActor
    private func escalate(_ tgt: ProcKillTarget) async {
        let name = procDisplayName(tgt.row)
        let res: ProcKillResult
        if tgt.needsAdmin {
            res = await procAdminKill(tgt.row.pid)
        } else {
            res = procSendSignal(tgt.row.pid, SIGKILL)
        }
        switch res {
        case .sent:
            // Brief recheck — SIGKILL is uncatchable, should be ~immediate.
            let gone = await procWaitForExit(tgt.row.pid, timeout: 1.0)
            killStatus = gone ? "\(name) force-killed." : "Sent SIGKILL to \(name); awaiting exit."
        case .alreadyGone:
            killStatus = "\(name) already exited."
        case .permissionDenied:
            // Shouldn't happen if we already routed to admin; surface clearly.
            killStatus = "Permission denied. Retry with administrator privileges."
            pendingKill = ProcKillTarget(row: tgt.row, needsAdmin: true)
        case .otherError(let e):
            killStatus = "kill -9 \(tgt.row.pid): \(e)"
        }
    }
}

// Identifiable wrapper so we can drive `.alert(item:)`. Carries the
// "needs admin" flag so the message text changes for cross-user kills.
struct ProcKillTarget: Identifiable {
    let row: ProcRow
    let needsAdmin: Bool
    var id: Int32 { row.pid }
}

// ===========================================================================
// MARK: - Search bar
// ===========================================================================

struct ProcSearchBar: View {
    @Binding var text: String
    @Binding var sortKey: ProcSortKey

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name, args, or PID", text: $text)
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

            Picker("Sort", selection: $sortKey) {
                ForEach(ProcSortKey.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Sort top-20 by CPU% or RAM (RSS)")
        }
    }
}
