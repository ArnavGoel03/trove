// Trove — Disk Speed pane.
//   • Sequential + random read/write benchmark for any chosen volume.
//   • F_NOCACHE bypass so we measure the device, not the page cache.
//   • Multi-volume queue + median-of-3 + CSV export.
//   • Power-user replacement for Blackmagic Disk Speed Test.
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Foundation
import Darwin
import UniformTypeIdentifiers
import IOKit.pwr_mgt

// ===========================================================================
// MARK: - Constants + helpers
// ===========================================================================

/// One MiB (binary, for IO math). All MB/s reporting uses MiB/s — it's what
/// engineers expect from a disk benchmark and matches `dd`/`fio` conventions.
private let DiskSpeedMiB: Int = 1024 * 1024

/// 4 KiB random IO block size — what SSD spec sheets quote.
private let DiskSpeedRandBlock: Int = 4096

/// Number of 4 KiB random ops per pass. 4096 ops × 4 KiB = 16 MiB of random IO,
/// enough to dwarf any device on-controller buffer without taking forever.
private let DiskSpeedRandOps: Int = 4096

/// Median-of-3: enough to dodge first-run SLC cache without making the user wait.
private let DiskSpeedRepeats: Int = 3

/// Default blob size — 1 GiB. Configurable 100 MiB ... 8 GiB.
private let DiskSpeedDefaultBlobMiB: Int = 1024
private let DiskSpeedMinBlobMiB: Int = 100
private let DiskSpeedMaxBlobMiB: Int = 8 * 1024

// MiB/s as a Double, given byte count + elapsed nanoseconds. Never use Date()
// for this — NTP drift mid-test would skew. (red-team #7)
private func diskSpeedMiBPerSec(bytes: Int64, nanos: UInt64) -> Double {
    guard nanos > 0 else { return 0 }
    let seconds = Double(nanos) / 1_000_000_000.0
    return (Double(bytes) / Double(DiskSpeedMiB)) / seconds
}

private enum DiskSpeedError: Error, LocalizedError {
    case openFailed(String)
    case nocacheFailed(Int32)
    case writeFailed(String)
    case readFailed(String)
    case diskFull
    case volumeDisconnected
    case permissionDenied
    case readOnly
    case cancelled
    case insufficientSpace(freeMiB: Int64, requestedMiB: Int64)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s):       return "Open failed: \(s)"
        case .nocacheFailed(let e):    return "Couldn't configure the test file (system error \(e)) — try again."
        case .writeFailed(let s):      return "Write failed: \(s)"
        case .readFailed(let s):       return "Read failed: \(s)"
        case .diskFull:                return "Disk full — wrote less than requested"
        case .volumeDisconnected:      return "Volume disconnected"
        case .permissionDenied:        return "Permission denied"
        case .readOnly:                return "Volume is read-only"
        case .cancelled:               return "Cancelled"
        case .insufficientSpace(let f, let r):
            return "Need ≤50% of free space — \(f) MB free, test file is \(r) MB"
        }
    }
}

// ===========================================================================
// MARK: - Volume listing
// ===========================================================================

struct DiskSpeedVolume: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let totalMiB: Int64
    let freeMiB: Int64
    let isRemovable: Bool
    let isReadOnly: Bool

    var path: String { url.path }
    var displayName: String {
        if name.isEmpty { return url.path }
        return "\(name) — \(url.path)"
    }

    static func == (lhs: DiskSpeedVolume, rhs: DiskSpeedVolume) -> Bool {
        lhs.url.path == rhs.url.path
    }
    func hash(into hasher: inout Hasher) { hasher.combine(url.path) }
}

