//
// storage_cache.swift
//
// Persistent cache for the Storage Overview / Scan panes so they paint
// last-known results instantly on launch and only re-scan when the user
// explicitly asks. Lives alongside main.swift; compile with:
//
//   swiftc -parse-as-library main.swift storage_cache.swift ...
//
// On-disk layout:
//   ~/Library/Application Support/Trove/storage-cache.json
//
// Privacy note: this JSON file is plain-text and world-readable to the
// current user. It contains absolute paths (filenames) that may include
// user PII (document names, project names, etc.). It is NOT encrypted.
// Treat it the same as any other Application Support artifact.
//
// Schema (version 1):
//   {
//     "version": 1,
//     "overview": { "diskTotal": Int64, "diskFree": Int64,
//                   "topHome": [SizedItemCodable], "computedAt": ISO8601 }?,
//     "scans":    [ { "path": ..., "mode": "dirs"|"files",
//                     "results": [...], "computedAt": ISO8601 } ]  // <= 10, LRU
//   }
//
// On schema mismatch or corrupt JSON: the bad file is renamed to
//   storage-cache-corrupt-<unix-ts>.json
// and we start empty. We never crash on bad input.
//

import Foundation
import AppKit

// ---------------------------------------------------------------------------
// MARK: - Codable adapters (SizedItem / DiskInfo are not Codable upstream)
// ---------------------------------------------------------------------------

struct StorageCacheSizedItem: Codable {
    let path: String
    let size: Int64
    let isDirectory: Bool

    init(_ s: SizedItem) {
        self.path = s.path; self.size = s.size; self.isDirectory = s.isDirectory
    }
    func toSizedItem() -> SizedItem {
        SizedItem(path: path, size: size, isDirectory: isDirectory)
    }
}

struct StorageCacheOverview: Codable {
    let diskTotal: Int64
    let diskFree: Int64
    let topHome: [StorageCacheSizedItem]
    let computedAt: Date
}

struct StorageCacheScan: Codable {
    let path: String
    let mode: String           // "dirs" or "files"
    let results: [StorageCacheSizedItem]
    let computedAt: Date
}

struct StorageCacheRoot: Codable {
    var version: Int
    var overview: StorageCacheOverview?
    var scans: [StorageCacheScan]
}

// ---------------------------------------------------------------------------
// MARK: - StorageCache
// ---------------------------------------------------------------------------

final class StorageCache {

    // Singleton — loads from disk synchronously on first access.
    static let shared = StorageCache()

    // Tunables
    private let schemaVersion = 1
    private let scanCap = 10
    private let debounceNanos: UInt64 = 300_000_000 // 300ms

    // Locking discipline:
    //  - `root` is only mutated/read while holding `lock`.
    //  - Disk I/O happens on `ioQueue` (serial) so writes can never overlap.
    private let lock = NSLock()
    private var root: StorageCacheRoot
    private let ioQueue = DispatchQueue(label: "trove.storagecache.io")
    private var pendingWrite: DispatchWorkItem?

    private let fileURL: URL
    private let dirURL: URL

    private init() {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = appSup.appendingPathComponent("Trove", isDirectory: true)
        self.dirURL = dir
        self.fileURL = dir.appendingPathComponent("storage-cache.json")
        self.root = StorageCacheRoot(version: schemaVersion,
                                     overview: nil, scans: [])

        // Ensure directory exists (best-effort).
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)