enum DiskSpeedVolumes {
    /// Enumerate mounted volumes. Always includes `/` as a fallback. Pulls
    /// removable/read-only/free-space flags via NSURL resource keys.
    static func list() -> [DiskSpeedVolume] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsReadOnlyKey,
        ]
        var out: [DiskSpeedVolume] = []
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                           options: [.skipHiddenVolumes]) ?? []
        for url in mounted {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let total = (v?.volumeTotalCapacity).map { Int64($0) } ?? 0
            // important-usage > raw available — accounts for purgeable.
            let free  = Int64((v?.volumeAvailableCapacityForImportantUsage)
                               ?? Int64(v?.volumeAvailableCapacity ?? 0))
            out.append(DiskSpeedVolume(
                url: url,
                name: v?.volumeName ?? url.lastPathComponent,
                totalMiB: total / Int64(DiskSpeedMiB),
                freeMiB: free / Int64(DiskSpeedMiB),
                isRemovable: v?.volumeIsRemovable ?? false,
                isReadOnly: v?.volumeIsReadOnly ?? false))
        }
        // Always include `/`.
        if !out.contains(where: { $0.url.path == "/" }) {
            let rootURL = URL(fileURLWithPath: "/")
            let v = try? rootURL.resourceValues(forKeys: Set(keys))
            let total = (v?.volumeTotalCapacity).map { Int64($0) } ?? 0
            let free  = Int64((v?.volumeAvailableCapacityForImportantUsage)
                               ?? Int64(v?.volumeAvailableCapacity ?? 0))
            out.insert(DiskSpeedVolume(
                url: rootURL,
                name: v?.volumeName ?? "Macintosh HD",
                totalMiB: total / Int64(DiskSpeedMiB),
                freeMiB: free / Int64(DiskSpeedMiB),
                isRemovable: false,
                isReadOnly: v?.volumeIsReadOnly ?? false), at: 0)
        }
        return out
    }

    /// Where to drop the scratch blob. Prefer a hidden dir on the chosen volume
    /// itself — we have to measure the *target* device, not the boot drive.
    /// For the root volume we use ~/Library/Caches/Trove so we don't litter /.
    ///
    /// red-team: if the user's home directory is on a network mount (NFS / SMB
    /// network home), ~/Library/Caches is on the *network*, and benchmarking
    /// "/" actually benchmarks the wire. Detect that and fall back to
    /// /tmp/trove-diskspeed — always local on macOS (tmpfs-ish on APFS).
    /// Override via env TROVE_DISKSPEED_SCRATCH=/path.
    static func scratchDir(for volume: DiskSpeedVolume) throws -> URL {
        let fm = FileManager.default

        // red-team: explicit override hook for power users / CI.
        if let override = ProcessInfo.processInfo.environment["TROVE_DISKSPEED_SCRATCH"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        if volume.url.path == "/" {
            let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            // red-team: detect network-home and bail to /tmp for the
            // local-only benchmark. Network homes report .volumeIsLocalKey =
            // false; trying to benchmark "/" by writing to a network-mounted
            // ~/Library/Caches would silently measure the wrong device.
            let isLocal = (try? cachesURL.resourceValues(forKeys: [.volumeIsLocalKey])
                                          .volumeIsLocal) ?? true
            if !isLocal {
                let tmp = URL(fileURLWithPath: "/tmp/trove-diskspeed", isDirectory: true)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                return tmp
            }
            let dir = cachesURL.appendingPathComponent("Trove", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = volume.url.appendingPathComponent(".trove-diskspeed", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// red-team: SIGKILL leaves blobs behind. Sweep `.trove-diskspeed/` on
    /// every mounted volume + the caches/tmp directories on launch and rm
    /// anything matching our naming pattern. Caller invokes from main on
    /// app start.
    // red-team-sec: ONLY delete files whose lastPathComponent matches our
    // exact naming pattern. The previous code did this via hasPrefix +
    // hasSuffix, which is correct, but we additionally refuse to recurse —
    // `contentsOfDirectory` (non-recursive) is what we want; we explicitly do
    // NOT use enumerator() here. A symlinked subdir inside .trove-diskspeed
    // could trick a recursive walk into rm'ing arbitrary user files; the
    // single-level listing keeps the blast radius bounded to the scratch dir.
    static func purgeOrphanedScratchOnLaunch() {
        let fm = FileManager.default
        var searchRoots: [URL] = []
        // Per-volume scratch dirs. red-team: skip non-local volumes — sweeping
        // a network mount on launch could hang the cold-start (NFS timeout)
        // and the scratch never lands there anyway (we always write to the
        // boot-volume Caches fallback for network-home users).
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey],
                                            options: [.skipHiddenVolumes]) ?? []
        for u in mounted {
            let isLocal = (try? u.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
            if !isLocal { continue }
            searchRoots.append(u.appendingPathComponent(".trove-diskspeed", isDirectory: true))
        }
        // Boot-volume scratch dir (under Caches) and /tmp fallback.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let c = caches {
            searchRoots.append(c.appendingPathComponent("Trove", isDirectory: true))
        }
        searchRoots.append(URL(fileURLWithPath: "/tmp/trove-diskspeed", isDirectory: true))
        // Honour the env override too.
        if let override = ProcessInfo.processInfo.environment["TROVE_DISKSPEED_SCRATCH"],
           !override.isEmpty {
            searchRoots.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        for root in searchRoots {
            guard let children = try? fm.contentsOfDirectory(at: root,
                                                              includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                              options: [.skipsHiddenFiles])
            else { continue }
            for child in children {
                let name = child.lastPathComponent
                // red-team-sec: only act on regular files; never follow or
                // delete a symlink (an attacker who can write into our
                // scratch dir could symlink `diskspeed-X.bin -> ~/.ssh/id_ed25519`
                // and have us unlink the target. Skipping symlinks closes that.).
                let rv = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if rv?.isSymbolicLink == true { continue }
                if rv?.isRegularFile != true { continue }
                // Only delete files we generated:
                //   diskspeed-<UUID>.bin
                //   .trove-probe-<UUID>
                if (name.hasPrefix("diskspeed-") && name.hasSuffix(".bin"))
                    || name.hasPrefix(".trove-probe-") {
                    try? fm.removeItem(at: child)
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Benchmark core
// ===========================================================================

/// Result of one full (seq-w + seq-r + rand-w + rand-r) benchmark pass.
struct DiskSpeedResult: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let volumePath: String
    let volumeName: String
    let blobMiB: Int
    /// Median MiB/s across `DiskSpeedRepeats` runs, per stage.
    let seqWrite: Double
    let seqRead: Double
    let randWrite: Double
    let randRead: Double
    let randWriteIOPS: Double
    let randReadIOPS: Double
    /// Per-run raw MiB/s (length == DiskSpeedRepeats), for transparency.
    let seqWriteRuns: [Double]
    let seqReadRuns: [Double]
    let randWriteRuns: [Double]
    let randReadRuns: [Double]
}

/// Phases tracked for the progress bar + ETA.
enum DiskSpeedStage: String, CaseIterable {
    case prep        = "Preparing"
    case seqWrite    = "Sequential write"
    case seqRead     = "Sequential read"
    case randWrite   = "Random write"
    case randRead    = "Random read"
    case cleanup     = "Cleanup"
}

/// Shared mutable cancellation flag for the IO loop. `Task.isCancelled` works
/// too but we want a tight inner check we can read from any thread without
/// a hop. (red-team #6)
final class DiskSpeedCancelFlag: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var flag: Bool = false
    func cancel() { os_unfair_lock_lock(&lock); flag = true; os_unfair_lock_unlock(&lock) }
    func isCancelled() -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return flag
    }
}

/// Pure IO core — no SwiftUI, no actor isolation. Callers run this on a
/// background queue and bridge progress back to MainActor.
enum DiskSpeedCore {

    /// Pre-flight: free-space cap + write probe. Throws DiskSpeedError on refusal.
    static func preflight(volume: DiskSpeedVolume, blobMiB: Int) throws -> URL {
        // red-team #1+5: pre-flight permission check on the scratch dir.
        let dir = try DiskSpeedVolumes.scratchDir(for: volume)
        let probe = dir.appendingPathComponent(".trove-probe-\(UUID().uuidString)")
        let fd = open(probe.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 {
            let e = errno
            if e == EACCES || e == EPERM { throw DiskSpeedError.permissionDenied }
            if e == EROFS               { throw DiskSpeedError.readOnly }
            throw DiskSpeedError.openFailed(String(cString: strerror(e)))
        }
        close(fd); unlink(probe.path)

        // red-team #*: refuse to fill > 50% of free space; cap at the spec max.
        let requested = Int64(blobMiB)
        // Re-read free space — list() data may be stale by minutes.
        let v = try? volume.url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let freeBytes = Int64(v?.volumeAvailableCapacityForImportantUsage
                              ?? Int64(v?.volumeAvailableCapacity ?? 0))
        let freeMiB = freeBytes / Int64(DiskSpeedMiB)
        if requested * 2 > freeMiB {
            throw DiskSpeedError.insufficientSpace(freeMiB: freeMiB, requestedMiB: requested)
        }
        return dir
    }

    /// Open a file with F_NOCACHE so reads/writes skip the unified buffer cache.
    /// red-team #2: verify the fcntl return — non-zero is failure.
    /// red-team #1: O_TRUNC for writers, plain O_RDONLY for readers.
    static func openNoCache(path: String, write: Bool) throws -> Int32 {
        let flags: Int32 = write ? (O_RDWR | O_CREAT | O_TRUNC) : O_RDONLY
        let fd = open(path, flags, 0o600)
        if fd < 0 {
            let e = errno
            if e == EACCES || e == EPERM { throw DiskSpeedError.permissionDenied }
            if e == EROFS               { throw DiskSpeedError.readOnly }
            throw DiskSpeedError.openFailed(String(cString: strerror(e)))
        }
        // F_NOCACHE: turns OFF data caching for this fd. Critical — without
        // this, the second read pass would hit the page cache and report
        // 40 GB/s of RAM bandwidth.
        let rc = fcntl(fd, F_NOCACHE, 1)
        if rc != 0 {
            let e = errno
            close(fd)
            throw DiskSpeedError.nocacheFailed(e)
        }
        return fd
    }

    /// Map errno from an IO syscall to a DiskSpeedError. ENOSPC = disk full,
    /// EIO / ENXIO / EBADF on a network volume that vanished = disconnected.
    private static func mapIOErr(_ e: Int32, write: Bool) -> DiskSpeedError {
        if e == ENOSPC { return .diskFull }
        if e == EIO || e == ENXIO || e == ENODEV || e == ENOENT {
            return .volumeDisconnected
        }
        let msg = String(cString: strerror(e))
        return write ? .writeFailed(msg) : .readFailed(msg)
    }

    /// Sequential write of `bytes` bytes from a single reused 1-MiB buffer.
    /// Returns elapsed nanoseconds. Throws on cancel/error.
    static func sequentialWrite(fd: Int32,
                                bytes: Int64,
                                cancel: DiskSpeedCancelFlag,
                                progress: (Double) -> Void) throws -> UInt64 {
        let chunk = DiskSpeedMiB
        // Reusable 1 MiB buffer, pre-filled with pseudo-random bytes so a
        // compressing filesystem (rare on macOS, but APFS-on-encrypted-vols
        // can still dedup zero pages) can't cheat.
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buf.deallocate() }
        let p = buf.bindMemory(to: UInt8.self, capacity: chunk)
        var seed: UInt64 = 0xcbf29ce484222325
        for i in 0..<chunk {
            seed = seed &* 0x100000001b3
            p[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        var written: Int64 = 0
        while written < bytes {
            if cancel.isCancelled() { throw DiskSpeedError.cancelled }
            let remaining = bytes - written
            let toWrite = remaining < Int64(chunk) ? Int(remaining) : chunk
            let n = write(fd, buf, toWrite)
            if n < 0 { throw mapIOErr(errno, write: true) }
            // red-team #3: short write that doesn't advance ⇒ ENOSPC dressed
            // up as a partial. Treat as disk-full.
            if n == 0 { throw DiskSpeedError.diskFull }
            written += Int64(n)
            progress(Double(written) / Double(bytes))
        }
        // fsync — without it, "write speed" is "speed of cramming into RAM
        // before the kernel flushes." F_NOCACHE *should* make writes synchronous
        // already on macOS, but fsync is the belt-and-suspenders guarantee.
        if fsync(fd) != 0 { throw mapIOErr(errno, write: true) }
        return DispatchTime.now().uptimeNanoseconds - start
    }

    /// Sequential read of `bytes` bytes into a reused 1-MiB buffer.
    static func sequentialRead(fd: Int32,
                               bytes: Int64,
                               cancel: DiskSpeedCancelFlag,
                               progress: (Double) -> Void) throws -> UInt64 {
        let chunk = DiskSpeedMiB
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buf.deallocate() }
        _ = lseek(fd, 0, SEEK_SET)

        let start = DispatchTime.now().uptimeNanoseconds
        var readSoFar: Int64 = 0
        while readSoFar < bytes {
            if cancel.isCancelled() { throw DiskSpeedError.cancelled }
            let remaining = bytes - readSoFar
            let toRead = remaining < Int64(chunk) ? Int(remaining) : chunk
            let n = read(fd, buf, toRead)
            if n < 0 { throw mapIOErr(errno, write: false) }
            if n == 0 { break } // EOF — shouldn't happen, but stop cleanly.
            readSoFar += Int64(n)
            progress(Double(readSoFar) / Double(bytes))
        }
        return DispatchTime.now().uptimeNanoseconds - start
    }

    /// Random 4-KiB writes scattered across the blob via pread/pwrite.
    /// Returns (elapsedNanos, totalBytesIO, opsCompleted).
    static func randomWrite(fd: Int32,
                            blobBytes: Int64,
                            ops: Int,
                            cancel: DiskSpeedCancelFlag,
                            progress: (Double) -> Void) throws -> (UInt64, Int64, Int) {
        let block = DiskSpeedRandBlock
        let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 4096)
        defer { buf.deallocate() }
        // Seed with garbage so write payload isn't all-zero.
        let p = buf.bindMemory(to: UInt8.self, capacity: block)
        for i in 0..<block { p[i] = UInt8(truncatingIfNeeded: i &+ 17) }

        // Block-aligned offset range. Avoid the very last block to keep us
        // strictly inside the blob.
        let maxBlocks = max(Int64(1), blobBytes / Int64(block) - 1)
        var rng = SystemRandomNumberGenerator()

        let start = DispatchTime.now().uptimeNanoseconds
        var bytesIO: Int64 = 0
        for i in 0..<ops {
            if cancel.isCancelled() { throw DiskSpeedError.cancelled }
            let off = Int64.random(in: 0..<maxBlocks, using: &rng) * Int64(block)
            let n = pwrite(fd, buf, block, off)
            if n < 0 { throw mapIOErr(errno, write: true) }
            if n == 0 { throw DiskSpeedError.diskFull }
            bytesIO += Int64(n)
            if (i & 0x3F) == 0 {
                progress(Double(i + 1) / Double(ops))
            }
        }
        if fsync(fd) != 0 { throw mapIOErr(errno, write: true) }
        progress(1.0)
        return (DispatchTime.now().uptimeNanoseconds - start, bytesIO, ops)
    }

    /// Random 4-KiB reads scattered across the blob via pread.
    static func randomRead(fd: Int32,
                           blobBytes: Int64,
                           ops: Int,
                           cancel: DiskSpeedCancelFlag,
                           progress: (Double) -> Void) throws -> (UInt64, Int64, Int) {
        let block = DiskSpeedRandBlock
        let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 4096)
        defer { buf.deallocate() }
        let maxBlocks = max(Int64(1), blobBytes / Int64(block) - 1)
        var rng = SystemRandomNumberGenerator()

        let start = DispatchTime.now().uptimeNanoseconds
        var bytesIO: Int64 = 0
        for i in 0..<ops {
            if cancel.isCancelled() { throw DiskSpeedError.cancelled }
            let off = Int64.random(in: 0..<maxBlocks, using: &rng) * Int64(block)
            let n = pread(fd, buf, block, off)
            if n < 0 { throw mapIOErr(errno, write: false) }
            if n == 0 { break }
            bytesIO += Int64(n)
            if (i & 0x3F) == 0 {
                progress(Double(i + 1) / Double(ops))
            }
        }
        progress(1.0)
        return (DispatchTime.now().uptimeNanoseconds - start, bytesIO, ops)
    }
}

// ===========================================================================
// MARK: - Tracker / blob registry
// ===========================================================================

/// Process-wide registry of in-flight scratch blobs. Used by the
/// `applicationWillTerminate` hook so a crash/Quit while a test is running
/// doesn't leave gigabytes of `.trove-diskspeed-*.bin` lying around.
/// (red-team #1)
enum DiskSpeedScratchRegistry {
    nonisolated(unsafe) private static var lock = os_unfair_lock_s()
    nonisolated(unsafe) private static var paths: Set<String> = []

    static func register(_ path: String) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        paths.insert(path)
    }
    static func unregister(_ path: String) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        paths.remove(path)
    }
    /// Best-effort sync cleanup on quit.
    static func purgeAll() {
        os_unfair_lock_lock(&lock)
        let snapshot = paths; paths.removeAll()
        os_unfair_lock_unlock(&lock)
        for p in snapshot { unlink(p) }
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

@MainActor
final class DiskSpeedViewModel: ObservableObject {
    @Published var volumes: [DiskSpeedVolume] = []
    @Published var selected: DiskSpeedVolume?
    @Published var blobMiB: Int = DiskSpeedDefaultBlobMiB
    @Published var queue: [DiskSpeedVolume] = []
    @Published var running: Bool = false
    @Published var currentVolume: DiskSpeedVolume?
    @Published var currentStage: DiskSpeedStage = .prep
    @Published var currentRepeat: Int = 0           // 1...DiskSpeedRepeats
    @Published var stageProgress: Double = 0
    @Published var overallProgress: Double = 0
    @Published var etaSeconds: Double?
    @Published var liveMessage: String = "Idle. Pick a volume and press Run."
    @Published var results: [DiskSpeedResult] = []
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    // red-team: removed the unused `cancelFlag` field. The only live flag is
    // `cancelFlagBox`, replaced per-run by `start()`. Keeping a stale, never
    // cancelled flag around was a footgun for whoever next added IO code.
    private var willTerminateObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    // IOPMAssertion: prevent system sleep during a benchmark run.
    private var pmAssertionID: IOPMAssertionID = IOPMAssertionID(0)

    init() {
        // Both `purgeOrphanedScratchOnLaunch` and `refreshVolumes` iterate
        // mounted volumes via `FileManager.mountedVolumeURLs` + per-volume
        // `resourceValues` lookups. Local disks return in microseconds, but
        // an attached network volume can stall the call indefinitely — and
        // doing it synchronously in `@StateObject` init is the exact main-
        // thread pattern that crashed the app on Clean / Finder / Account.
        // Move both off-main; volumes patch in when ready.
        Task.detached(priority: .utility) { [weak self] in
            DiskSpeedVolumes.purgeOrphanedScratchOnLaunch()
            let vols = DiskSpeedVolumes.list()
            await MainActor.run {
                guard let self else { return }
                self.volumes = vols
                self.selected = vols.first { $0.url.path == "/" } ?? vols.first
            }
        }
        // red-team #1: scratch cleanup on app termination.
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: .troveWillTerminate, object: nil, queue: .main
        ) { _ in
            DiskSpeedScratchRegistry.purgeAll()
        }
        // Cancel/finalize an in-flight benchmark before the Mac sleeps so an
        // 8-hour suspend doesn't leave a stale IO task running across wake.
        willSleepObserver = NotificationCenter.default.addObserver(
            forName: .troveSystemWillSleep, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelForSleep()
        }
    }

    /// Cancels the active benchmark on sleep. Mirrors `cancelScanForSleep` in BigScan.
    private func cancelForSleep() {
        guard running else { return }
        task?.cancel()
        cancelFlagBox.cancel()
        running = false
        liveMessage = "Benchmark cancelled — Mac going to sleep."
        if pmAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(pmAssertionID)
            pmAssertionID = IOPMAssertionID(0)
        }
    }

    deinit {
        if let o = willTerminateObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = willSleepObserver {
            NotificationCenter.default.removeObserver(o)
        }
        // red-team: belt-and-suspenders — if the VM is dropped while a run is
        // still mid-flight (pane removed from the sidebar during a benchmark),
        // cancel the in-flight task and purge any scratch blobs we registered
        // so we don't leak gigabytes on disk. willTerminate covers Quit; this
        // covers the "pane dismissed mid-run" path.
        task?.cancel()
        cancelFlagBox.cancel()
        DiskSpeedScratchRegistry.purgeAll()
    }

    func refreshVolumes() {
        let fresh = DiskSpeedVolumes.list()
        volumes = fresh
        // Keep selection if its path is still mounted.
        if let s = selected, !fresh.contains(where: { $0.url.path == s.url.path }) {
            selected = fresh.first
        }
    }

    func enqueue(_ v: DiskSpeedVolume) {
        if !queue.contains(v) { queue.append(v) }
    }

    func removeFromQueue(_ v: DiskSpeedVolume) {
        queue.removeAll { $0.id == v.id }
    }

    func clampedBlobMiB() -> Int {
        return min(DiskSpeedMaxBlobMiB, max(DiskSpeedMinBlobMiB, blobMiB))
    }

    // ------ start / cancel ------------------------------------------------

    func start(stage: Stage) {
        guard !running else { return }
        // Build the run list: explicit queue if any, else just selected.
        let runList: [DiskSpeedVolume] = queue.isEmpty
            ? (selected.map { [$0] } ?? [])
            : queue
        guard !runList.isEmpty else {
            stage.flash("Disk Speed: pick a volume first.")
            return
        }
        running = true
        errorMessage = nil
        // Prevent system sleep while the benchmark is running — a sleep mid-
        // benchmark produces bogus latency numbers and can corrupt scratch blobs.
        if pmAssertionID == IOPMAssertionID(0) {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Trove disk benchmark in progress" as CFString,
                &pmAssertionID)
        }
        let mib = clampedBlobMiB()
        // red-team: race fix — install the new cancelFlagBox BEFORE launching
        // the detached task. Previously the box was assigned after Task
        // creation, so a near-instant user Cancel could fire on the stale
        // prior box, the new task would never see cancelled=true, and we'd
        // leak a full benchmark pass after the user thought they'd stopped.
        let newFlag = DiskSpeedCancelFlag()
        cancelFlagBox = newFlag
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runQueue(runList, blobMiB: mib, cancel: newFlag, stage: stage)
        }
    }

    /// Latest cancel flag — replaced per-run so a previous cancelled flag
    /// can't poison a fresh start.
    private var cancelFlagBox: DiskSpeedCancelFlag = DiskSpeedCancelFlag()

    func cancel() {
        cancelFlagBox.cancel()
        task?.cancel()
        liveMessage = "Cancelling…"
    }

    // ------ driver -------------------------------------------------------

    private func runQueue(_ vols: [DiskSpeedVolume],
                          blobMiB: Int,
                          cancel: DiskSpeedCancelFlag,
                          stage: Stage) async {
        // red-team: the queue loop below is STRICTLY sequential — `await
        // runOne(...)` blocks the iterator. This is intentional and matches
        // the user's "Sequential HDD jobs" rule: even when the queue
        // contains multiple volumes that happen to share a single physical
        // disk (e.g. two APFS volumes on the same SSD), we benchmark them
        // one at a time so their numbers reflect uncontested device
        // bandwidth instead of half-each. Do NOT parallelise across `vols`.
        let totalUnits = Double(vols.count) * Double(DiskSpeedRepeats) * 4.0  // 4 IO stages
        var unitsDone: Double = 0
        let startNanos = DispatchTime.now().uptimeNanoseconds

        defer {
            Task { @MainActor in
                self.running = false
                self.currentVolume = nil
                self.currentStage = .prep
                self.stageProgress = 0
                self.overallProgress = 0
                self.etaSeconds = nil
                // Release IOPMAssertion now that the benchmark has ended.
                if self.pmAssertionID != IOPMAssertionID(0) {
                    IOPMAssertionRelease(self.pmAssertionID)
                    self.pmAssertionID = IOPMAssertionID(0)
                }
            }
        }

        for vol in vols {
            if cancel.isCancelled() { break }
            await MainActor.run {
                self.currentVolume = vol
                self.currentStage = .prep
                self.liveMessage = "Preparing \(vol.displayName)…"
            }
            do {
                let result = try await self.runOne(
                    volume: vol, blobMiB: blobMiB, cancel: cancel,
                    onStageDone: {
                        unitsDone += 1
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanos)
                                       / 1_000_000_000.0
                        let perUnit = unitsDone > 0 ? elapsed / unitsDone : 0
                        let remaining = (totalUnits - unitsDone) * perUnit
                        Task { @MainActor in
                            self.overallProgress = unitsDone / totalUnits
                            self.etaSeconds = remaining > 0 ? remaining : nil
                        }
                    })
                await MainActor.run {
                    self.results.insert(result, at: 0)
                    self.liveMessage = "Done: \(vol.displayName)"
                    stage.flash("Disk Speed: \(vol.name) — seq R \(String(format: "%.0f", result.seqRead)) MiB/s")
                }
            } catch let e as DiskSpeedError {
                await MainActor.run {
                    self.errorMessage = "\(vol.displayName): \(e.localizedDescription)"
                    self.liveMessage = e.localizedDescription
                }
                if case .cancelled = e { break }
                // Other errors: continue to the next volume in the queue.
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(vol.displayName): \(error.localizedDescription)"
                }
            }
        }
        await MainActor.run {
            if !cancel.isCancelled() && self.errorMessage == nil {
                self.liveMessage = "All runs complete."
            } else if cancel.isCancelled() {
                self.liveMessage = "Cancelled."
                let n = self.results.count
                stage.flash("Disk speed cancelled · \(n) result\(n == 1 ? "" : "s") captured",
                            kind: .warning)
            }
        }
    }

    private func runOne(volume: DiskSpeedVolume,
                        blobMiB: Int,
                        cancel: DiskSpeedCancelFlag,
                        onStageDone: @escaping () -> Void) async throws -> DiskSpeedResult {
        // Pre-flight on main-actor-blessed input — sync IO, but cheap.
        let scratchDir = try DiskSpeedCore.preflight(volume: volume, blobMiB: blobMiB)
        let blobBytes = Int64(blobMiB) * Int64(DiskSpeedMiB)
        let blobURL = scratchDir
            .appendingPathComponent("diskspeed-\(UUID().uuidString).bin")
        let blobPath = blobURL.path

        DiskSpeedScratchRegistry.register(blobPath)
        // red-team #1+6: defer cleanup so cancel/throw also removes the blob.
        defer {
            unlink(blobPath)
            DiskSpeedScratchRegistry.unregister(blobPath)
        }

        var seqW: [Double] = []
        var seqR: [Double] = []
        var randW: [Double] = []
        var randR: [Double] = []
        var randWIOPS: [Double] = []
        var randRIOPS: [Double] = []

        for rep in 1...DiskSpeedRepeats {
            if cancel.isCancelled() { throw DiskSpeedError.cancelled }
            await MainActor.run { self.currentRepeat = rep }

            // ----- SEQ WRITE -----
            await MainActor.run {
                self.currentStage = .seqWrite
                self.stageProgress = 0
                self.liveMessage = "Pass \(rep)/\(DiskSpeedRepeats) · sequential write"
            }
            do {
                let fd = try DiskSpeedCore.openNoCache(path: blobPath, write: true)
                defer { close(fd) }
                let nanos = try DiskSpeedCore.sequentialWrite(
                    fd: fd, bytes: blobBytes, cancel: cancel,
                    progress: { p in
                        Task { @MainActor in self.stageProgress = p }
                    })
                seqW.append(diskSpeedMiBPerSec(bytes: blobBytes, nanos: nanos))
            }
            onStageDone()

            // ----- SEQ READ -----
            await MainActor.run {
                self.currentStage = .seqRead
                self.stageProgress = 0
                self.liveMessage = "Pass \(rep)/\(DiskSpeedRepeats) · sequential read"
            }
            do {
                let fd = try DiskSpeedCore.openNoCache(path: blobPath, write: false)
                defer { close(fd) }
                let nanos = try DiskSpeedCore.sequentialRead(
                    fd: fd, bytes: blobBytes, cancel: cancel,
                    progress: { p in
                        Task { @MainActor in self.stageProgress = p }
                    })
                seqR.append(diskSpeedMiBPerSec(bytes: blobBytes, nanos: nanos))
            }
            onStageDone()

            // ----- RAND WRITE -----
            await MainActor.run {
                self.currentStage = .randWrite
                self.stageProgress = 0
                self.liveMessage = "Pass \(rep)/\(DiskSpeedRepeats) · random write (4 KiB × \(DiskSpeedRandOps))"
            }
            do {
                // Re-open RDWR (no O_TRUNC — we want the existing blob).
                let fd = open(blobPath, O_RDWR, 0o600)
                if fd < 0 { throw DiskSpeedError.openFailed(String(cString: strerror(errno))) }
                defer { close(fd) }
                if fcntl(fd, F_NOCACHE, 1) != 0 {
                    throw DiskSpeedError.nocacheFailed(errno)
                }
                let (nanos, bytesIO, ops) = try DiskSpeedCore.randomWrite(
                    fd: fd, blobBytes: blobBytes, ops: DiskSpeedRandOps,
                    cancel: cancel,
                    progress: { p in
                        Task { @MainActor in self.stageProgress = p }
                    })
                randW.append(diskSpeedMiBPerSec(bytes: bytesIO, nanos: nanos))
                let secs = Double(nanos) / 1_000_000_000.0
                randWIOPS.append(secs > 0 ? Double(ops) / secs : 0)
            }
            onStageDone()

            // ----- RAND READ -----
            await MainActor.run {
                self.currentStage = .randRead
                self.stageProgress = 0
                self.liveMessage = "Pass \(rep)/\(DiskSpeedRepeats) · random read (4 KiB × \(DiskSpeedRandOps))"
            }
            do {
                let fd = open(blobPath, O_RDONLY, 0o600)
                if fd < 0 { throw DiskSpeedError.openFailed(String(cString: strerror(errno))) }
                defer { close(fd) }
                if fcntl(fd, F_NOCACHE, 1) != 0 {
                    throw DiskSpeedError.nocacheFailed(errno)
                }
                let (nanos, bytesIO, ops) = try DiskSpeedCore.randomRead(
                    fd: fd, blobBytes: blobBytes, ops: DiskSpeedRandOps,
                    cancel: cancel,
                    progress: { p in
                        Task { @MainActor in self.stageProgress = p }
                    })
                randR.append(diskSpeedMiBPerSec(bytes: bytesIO, nanos: nanos))
                let secs = Double(nanos) / 1_000_000_000.0
                randRIOPS.append(secs > 0 ? Double(ops) / secs : 0)
            }
            onStageDone()
        }

        await MainActor.run {
            self.currentStage = .cleanup
            self.stageProgress = 1
        }
        return DiskSpeedResult(
            date: Date(),
            volumePath: volume.url.path,
            volumeName: volume.name,
            blobMiB: blobMiB,
            seqWrite:      diskSpeedMedian(seqW),
            seqRead:       diskSpeedMedian(seqR),
            randWrite:     diskSpeedMedian(randW),
            randRead:      diskSpeedMedian(randR),
            randWriteIOPS: diskSpeedMedian(randWIOPS),
            randReadIOPS:  diskSpeedMedian(randRIOPS),
            seqWriteRuns: seqW, seqReadRuns: seqR,
            randWriteRuns: randW, randReadRuns: randR)
    }

    // ------ export -------------------------------------------------------

    func exportCSV(stage: Stage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "disk-speed-\(Self.fileStamp()).csv"
        panel.canCreateDirectories = true
        panel.message = "Export Disk Speed results"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // red-team-sec: NSSavePanel returns a user-validated URL. Defense in
        // depth: refuse non-file URLs (the user typing a URL into the path
        // field, or a future bug surfacing a `nil`-ish placeholder URL) so
        // we never feed a network/iCloud-only placeholder to Data.write
        // and end up surfacing a confusing "failed to write" error.
        guard url.isFileURL else { return }
        let csv = Self.buildCSV(results)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            stage.flash("Exported \(results.count) result\(results.count == 1 ? "" : "s")")
        } catch {
            stage.flash("Export failed: \(error.localizedDescription)")
        }
    }

    private static func buildCSV(_ rows: [DiskSpeedResult]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out = "date,volume_path,volume_name,blob_mib,"
        out   += "seq_write_mibs,seq_read_mibs,rand_write_mibs,rand_read_mibs,"
        out   += "rand_write_iops,rand_read_iops,"
        out   += "seq_write_runs,seq_read_runs,rand_write_runs,rand_read_runs\n"
        for r in rows {
            // red-team: removed dead `let runs = ...; _ = runs` shim that did
            // nothing — it was a leftover from a refactor. Kept the active
            // `runList` helper below.
            func runList(_ xs: [Double]) -> String {
                xs.map { String(format: "%.2f", $0) }.joined(separator: "|")
            }
            // red-team-sec: also escape CR (\r) — a volume name containing
            // bare CR (rare, but APFS allows almost any byte in volume names)
            // would otherwise inject a line break into the CSV. Matches the
            // RFC 4180 rule: any field containing CR, LF, comma, or quote
            // must be quoted; embedded quotes are doubled.
            func esc(_ s: String) -> String {
                if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return s
            }
            out += "\(iso.string(from: r.date)),"
            out += "\(esc(r.volumePath)),\(esc(r.volumeName)),\(r.blobMiB),"
            out += "\(String(format: "%.2f", r.seqWrite)),"
            out += "\(String(format: "%.2f", r.seqRead)),"
            out += "\(String(format: "%.2f", r.randWrite)),"
            out += "\(String(format: "%.2f", r.randRead)),"
            out += "\(String(format: "%.1f", r.randWriteIOPS)),"
            out += "\(String(format: "%.1f", r.randReadIOPS)),"
            out += "\(runList(r.seqWriteRuns)),"
            out += "\(runList(r.seqReadRuns)),"
            out += "\(runList(r.randWriteRuns)),"
            out += "\(runList(r.randReadRuns))\n"
        }
        return out
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Median of a `[Double]` — sort + middle (or mean of two middles).
private func diskSpeedMedian(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let n = s.count
    if n % 2 == 1 { return s[n / 2] }
    return (s[n/2 - 1] + s[n/2]) / 2
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct DiskSpeedView: View {
    @StateObject private var vm = DiskSpeedViewModel()
    @EnvironmentObject var stage: Stage

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pickerCard
                queueCard
                runCard
                if let err = vm.errorMessage { errorCard(err) }
                if !vm.results.isEmpty {
                    resultsCard
                } else if !vm.running {
                    noResultsCard
                }
            }
            .padding(24)
        }
        .navigationTitle("Disk Speed")
        .navigationSubtitle(vm.running
            ? "\(vm.currentStage.rawValue) · pass \(vm.currentRepeat)/\(DiskSpeedRepeats)"
            : "\(vm.results.count) result\(vm.results.count == 1 ? "" : "s")")
        .background(
            // red-team: Space to start/cancel. A zero-frame button with
            // .keyboardShortcut(.space) avoids stealing space from text fields
            // because SwiftUI only delivers it when nothing else accepts it.
            Button("") { toggleSpace() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if vm.running {
                    Button(role: .destructive) { vm.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Cancel benchmark (Esc or ⌘.)")
                    Button("") { vm.cancel() }
                        .keyboardShortcut(".", modifiers: [.command])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                } else {
                    Button { vm.start(stage: stage) } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                Button {
                    vm.exportCSV(stage: stage)
                } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(vm.results.isEmpty)
                Button {
                    vm.refreshVolumes()
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(vm.running)
            }
        }
    }

    private func toggleSpace() {
        if vm.running { vm.cancel() } else { vm.start(stage: stage) }
    }

    // ----- cards ----------------------------------------------------------

    private var pickerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text("Volume").font(.headline)
                    Spacer()
                    Text("\(vm.volumes.count) mounted")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Picker("", selection: Binding(
                    get: { vm.selected ?? vm.volumes.first ?? DiskSpeedVolume(
                        url: URL(fileURLWithPath: "/"),
                        name: "Macintosh HD",
                        totalMiB: 0, freeMiB: 0,
                        isRemovable: false, isReadOnly: false) },
                    set: { vm.selected = $0 }
                )) {
                    ForEach(vm.volumes) { v in
                        Text(diskSpeedVolumeLabel(v)).tag(v)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let v = vm.selected {
                    HStack(spacing: 14) {
                        Text("Free: \((v.freeMiB * Int64(DiskSpeedMiB)).human)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("Total: \((v.totalMiB * Int64(DiskSpeedMiB)).human)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if v.isReadOnly {
                            Label("Read-only", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if v.isRemovable {
                            Label("Removable", systemImage: "eject.fill")
                                .font(.caption).foregroundStyle(.tint)
                        }
                        Spacer()
                        Button {
                            if let s = vm.selected { vm.enqueue(s) }
                        } label: { Label("Add to queue", systemImage: "plus") }
                        .disabled(vm.running)
                    }
                }

                Divider().padding(.vertical, 2)

                HStack(spacing: 12) {
                    Text("Blob size").font(.subheadline)
                    Slider(value: Binding(
                        get: { Double(vm.blobMiB) },
                        set: { vm.blobMiB = Int($0) }
                    ), in: Double(DiskSpeedMinBlobMiB)...Double(DiskSpeedMaxBlobMiB),
                       step: 100)
                    .disabled(vm.running)
                    Text(diskSpeedFormatMiB(vm.blobMiB))
                        .font(.body.monospacedDigit())
                        .frame(width: 90, alignment: .trailing)
                }
                Text("Each test runs \(DiskSpeedRepeats)× (median). F_NOCACHE bypasses the page cache. " +
                     "Auto-capped to ≤ 50% of free space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var queueCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                    Text("Queue").font(.headline)
                    Spacer()
                    if !vm.queue.isEmpty {
                        Button("Clear", role: .destructive) { vm.queue.removeAll() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .disabled(vm.running)
                    }
                }
                if vm.queue.isEmpty {
                    Text("Empty — Run will benchmark just the selected volume. " +
                         "Add volumes to enqueue a multi-volume batch.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(vm.queue) { v in
                        HStack(spacing: 8) {
                            Image(systemName: vm.currentVolume?.id == v.id
                                  ? "play.circle.fill" : "circle")
                                .foregroundStyle(vm.currentVolume?.id == v.id
                                                 ? Color.accentColor : .secondary)
                            Text(diskSpeedVolumeLabel(v))
                                .font(.callout.monospacedDigit())
                            Spacer()
                            Button {
                                vm.removeFromQueue(v)
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .disabled(vm.running)
                        }
                    }
                }
            }
        }
    }

    private var runCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: vm.running ? "bolt.horizontal.circle"
                                                 : "bolt.horizontal.circle.fill")
                        .foregroundStyle(vm.running ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.secondary))
                    Text(vm.running ? "Running" : "Ready").font(.headline)
                    Spacer()
                    Text(vm.liveMessage)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if vm.running {
                    ProgressView(value: vm.stageProgress)
                        .progressViewStyle(.linear)
                    HStack(spacing: 12) {
                        Text("Overall: \(Int(vm.overallProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ProgressView(value: vm.overallProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                        if let eta = vm.etaSeconds {
                            Text("ETA \(diskSpeedFormatETA(eta))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                } else {
                    Text("Press Run (or Space) to start. Each volume is tested " +
                         "in 4 stages × \(DiskSpeedRepeats) passes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var noResultsCard: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "speedometer")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No benchmark yet")
                    .font(.headline)
                Text("Disk Speed measures sequential and random read/write throughput plus 4 KiB IOPS on the volume above. Each run uses F_NOCACHE to bypass the page cache and reports the median of \(DiskSpeedRepeats) passes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.center)
                Button {
                    vm.start(stage: stage)
                } label: {
                    Label("Run benchmark", systemImage: "play.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private func errorCard(_ msg: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Issue").font(.headline)
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { vm.errorMessage = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var resultsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "tablecells").foregroundStyle(.secondary)
                    Text("Results").font(.headline)
                    Spacer()
                    Text("\(vm.results.count) run\(vm.results.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                // Header row
                HStack(spacing: 0) {
                    DiskSpeedColHeader("Volume", width: 200, align: .leading)
                    DiskSpeedColHeader("Size",   width: 70)
                    DiskSpeedColHeader("Seq W",  width: 80)
                    DiskSpeedColHeader("Seq R",  width: 80)
                    DiskSpeedColHeader("Rnd W",  width: 80)
                    DiskSpeedColHeader("Rnd R",  width: 80)
                    DiskSpeedColHeader("W IOPS", width: 80)
                    DiskSpeedColHeader("R IOPS", width: 80)
                    Spacer(minLength: 0)
                }
                Divider()
                ForEach(vm.results) { r in
                    HStack(spacing: 0) {
                        DiskSpeedCell(text: r.volumeName.isEmpty ? r.volumePath : r.volumeName,
                                      width: 200, align: .leading)
                        DiskSpeedCell(text: diskSpeedFormatMiB(r.blobMiB), width: 70)
                        DiskSpeedCell(text: String(format: "%.0f", r.seqWrite), width: 80)
                        DiskSpeedCell(text: String(format: "%.0f", r.seqRead),  width: 80)
                        DiskSpeedCell(text: String(format: "%.0f", r.randWrite),width: 80)
                        DiskSpeedCell(text: String(format: "%.0f", r.randRead), width: 80)
                        DiskSpeedCell(text: String(format: "%.0f", r.randWriteIOPS), width: 80)
                        DiskSpeedCell(text: String(format: "%.0f", r.randReadIOPS),  width: 80)
                        Spacer(minLength: 0)
                    }
                }
                Text("All numbers are median MiB/s across \(DiskSpeedRepeats) passes. " +
                     "IOPS are 4 KiB random ops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// ----- small subviews / formatters -------------------------------------------

private struct DiskSpeedColHeader: View {
    let title: String
    let width: CGFloat
    var align: Alignment = .trailing
    init(_ title: String, width: CGFloat, align: Alignment = .trailing) {
        self.title = title; self.width = width; self.align = align
    }
    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: align)
    }
}

private struct DiskSpeedCell: View {
    let text: String
    let width: CGFloat
    var align: Alignment = .trailing
    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .frame(width: width, alignment: align)
            .lineLimit(1).truncationMode(.middle)
    }
}

private func diskSpeedVolumeLabel(_ v: DiskSpeedVolume) -> String {
    let free = (v.freeMiB * Int64(DiskSpeedMiB)).human
    return "\(v.name.isEmpty ? v.url.path : v.name)  ·  \(v.url.path)  ·  \(free) free"
}

private func diskSpeedFormatMiB(_ mib: Int) -> String {
    if mib >= 1024 {
        let gib = Double(mib) / 1024.0
        return String(format: "%.1f GiB", gib)
    }
    return "\(mib) MiB"
}

private func diskSpeedFormatETA(_ secs: Double) -> String {
    if secs < 60 { return String(format: "%.0fs", secs) }
    let m = Int(secs) / 60
    let s = Int(secs) % 60
    return "\(m)m \(s)s"
}