        // Seed empty defaults immediately so callers on the main thread don't
        // block. Load from disk on a utility queue and patch `root` under lock.
        Task.detached(priority: .utility) { [weak self] in
            self?.loadFromDiskOrQuarantine()
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Persist the most recent Overview result. Debounced 300ms.
    func saveOverview(disk: DiskInfo, topHome: [SizedItem]) {
        lock.lock()
        root.overview = StorageCacheOverview(
            diskTotal: disk.total,
            diskFree: disk.free,
            topHome: topHome.map(StorageCacheSizedItem.init),
            computedAt: Date()
        )
        lock.unlock()
        scheduleWrite()
    }

    /// Persist a Scan result keyed by (path, mode). Bounded LRU of 10.
    func saveScan(path: String, mode: String, results: [SizedItem]) {
        lock.lock()
        // Drop existing entry with same key (case-sensitive match on both).
        root.scans.removeAll { $0.path == path && $0.mode == mode }
        root.scans.append(StorageCacheScan(
            path: path, mode: mode,
            results: results.map(StorageCacheSizedItem.init),
            computedAt: Date()
        ))
        // Enforce LRU bound by computedAt (drop oldest first).
        if root.scans.count > scanCap {
            root.scans.sort { $0.computedAt < $1.computedAt }
            let drop = root.scans.count - scanCap
            root.scans.removeFirst(drop)
        }
        lock.unlock()
        scheduleWrite()
    }

    /// Returns the last-known overview snapshot, or nil if none.
    func loadedOverview() -> (DiskInfo, [SizedItem], Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let o = root.overview else { return nil }
        let disk = DiskInfo(total: o.diskTotal, free: o.diskFree)
        let items = o.topHome.map { $0.toSizedItem() }
        return (disk, items, o.computedAt)
    }

    /// Returns the last-known scan for (path, mode), or nil.
    func loadedScan(path: String, mode: String) -> ([SizedItem], Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = root.scans.first(where: { $0.path == path && $0.mode == mode })
        else { return nil }
        return (s.results.map { $0.toSizedItem() }, s.computedAt)
    }

    // -----------------------------------------------------------------------
    // MARK: Disk I/O
    // -----------------------------------------------------------------------

    private func loadFromDiskOrQuarantine() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        // red-team: a maliciously-large cache file (hand-edited, restored from a
        // bad backup, or just stale from an old buggy build) could OOM on the
        // synchronous Data(contentsOf:) load that happens during init. The
        // legitimate file is hundreds of KB at most; refuse anything over 32 MB
        // and quarantine rather than risk the app dying before main.swift can
        // even paint a window.
        let maxCacheBytes: Int = 32 * 1024 * 1024
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let sz = attrs[.size] as? NSNumber, sz.intValue > maxCacheBytes {
            quarantine(reason: "oversized (\(sz.intValue) bytes)")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(StorageCacheRoot.self, from: data)
            guard decoded.version == schemaVersion else {
                quarantine(reason: "version mismatch (\(decoded.version))")
                return
            }
            // Defensive: clamp scans even if file was hand-edited.
            var fixed = decoded
            if fixed.scans.count > scanCap {
                fixed.scans.sort { $0.computedAt < $1.computedAt }
                fixed.scans.removeFirst(fixed.scans.count - scanCap)
            }
            // red-team-sec: a crafted cache file could feed bogus sizes /
            // attacker-controlled paths into the UI. Reject entries with
            // negative sizes, empty paths, or absurdly large reported sizes
            // (>1 PB — far beyond any consumer disk). Symlinks are resolved
            // at Reveal-time by NSWorkspace which is the correct boundary,
            // but we reject paths containing NUL bytes (which can confuse
            // downstream APIs) and embedded newlines.
            let maxPlausibleBytes: Int64 = 1_000_000_000_000_000 // 1 PB
            func sanePath(_ p: String) -> Bool {
                guard !p.isEmpty else { return false }
                if p.contains("\0") || p.contains("\n") || p.contains("\r") { return false }
                return true
            }
            func saneSize(_ s: Int64) -> Bool {
                s >= 0 && s <= maxPlausibleBytes
            }
            if let o = fixed.overview {
                let badOverview = !saneSize(o.diskTotal) || !saneSize(o.diskFree)
                    || o.topHome.contains(where: { !sanePath($0.path) || !saneSize($0.size) })
                if badOverview {
                    fixed.overview = nil
                    NSLog("StorageCache: dropped overview with invalid sizes/paths")
                }
            }
            fixed.scans = fixed.scans.filter { scan in
                guard sanePath(scan.path), scan.mode == "dirs" || scan.mode == "files" else {
                    return false
                }
                return !scan.results.contains(where: { !sanePath($0.path) || !saneSize($0.size) })
            }
            self.root = fixed
        } catch {
            quarantine(reason: "decode error: \(error.localizedDescription)")
        }
    }

    private func quarantine(reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let dest = dirURL.appendingPathComponent("storage-cache-corrupt-\(ts).json")
        try? FileManager.default.moveItem(at: fileURL, to: dest)
        // Stay empty; do not crash. We don't flash here because the cache
        // hasn't been wired to the UI yet at first-launch boot.
        NSLog("StorageCache: quarantined cache file (\(reason)) -> \(dest.path)")
    }

    private func scheduleWrite() {
        // Capture a snapshot now (under lock) and pass it forward; this way
        // disk failures cannot corrupt the in-memory state, and rapid saves
        // collapse into the most recent snapshot only.
        // red-team: pendingWrite was mutated from arbitrary caller threads
        // (saveOverview/saveScan are not thread-confined). Concurrent calls
        // race on the cancel + assign and could leak un-cancelled work items.
        // Guard pendingWrite under `lock` (same lock that owns `root`).
        lock.lock()
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let snapshot = self.root
            self.lock.unlock()
            self.writeAtomically(snapshot)
        }
        pendingWrite = work
        lock.unlock()
        let deadline: DispatchTime = .now() + .nanoseconds(Int(debounceNanos))
        ioQueue.asyncAfter(deadline: deadline, execute: work)
    }

    private func writeAtomically(_ snapshot: StorageCacheRoot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // red-team: track our own tmp path so a write failure (or a crash mid-
        // replaceItem) doesn't leave `storage-cache-<UUID>.tmp` debris in the
        // Application Support dir on every save attempt. The previous version
        // only cleaned up on the *success* path inside replaceItem; a partial
        // write or a thrown encode would orphan the file.
        var tmpURL: URL?
        do {
            // Ensure dir still exists (user may have nuked it).
            try FileManager.default.createDirectory(at: dirURL,
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            // tmp + replaceItem for atomicity.
            let tmp = dirURL.appendingPathComponent(
                "storage-cache-\(UUID().uuidString).tmp")
            tmpURL = tmp
            try data.write(to: tmp, options: [.atomic])
            // replaceItem handles the "destination doesn't exist yet" case.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            tmpURL = nil // moved/replaced — no orphan to clean.
        } catch {
            // Best-effort orphan cleanup.
            if let t = tmpURL { try? FileManager.default.removeItem(at: t) }
            // In-memory state is untouched; just surface to the user.
            let msg = "Cache save failed: \(error.localizedDescription)"
            DispatchQueue.main.async {
                SharedStore.stage.flash(msg)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Relative-date formatter for the "Last scanned ..." badge
// ---------------------------------------------------------------------------

enum StorageCacheAge {
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    /// Caller-facing helper for the badge text.
    /// Example: `Text("Cached \(StorageCacheAge.describe(date))")`
    static func describe(_ date: Date) -> String {
        rel.localizedString(for: date, relativeTo: Date())
    }
}
