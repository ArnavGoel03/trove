//
// big_scan.swift
//
// Deep disk analyzer — five lenses in one pane, competitor-class to
// DaisyDisk / GrandPerspective / OmniDiskSweeper. Compile alongside
// main.swift + storage_cache.swift + the other sibling Swift files:
//
//   swiftc -parse-as-library main.swift storage_cache.swift big_scan.swift ...
//
// The caller (main.swift) wires `BigScanView()` into its Pane router. We do
// NOT declare a Pane case, @main, App, or any top-level executable code here.
//
// Why this file exists (versus reusing the existing ScanView):
//   The existing ScanView is a single-shot "top-N in one folder" tool. It
//   can't answer "which file types are eating my disk", "what are the top
//   50 huge files anywhere under home", "what haven't I touched in 2 years",
//   or "where are my duplicate downloads". This pane does, and runs as a
//   single cancellable Task with a bounded heap so it stays responsive on
//   million-file home directories.
//
// TCC discipline:
//   Every traversal step calls `pathIsTCCWalled(...)` (defined in main.swift)
//   and short-circuits. We NEVER auto-scan; the user must click Scan.
//
// Cancellation:
//   The walker calls `try Task.checkCancellation()` between every batch of
//   `BigScanWalker.batchSize` (100) URLs. Cancellation propagates cleanly
//   from the toolbar "Cancel" button.
//
// Destructive operations:
//   "Move to Trash" uses `FileManager.trashItem(at:)` — recoverable, never
//   `rm`. Per-row failures surface to `SharedStore.stage.flash(...)` and
//   never crash.
//
// Cache:
//   Writes a separate `storage-deep-cache.json` next to `storage-cache.json`
//   in `~/Library/Application Support/Trove/`. Capped at top-2000 tree
//   entries per directory so the file doesn't grow without bound. Reopening
//   a previously-scanned root paints instantly.
//

import SwiftUI
import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Lens enum
// ===========================================================================

enum BigScanLens: String, CaseIterable, Hashable, Codable {
    case tree       = "Tree"
    case byType     = "By type"
    case bigFiles   = "Big files"
    case oldFiles   = "Old files"
    case duplicates = "Duplicates"
}

enum BigScanOldAge: String, CaseIterable, Hashable, Codable {
    case m6  = "> 6 months"
    case y1  = "> 1 year"
    case y2  = "> 2 years"
    case y3  = "> 3 years"
    var months: Int {
        switch self {
        case .m6: return 6
        case .y1: return 12
        case .y2: return 24
        case .y3: return 36
        }
    }
}

// ===========================================================================
// MARK: - File-type categories
// ===========================================================================

enum BigScanCategory: String, CaseIterable, Hashable, Codable {
    case images     = "Images"
    case videos     = "Videos"
    case audio      = "Audio"
    case archives   = "Archives"
    case pdfs       = "PDFs"
    case code       = "Code"
    case apps       = "Apps"
    case installers = "Installers"
    case caches     = "Caches"
    case other      = "Other"

    var symbol: String {
        switch self {
        case .images:     return "photo"
        case .videos:     return "film"
        case .audio:      return "music.note"
        case .archives:   return "archivebox"
        case .pdfs:       return "doc.richtext"
        case .code:       return "chevron.left.forwardslash.chevron.right"
        case .apps:       return "app.badge"
        case .installers: return "shippingbox"
        case .caches:     return "internaldrive"
        case .other:      return "doc"
        }
    }

    /// Classifier — extension-first (cheap), with a "caches" path-shape
    /// fallback for things like `~/Library/Caches/...` that have no
    /// distinguishing extension.
    static func classify(path: String, ext: String) -> BigScanCategory {
        let e = ext.lowercased()
        // Path-shape signal beats extension for cache-like content.
        if path.contains("/Library/Caches/") ||
           path.contains("/Caches/") ||
           path.contains("DerivedData") ||
           path.contains("/Library/Logs/") {
            return .caches
        }
        switch e {
        case "jpg","jpeg","png","gif","heic","heif","tiff","tif","bmp","webp","raw","cr2","nef","arw","dng","svg","ico":
            return .images
        case "mov","mp4","m4v","mkv","avi","webm","wmv","flv","mpg","mpeg","mts","m2ts","3gp":
            return .videos
        case "mp3","m4a","aac","wav","flac","aiff","aif","ogg","opus","wma":
            return .audio
        case "zip","tar","gz","tgz","bz2","xz","7z","rar","zst","lz","lzma","cpio","ar":
            return .archives
        case "pdf":
            return .pdfs
        case "swift","m","mm","c","cc","cpp","h","hpp","js","jsx","ts","tsx","py","rb","go","rs","java","kt","kts","sh","bash","zsh","fish","pl","php","cs","fs","scala","clj","ex","exs","r","sql","html","css","scss","sass","less","json","yaml","yml","toml","md","lock","gradle","plist","xcconfig":
            return .code
        case "app":
            return .apps
        case "dmg","pkg","mpkg","iso","img":
            return .installers
        default:
            // .app bundles arrive as files in our walker (skipsPackageDescendants),
            // but their NSString.pathExtension is "app" so caught above. .ipa is
            // technically a zip; classify as installer for clarity.
            if e == "ipa" { return .installers }
            return .other
        }
    }
}

// ===========================================================================
// MARK: - Domain types (prefixed BigScan* per spec)
// ===========================================================================

struct BigScanFile: Identifiable, Hashable, Codable {
    let path: String
    let size: Int64
    let modified: Date
    let category: BigScanCategory
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct BigScanDir: Identifiable, Hashable, Codable {
    let path: String
    let size: Int64
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// One node in the cached tree-lens view of a directory: list of children
/// (dirs + files), each with size, capped per-directory.
struct BigScanTreeNode: Codable {
    let path: String
    let totalSize: Int64
    let children: [BigScanChild]
    let computedAt: Date
}

struct BigScanChild: Codable, Hashable, Identifiable {
    let path: String
    let size: Int64
    let isDirectory: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    func asSizedItem() -> SizedItem {
        SizedItem(path: path, size: size, isDirectory: isDirectory)
    }
}

struct BigScanDuplicateGroup: Identifiable, Hashable, Codable {
    let key: String          // size + partial-hash signature
    let size: Int64          // size of one file
    let files: [String]      // absolute paths
    var id: String { key }
    var wastedBytes: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// What a scan run produces. The five lenses pull what they need from here.
struct BigScanResult: Codable {
    let root: String
    let computedAt: Date
    let elapsed: TimeInterval
    let filesScanned: Int
    let dirsScanned: Int
    let skippedNoAccess: Int
    let totalBytes: Int64

    let topBigFiles: [BigScanFile]          // sorted desc
    let topOldFiles: [BigScanFile]          // sorted desc
    let byCategory: [BigScanCategory: [BigScanFile]]   // sorted desc per cat
    let categoryTotals: [BigScanCategory: Int64]
    let duplicates: [BigScanDuplicateGroup] // sorted by wasted desc

    /// Tree cache: path → its top-N children. Built progressively while
    /// walking. Cached so re-opening a drill-down paints instantly.
    let tree: [String: BigScanTreeNode]
}

// ===========================================================================
// MARK: - Common-hogs shortcuts
// ===========================================================================

struct BigScanHogShortcut: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let symbol: String
    let path: String
    let note: String
}

enum BigScanHogs {
    static func all() -> [BigScanHogShortcut] {
        let h = NSHomeDirectory()
        return [
            BigScanHogShortcut(label: "User Caches",       symbol: "internaldrive",
                               path: "\(h)/Library/Caches", note: "Per-app caches; safe to scan"),
            BigScanHogShortcut(label: "Containers",        symbol: "shippingbox",
                               path: "\(h)/Library/Containers", note: "Sandboxed app storage"),
            BigScanHogShortcut(label: "Application Support", symbol: "puzzlepiece.extension",
                               path: "\(h)/Library/Application Support", note: "App data; review before deleting"),
            BigScanHogShortcut(label: "Xcode DerivedData", symbol: "hammer",
                               path: "\(h)/Library/Developer/Xcode/DerivedData", note: "Build artifacts; safe to delete"),
            BigScanHogShortcut(label: "iOS Simulators",    symbol: "iphone",
                               path: "\(h)/Library/Developer/CoreSimulator", note: "Simulator data; deletable from Xcode"),
            BigScanHogShortcut(label: "Mail",              symbol: "envelope",
                               path: "\(h)/Library/Mail", note: "Email archives + attachments"),
            BigScanHogShortcut(label: "Messages",          symbol: "message",
                               path: "\(h)/Library/Messages", note: "iMessage attachments (TCC-walled)"),
            BigScanHogShortcut(label: "Trash",             symbol: "trash",
                               path: "\(h)/.Trash", note: "Empty to reclaim immediately"),
            BigScanHogShortcut(label: "iOS Backups",       symbol: "externaldrive",
                               path: "\(h)/Library/Application Support/MobileSync",
                               note: "Device backups; can be huge"),
        ]
    }
}

// ===========================================================================
// MARK: - Walker (cancellable, TCC-aware)
// ===========================================================================

/// Heap-style top-N accumulator: keeps the N largest seen, drops the rest.
/// Memory bounded — critical for million-file home directories.
fileprivate struct BigScanTopN {
    let capacity: Int
    private(set) var items: [BigScanFile] = []
    private var threshold: Int64 = 0

    init(capacity: Int) { self.capacity = capacity; items.reserveCapacity(capacity + 1) }

    mutating func offer(_ f: BigScanFile) {
        if items.count < capacity {
            items.append(f); items.sort { $0.size > $1.size }
            threshold = items.last?.size ?? 0
            return
        }
        if f.size <= threshold { return }
        // Insert in sorted order, drop tail.
        items.append(f); items.sort { $0.size > $1.size }
        if items.count > capacity { items.removeLast() }
        threshold = items.last?.size ?? 0
    }
}

/// Per-directory rolling tally for the tree view. We aggregate top-K
/// children at the end and discard the rest (cap-2000 per directory).
// red-team #3: `entries` was unbounded — a directory with 1M direct files
// would accumulate 1M BigScanChild rows in memory before trimming at the end.
// We now keep a bounded min-heap of the top-K-by-size direct file children,
// dropping smaller files as we go. Subdirectory rows are still added in the
// post-pass (their count is bounded by the dir count, which we also cap).
fileprivate struct BigScanDirTally {
    let path: String
    var totalBytes: Int64 = 0
    // Bounded reservoir of the largest direct-file children seen.
    var topFiles: [BigScanChild] = []
    var topFilesThreshold: Int64 = 0
    var directFileCount: Int = 0

    mutating func offerDirectFile(_ c: BigScanChild, cap: Int) {
        directFileCount &+= 1
        if topFiles.count < cap {
            topFiles.append(c)
            topFiles.sort { $0.size > $1.size }
            topFilesThreshold = topFiles.last?.size ?? 0
            return
        }
        if c.size <= topFilesThreshold { return }
        topFiles.append(c)
        topFiles.sort { $0.size > $1.size }
        if topFiles.count > cap { topFiles.removeLast() }
        topFilesThreshold = topFiles.last?.size ?? 0
    }
}

final class BigScanWalker {

    static let batchSize = 100
    static let maxDepth = 12
    static let treeChildrenCap = 2000
    static let bigFilesCapacity = 50
    static let oldFilesCapacity = 50
    static let perCategoryCapacity = 200

    struct Progress {
        var files: Int = 0
        var dirs: Int = 0
        var bytes: Int64 = 0
        var skipped: Int = 0
    }

    /// Knobs the UI passes in.
    struct Options {
        var root: String
        var oldAge: BigScanOldAge
        var bigFilesMinBytes: Int64
        var dupesMinBytes: Int64
        var includeDuplicates: Bool
        /// P1: directory base-names to skip during the walk (e.g. node_modules, .git).
        var excludedDirNames: Set<String> = []
    }

    let options: Options
    init(options: Options) { self.options = options }

    /// Run the deep walk. Throws `CancellationError` if the caller cancels.
    func run(progress: @escaping (Progress) -> Void) async throws -> BigScanResult {
        let started = ContinuousClock.now
        var prog = Progress()

        // Top-N heaps
        var topBig = BigScanTopN(capacity: BigScanWalker.bigFilesCapacity)
        var topOld = BigScanTopN(capacity: BigScanWalker.oldFilesCapacity)
        // Per-category heap (each capped) + totals
        var catItems: [BigScanCategory: BigScanTopN] = [:]
        for c in BigScanCategory.allCases {
            catItems[c] = BigScanTopN(capacity: BigScanWalker.perCategoryCapacity)
        }
        var catTotal: [BigScanCategory: Int64] = [:]

        // Tree: per-directory rolling sums.
        var dirs: [String: BigScanDirTally] = [:]

        // Duplicate candidate grouping: bucket files by (size, ext) cheaply
        // first; later we partial-hash only buckets with >=2 entries.
        var sizeBuckets: [Int64: [BigScanFile]] = [:]

        // The age cutoff is computed once.
        let cal = Calendar(identifier: .gregorian)
        let ageCutoff: Date = cal.date(byAdding: .month, value: -options.oldAge.months, to: Date()) ?? Date.distantPast

        // red-team #11: root may be a symlink. Resolve to its real path so the
        // tree dictionary keys line up with child immediate-parent strings the
        // walker yields (children come back as resolved paths from the
        // enumerator). Without this, the root tally would be orphaned and the
        // tree-lens "root" view would show an empty list.
        let resolvedRoot = ((options.root as NSString)
            .resolvingSymlinksInPath as NSString).standardizingPath
        let rootURL = URL(fileURLWithPath: resolvedRoot, isDirectory: true)
        // Use the resolved path everywhere downstream so dict lookups match.
        let rootPath = resolvedRoot

        // Seed root tally so even an empty root still appears in the tree.
        dirs[rootPath] = BigScanDirTally(path: rootPath)

        // Pre-flight: short-circuit if root itself is TCC-walled.
        if pathIsTCCWalled(rootPath) {
            throw NSError(domain: "BigScan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That folder is protected by macOS privacy (TCC)."])
        }

        // red-team #11: also refuse to scan if the root doesn't exist or isn't
        // a directory (the enumerator would silently return a no-op walker,
        // leaving the user wondering why nothing scanned).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir),
              isDir.boolValue else {
            throw NSError(domain: "BigScan", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Not a directory: \(rootPath)"])
        }

        let resourceKeys: [URLResourceKey] = [
            .fileSizeKey, .isDirectoryKey, .isRegularFileKey,
            .isSymbolicLinkKey, .contentModificationDateKey
        ]

        guard let walker = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                // Per-URL errors → we just skip and count.
                return true
            }
        ) else {
            throw NSError(domain: "BigScan", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open \(options.root)"])
        }

        var batchCounter = 0

        for case let url as URL in walker {
            batchCounter += 1
            if batchCounter % BigScanWalker.batchSize == 0 {
                try Task.checkCancellation()
                progress(prog)
            }

            // Depth guard — skipDescendants if we get pathologically deep.
            if walker.level > BigScanWalker.maxDepth {
                walker.skipDescendants()
                continue
            }

            let path = url.path

            // TCC skip — silent, before any attribute read that could prompt.
            // red-team #1: belt-and-suspenders. `.skipsPackageDescendants`
            // *should* prevent descent into .photoslibrary, .musiclibrary,
            // .tvlibrary, .app, etc., but only if LaunchServices has those
            // UTIs registered (Photos.app uninstalled = .photoslibrary may
            // not be flagged as a package). pathIsTCCWalled covers the
            // suffix-based fallback so we never enter and never trigger
            // a TCC prompt by reading attributes inside the bundle.
            if pathIsTCCWalled(path) {
                walker.skipDescendants()
                continue
            }

            // P1: exclude user-specified directory names (node_modules, .git, build…).
            // Check the last path component — no attribute read needed.
            if !options.excludedDirNames.isEmpty {
                let baseName = (path as NSString).lastPathComponent
                if options.excludedDirNames.contains(baseName) {
                    prog.skipped += 1
                    walker.skipDescendants()
                    continue
                }
            }

            let rv: URLResourceValues
            do {
                rv = try url.resourceValues(forKeys: Set(resourceKeys))
            } catch {
                prog.skipped += 1
                continue
            }

            // Never follow symlinks (cycle protection).
            if rv.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }

            if rv.isDirectory == true {
                prog.dirs += 1
                if dirs[path] == nil { dirs[path] = BigScanDirTally(path: path) }
                // We aggregate child sizes when we encounter the parent below.
                continue
            }

            guard rv.isRegularFile == true else { continue }

            let size = Int64(rv.fileSize ?? 0)
            let modified = rv.contentModificationDate ?? Date.distantPast
            let ext = (path as NSString).pathExtension
            let cat = BigScanCategory.classify(path: path, ext: ext)
            let f = BigScanFile(path: path, size: size, modified: modified, category: cat)

            prog.files += 1
            prog.bytes &+= size

            // By type
            catItems[cat]?.offer(f)
            catTotal[cat, default: 0] &+= size

            // Big files (only worth offering if it could clear current threshold).
            if size >= options.bigFilesMinBytes { topBig.offer(f) }

            // Old files
            if modified <= ageCutoff { topOld.offer(f) }

            // Duplicates pre-bucket — cheap; only files above min size
            if options.includeDuplicates && size >= options.dupesMinBytes {
                sizeBuckets[size, default: []].append(f)
            }

            // Tree roll-up: charge this file's BYTES to every ancestor up to
            // root (so a parent's totalBytes covers its whole subtree), but
            // only add the BigScanChild row to the IMMEDIATE parent. Otherwise
            // a deep file would get N copies in N ancestor `entries` arrays,
            // blowing up memory on big trees.
            let immediateParent = (path as NSString).deletingLastPathComponent
            var anc = immediateParent
            var addedRow = false
            // red-team: previously `while !anc.isEmpty, anc != "/"` excluded
            // the root "/" entirely — a scan of "/" would attribute zero bytes
            // to the tree. Stop on the parent of root instead, and detect
            // fixed-point via `next == anc`.
            while !anc.isEmpty {
                if var tally = dirs[anc] {
                    tally.totalBytes &+= size
                    if !addedRow && anc == immediateParent {
                        // red-team #3: bounded reservoir replaces unbounded
                        // entries.append. Cap matches treeChildrenCap so the
                        // post-pass trim is a no-op for files (subdir rows
                        // are added separately and the combined list is
                        // re-capped below).
                        tally.offerDirectFile(
                            BigScanChild(path: path, size: size, isDirectory: false),
                            cap: BigScanWalker.treeChildrenCap
                        )
                        addedRow = true
                    }
                    dirs[anc] = tally
                }
                if anc == rootPath { break }
                let next = (anc as NSString).deletingLastPathComponent
                if next == anc { break }
                anc = next
            }
        }

        try Task.checkCancellation()

        // Second pass for tree: also charge each directory's own size into
        // its parent's running totals (so a parent's total includes
        // grand-children rolled through us above).
        // (Already done file-by-file; nothing more to do for sizes.)

        // Trim tree per spec: top-2000 children per directory, sorted desc.
        // red-team #3: the previous implementation was O(D²) — for every dir,
        // it scanned every other dir to find children. On a 100k-directory
        // home folder that's 10B iterations and a multi-minute freeze. Build
        // a parent→[subdir] index in one pass instead.
        var subdirsByParent: [String: [BigScanChild]] = [:]
        subdirsByParent.reserveCapacity(dirs.count)
        for (subPath, sub) in dirs where subPath != rootPath {
            // The immediate parent of a tracked subdir is some path that may
            // or may not itself be tracked; if not, skip — it's an orphan
            // (e.g. parent was TCC-walled and we skipped descendants of it).
            let par = (subPath as NSString).deletingLastPathComponent
            subdirsByParent[par, default: []].append(
                BigScanChild(path: subPath, size: sub.totalBytes, isDirectory: true)
            )
        }

        var treeOut: [String: BigScanTreeNode] = [:]
        // red-team #13: also bound the total number of tree nodes we persist
        // to the cache. With millions of directories a single home scan could
        // serialize a >100 MB JSON file. Cap at 5000 dirs sorted by totalBytes
        // (the biggest ones — the only ones the UI is likely to drill into).
        let maxTreeDirs = 5000
        let dirRanking = dirs
            .sorted { $0.value.totalBytes > $1.value.totalBytes }
            .prefix(maxTreeDirs)
            .map { $0.key }
        let dirKeepSet = Set(dirRanking)
        // Always keep the scan root so the initial drill-in view exists.
        var trimmedDirKeys = dirKeepSet
        trimmedDirKeys.insert(rootPath)

        for dirPath in trimmedDirKeys {
            try Task.checkCancellation()
            guard let tally = dirs[dirPath] else { continue }
            var direct = tally.topFiles
            if let subs = subdirsByParent[dirPath] {
                direct.append(contentsOf: subs)
            }
            direct.sort { $0.size > $1.size }
            if direct.count > BigScanWalker.treeChildrenCap {
                direct = Array(direct.prefix(BigScanWalker.treeChildrenCap))
            }
            treeOut[dirPath] = BigScanTreeNode(path: dirPath,
                                               totalSize: tally.totalBytes,
                                               children: direct,
                                               computedAt: Date())
        }

        // Duplicates: only pay for hashes inside buckets ≥ 2 entries.
        // red-team #3 / #9: bound work per bucket so a pathological case
        // (10k files all reporting the same size, e.g. zero-byte placeholders)
        // can't tie us up reading 10k files of partial hashes. Cancellation
        // checks now run per-file inside the inner loops too.
        var dupeGroups: [BigScanDuplicateGroup] = []
        let maxFilesPerSizeBucket = 512
        if options.includeDuplicates {
            for (size, rawBucket) in sizeBuckets where rawBucket.count >= 2 {
                try Task.checkCancellation()
                // Cap bucket — sort by path for stability so reruns are
                // deterministic, then take the head.
                let bucket: [BigScanFile] = rawBucket.count > maxFilesPerSizeBucket
                    ? Array(rawBucket.sorted { $0.path < $1.path }.prefix(maxFilesPerSizeBucket))
                    : rawBucket
                // Compute partial hash per file.
                var byHash: [String: [BigScanFile]] = [:]
                for f in bucket {
                    try Task.checkCancellation()
                    if let h = Self.partialHash(path: f.path, size: size) {
                        byHash[h, default: []].append(f)
                    }
                }
                for (h, group) in byHash where group.count >= 2 {
                    try Task.checkCancellation()
                    // Spec: if 3+ candidates partial-match, do a full hash to
                    // reduce false-positive risk.
                    if group.count >= 3 {
                        var byFull: [String: [BigScanFile]] = [:]
                        for f in group {
                            try Task.checkCancellation()
                            if let full = Self.fullHash(path: f.path) {
                                byFull[full, default: []].append(f)
                            }
                        }
                        for (fullKey, sub) in byFull where sub.count >= 2 {
                            dupeGroups.append(BigScanDuplicateGroup(
                                key: "\(size)-\(h)-\(fullKey)",
                                size: size,
                                files: sub.map { $0.path }
                            ))
                        }
                    } else {
                        dupeGroups.append(BigScanDuplicateGroup(
                            key: "\(size)-\(h)",
                            size: size,
                            files: group.map { $0.path }
                        ))
                    }
                }
            }
            dupeGroups.sort { $0.wastedBytes > $1.wastedBytes }
            // red-team #13: cap dupe groups to a sensible top-N for the UI
            // and for cache file size. 500 groups is plenty to act on.
            if dupeGroups.count > 500 {
                dupeGroups = Array(dupeGroups.prefix(500))
            }
        }

        // Build category outputs.
        var byCategory: [BigScanCategory: [BigScanFile]] = [:]
        for (cat, heap) in catItems { byCategory[cat] = heap.items }

        let result = BigScanResult(
            root: options.root,
            computedAt: Date(),
            elapsed: (ContinuousClock.now - started).timeInterval,
            filesScanned: prog.files,
            dirsScanned: prog.dirs,
            skippedNoAccess: prog.skipped,
            totalBytes: prog.bytes,
            topBigFiles: topBig.items,
            topOldFiles: topOld.items.sorted { $0.size > $1.size },
            byCategory: byCategory,
            categoryTotals: catTotal,
            duplicates: dupeGroups,
            tree: treeOut
        )
        progress(prog)
        return result
    }

    // -----------------------------------------------------------------------
    // MARK: Hashing helpers
    // -----------------------------------------------------------------------

    /// First 1 MB + last 1 MB + size, hashed with SHA-256. Skips full-file
    /// reads to keep duplicate detection fast on huge media files.
    // red-team: cooperative cancellation. Partial-hash reads can be tens of MB
    // when a duplicate bucket lights up across dozens of huge files; a Cancel
    // mid-flight should bail before we touch another sector.
    fileprivate static func partialHash(path: String, size: Int64) -> String? {
        if Task.isCancelled { return nil }
        let chunk: Int64 = 1024 * 1024
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        // Mix size in so two empty files of different reported sizes don't
        // collide (defense in depth).
        var s = size
        withUnsafeBytes(of: &s) { hasher.update(bufferPointer: $0) }
        do {
            try fh.seek(toOffset: 0)
            if let head = try fh.read(upToCount: Int(min(chunk, max(size, 0)))) {
                hasher.update(data: head)
            }
            if size > chunk {
                if Task.isCancelled { return nil }
                let tailOffset = UInt64(max(Int64(0), size - chunk))
                try fh.seek(toOffset: tailOffset)
                if let tail = try fh.read(upToCount: Int(chunk)) {
                    hasher.update(data: tail)
                }
            }
        } catch {
            return nil
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Full-file SHA-256, used only for groups of 3+ partial-hash matches.
    // red-team #9: previously this loop could read tens of GB without ever
    // checking for cancellation — cancelling a scan during dupe-grouping of
    // huge video files would hang the cancel button. We now check
    // `Task.isCancelled` between chunks and bail out cleanly. A nil return
    // means "give up on this file" which is correct fallback behavior.
    fileprivate static func fullHash(path: String) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        let chunk = 1024 * 1024
        do {
            while true {
                if Task.isCancelled { return nil }
                let data = try fh.read(upToCount: chunk) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #if TROVE_TESTING
    static func _t_partialHash(path: String, size: Int64) -> String? { partialHash(path: path, size: size) }
    static func _t_fullHash(path: String) -> String? { fullHash(path: path) }
    #endif
}

// ===========================================================================
// MARK: - On-disk cache (separate file from StorageCache to avoid coupling)
// ===========================================================================

fileprivate struct BigScanCacheRoot: Codable {
    var version: Int
    /// Keyed by absolute root path. Most recent only per root.
    var byRoot: [String: BigScanResult]
}

final class BigScanCache {
    static let shared = BigScanCache()

    private let schemaVersion = 1
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "trove.bigscan.io")
    private var pendingWrite: DispatchWorkItem?
    private var root: BigScanCacheRoot
    private let fileURL: URL
    private let dirURL: URL
    private var terminateObserver: NSObjectProtocol?

    private init() {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = appSup.appendingPathComponent("Trove", isDirectory: true)
        self.dirURL = dir
        self.fileURL = dir.appendingPathComponent("storage-deep-cache.json")
        self.root = BigScanCacheRoot(version: schemaVersion, byRoot: [:])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadOrQuarantine()
        // Fix 6: force-flush the cache on app quit — same pattern as NoteStore.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: .troveWillTerminate, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
            let snap = self.root
            self.lock.unlock()
            self.ioQueue.sync { self.writeAtomically(snap) }
        }
    }

    deinit {
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
    }

    func loaded(rootPath: String) -> BigScanResult? {
        lock.lock(); defer { lock.unlock() }
        return root.byRoot[rootPath]
    }

    func save(rootPath: String, result: BigScanResult) {
        lock.lock()
        root.byRoot[rootPath] = result
        lock.unlock()
        scheduleWrite()
    }

    // -----------------------------------------------------------------------

    private func loadOrQuarantine() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        // security: reject oversized cache files to prevent OOM — 32 MB cap
        // mirrors storage_cache.swift:183.
        let maxCacheBytes = 32 * 1024 * 1024
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let sz = attrs[.size] as? NSNumber, sz.intValue > maxCacheBytes {
            quarantine("oversized (\(sz.intValue) bytes)"); return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let r = try dec.decode(BigScanCacheRoot.self, from: data)
            guard r.version == schemaVersion else {
                quarantine("version \(r.version)"); return
            }
            self.root = r
        } catch {
            quarantine("decode: \(error.localizedDescription)")
        }
    }

    private func quarantine(_ reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let dest = dirURL.appendingPathComponent("storage-deep-cache-corrupt-\(ts).json")
        try? FileManager.default.moveItem(at: fileURL, to: dest)
        NSLog("BigScanCache: quarantined (\(reason)) -> \(dest.path)")
    }

    private func scheduleWrite() {
        // red-team: same race fix StorageCache landed — pendingWrite was
        // mutated from arbitrary caller threads (save() may come from any
        // background task). Guard cancel + assign under `lock` so two
        // concurrent saves can't both leak un-cancelled work items.
        lock.lock()
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); let snap = self.root; self.lock.unlock()
            self.writeAtomically(snap)
        }
        pendingWrite = work
        lock.unlock()
        ioQueue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func writeAtomically(_ snapshot: BigScanCacheRoot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        // red-team: clean up the tmp file on any failure path — orphans would
        // otherwise accumulate on every save error (full disk, EPERM, etc.).
        var tmpURL: URL?
        do {
            try FileManager.default.createDirectory(at: dirURL,
                                                    withIntermediateDirectories: true)
            let data = try enc.encode(snapshot)
            let tmp = dirURL.appendingPathComponent("storage-deep-cache-\(UUID().uuidString).tmp")
            tmpURL = tmp
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            tmpURL = nil
        } catch {
            if let t = tmpURL { try? FileManager.default.removeItem(at: t) }
            DispatchQueue.main.async {
                SharedStore.stage.flash("Deep cache save failed: \(error.localizedDescription)")
            }
        }
    }
}

// ===========================================================================
// MARK: - Time Machine snapshots probe
// ===========================================================================

struct BigScanSnapshot: Identifiable, Hashable {
    let id = UUID()
    let name: String
}

enum BigScanSnapshots {
    /// Reads `tmutil listlocalsnapshots /`. Returns [] on any error.
    // red-team #6: previous parsing kept the leading "* " prefix that tmutil
    // prints on older macOS versions, and didn't tolerate "No local
    // snapshots." text. Strip any leading "* " or "- " bullet, ignore the
    // "Snapshots for ..." header, and skip empty / informational lines.
    // red-team-sec: arguments are literal constants — no user-controlled
    // string ever reaches argv, so shell injection isn't possible here. We
    // also stick to executableURL (no shell interposed) which means each
    // argv element is delivered to tmutil as-is without re-parsing.
    static func list() -> [BigScanSnapshot] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let out = Pipe(); p.standardOutput = out
        // red-team: don't leak tmutil's stderr to the parent — under sandboxed
        // CI it can spew "Could not access /" messages that pollute the
        // process log. Discard explicitly to a per-call Pipe.
        let err = Pipe(); p.standardError = err
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // red-team: also drain stderr to its EOF so a verbose tmutil run can't
        // fill the 64 KB pipe buffer and wedge `waitUntilExit`.
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExitOffMain()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var t = String(line).trimmingCharacters(in: .whitespaces)
                // Strip any list-bullet style prefix tmutil might emit.
                while t.hasPrefix("* ") || t.hasPrefix("- ") {
                    t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                return t
            }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("Snapshots for") }
            .filter { !$0.lowercased().contains("no local snapshots") }
            // Real snapshots are dotted identifiers; defensively keep only
            // lines that look like one (contain "com.apple" or a date prefix).
            .filter { $0.contains("com.apple") || $0.first?.isNumber == true }
            .map(BigScanSnapshot.init(name:))
    }

    /// Aggressively thins to `purgeMin` GB free. We pass purgeMin=0 and
    /// urgency=4 to ask the OS to free as much as it can right now.
    /// Returns the raw `tmutil` output for transparency.
    // red-team-sec: clamp urgency to tmutil's documented 1...4 range before
    // stringifying into argv. The UI picker only emits 1/2/4 today, but a
    // future caller (CLI subcommand, AppleScript, MCP tool) could pass
    // anything; tmutil accepts only 1-4 and rejects other values, but we'd
    // rather guarantee a sensible default than rely on the tool's own
    // validation. Clamp + log when out of range.
    static func thin(urgency: Int) -> String {
        let safeUrgency = max(1, min(4, urgency))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["thinlocalsnapshots", "/", "0", String(safeUrgency)]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return "tmutil launch failed: \(error.localizedDescription)" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExitOffMain()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// ===========================================================================
// MARK: - BigScanView — the pane the caller wires up
// ===========================================================================

public struct BigScanView: View {

    public init() {}

    // ---- Inputs ----
    @State private var path: String = NSHomeDirectory()
    @State private var lens: BigScanLens = .tree
    @State private var bigMinMB: Double = 50
    @State private var oldAge: BigScanOldAge = .y1
    @State private var dupesMinMB: Double = 1

    // P1: compute duplicates only when explicitly requested (expensive hashing)
    @State private var computeDuplicates: Bool = false

    // P1: exclude common noise dirs from scan
    @State private var excludedDirNames: Set<String> = ["node_modules", ".git", "build", ".build", "DerivedData"]
    @State private var showExcludeEditor: Bool = false

    // P1: sort + filter controls for big/old file lenses
    @State private var fileSortAscending: Bool = false
    @State private var fileFilterText: String = ""

    // P1: show-more caps for big/old lenses (start at 50, raise to 200)
    @State private var bigFilesShowCount: Int = 50
    @State private var oldFilesShowCount: Int = 50

    // ---- Scan state ----
    @State private var result: BigScanResult?
    @State private var loading: Bool = false
    @State private var progress: BigScanWalker.Progress = .init()
    @State private var startedAt: Date?
    @State private var task: Task<Void, Never>?

    // ---- Tree drill-in (breadcrumb stack of paths from scan root) ----
    @State private var crumbs: [String] = []

    // ---- Per-row selection ----
    @State private var selectedPath: String?
    @State private var trashConfirm: BigScanTrashConfirm?

    // ---- By-type expansion ----
    @State private var expandedCategory: BigScanCategory?
    // Memoized sorted category list, recomputed only when result changes.
    @State private var sortedCategories: [(BigScanCategory, Int64)] = []

    // ---- Snapshots (Time Machine) ----
    @State private var snapshots: [BigScanSnapshot] = []
    @State private var thinUrgency: Int = 1
    // red-team #7: explicit confirm before destroying snapshots, especially
    // urgency=4 which asks the OS to purge as much as possible.
    @State private var confirmThin: Bool = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                rootCard
                if result == nil && !loading {
                    hogsCard
                    snapshotsCard
                }
                lensControls
                resultsCard
            }
            .padding(24)
        }
        .navigationTitle("Deep Scan")
        .navigationSubtitle(navSubtitle)
        // EXPLICITLY no .onAppear { scan() } — spec forbids auto-scan.
        // Reseed from cache on root change, but never start a scan.
        .onChange(of: path) { _ in reseedFromCache(); crumbs = [] }
        // P1: reset show-more caps when lens changes
        .onChange(of: lens) { _ in bigFilesShowCount = 50; oldFilesShowCount = 50 }
        .onChange(of: result?.computedAt) { _ in
            let totals = result?.categoryTotals ?? [:]
            sortedCategories = BigScanCategory.allCases
                .map { ($0, totals[$0] ?? 0) }
                .sorted { $0.1 > $1.1 }
        }
        // red-team: cancel an in-flight scan if the Mac is about to sleep so
        // an 8h suspend doesn't leave a stale walker running across wake.
        .onReceive(NotificationCenter.default.publisher(for: .troveSystemWillSleep)) { _ in
            cancelScanForSleep()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if loading {
                    Button(role: .destructive) { cancelScan() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Cancel scan (Esc or ⌘.)")
                    // mirror ⌘. → cancel via a hidden zero-size button; SwiftUI
                    // only honors one .keyboardShortcut per Button.
                    Button("") { cancelScan() }
                        .keyboardShortcut(".", modifiers: [.command])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                } else {
                    Button { startScan() } label: {
                        Label("Scan", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                Button {
                    revealSelection()
                } label: { Label("Reveal", systemImage: "arrow.up.right.square") }
                    .disabled(selectedPath == nil)
                Button(role: .destructive) {
                    if let p = selectedPath {
                        trashConfirm = BigScanTrashConfirm(paths: [p])
                    }
                } label: { Label("Trash", systemImage: "trash") }
                    .disabled(selectedPath == nil)
            }
        }
        .confirmationDialog(
            trashConfirm.map { "Move \($0.paths.count) item\($0.paths.count == 1 ? "" : "s") to Trash?" } ?? "",
            isPresented: Binding(
                get: { trashConfirm != nil },
                set: { if !$0 { trashConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let c = trashConfirm { performTrash(paths: c.paths) }
                trashConfirm = nil
            }
            Button("Cancel", role: .cancel) { trashConfirm = nil }
        } message: {
            if let c = trashConfirm {
                Text(c.paths.prefix(5).joined(separator: "\n") +
                     (c.paths.count > 5 ? "\n…and \(c.paths.count - 5) more" : ""))
            } else { EmptyView() }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Sub-views
    // -----------------------------------------------------------------------

    private var rootCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass.circle").foregroundStyle(.secondary)
                    TextField("Folder to analyze", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disableAutocorrection(true)
                    Button("Choose…") { pickRoot() }
                    Menu("Quick") {
                        Button("Home")      { path = NSHomeDirectory() }
                        Button("Downloads") { path = "\(NSHomeDirectory())/Downloads" }
                        Button("Desktop")   { path = "\(NSHomeDirectory())/Desktop" }
                        Button("Documents") { path = "\(NSHomeDirectory())/Documents" }
                        Button("Library")   { path = "\(NSHomeDirectory())/Library" }
                    }
                }
                if !crumbs.isEmpty {
                    BigScanBreadcrumb(crumbs: crumbs, root: path) { idx in
                        // Pop crumbs after idx
                        crumbs = Array(crumbs.prefix(idx + 1))
                    } onRoot: {
                        crumbs = []
                    }
                }
                statusRow
            }
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Scanning… \(progress.files) files · \(progress.dirs) dirs · \(progress.bytes.human)")
                        .font(.callout).foregroundStyle(.secondary)
                    if progress.skipped > 0 {
                        Text("· \(progress.skipped) skipped (no access)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    if let s = startedAt {
                        Text("· \(elapsedString(since: s))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } else if let r = result {
                    Text("\(r.filesScanned) files · \(r.dirsScanned) dirs · \(r.totalBytes.human) · \(String(format: "%.1fs", r.elapsed))")
                        .font(.callout).foregroundStyle(.secondary)
                    if r.skippedNoAccess > 0 {
                        Text("· \(r.skippedNoAccess) skipped").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Pick a folder and hit Scan. Nothing runs until you do.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // P1: stale-cache infobar — shown when painting cached results
            if !loading, let r = result {
                let age = -r.computedAt.timeIntervalSinceNow
                if age > 300 {   // stale after 5 minutes
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(Color.troveWarning)
                        Text("Cached \(StorageCacheAge.describe(r.computedAt)) — Scan to refresh")
                            .font(.caption).foregroundStyle(Color.troveWarning)
                        Spacer()
                    }
                }
            }

            // P1: proportional stacked bar breakdown by category
            if !loading, let r = result, r.totalBytes > 0 {
                BigScanStackedBar(categoryTotals: r.categoryTotals, totalBytes: r.totalBytes)
                    .frame(height: 12)
                    .padding(.top, 2)
            }
        }
    }

    private var hogsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Common disk hogs").headerText()
                Text("Tap one to set it as the scan root, then click Scan.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(BigScanHogs.all()) { h in
                        Button {
                            path = h.path
                            SharedStore.stage.flash("Root set: \(h.label)")
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: h.symbol)
                                    .foregroundStyle(.tint).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.label).font(.body)
                                    Text(h.note).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.troveCardSolid.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var snapshotsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Time Machine local snapshots").headerText()
                    Spacer()
                    Button("Refresh") {
                        Task { snapshots = await Task.detached { BigScanSnapshots.list() }.value }
                    }
                }
                if snapshots.isEmpty {
                    Text("No snapshots listed (or tmutil unavailable). Click Refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(snapshots.count) local snapshot\(snapshots.count == 1 ? "" : "s") found. These can occupy tens of GB without showing up in a normal file walk.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(snapshots.prefix(5)) { s in
                        Text(s.name).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if snapshots.count > 5 {
                        Text("…and \(snapshots.count - 5) more").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Picker("Urgency", selection: $thinUrgency) {
                        Text("Gentle (1)").tag(1)
                        Text("Normal (2)").tag(2)
                        Text("Aggressive (4)").tag(4)
                    }.frame(width: 220)
                    Spacer()
                    Button("Thin local snapshots") {
                        // red-team #7: gate behind an explicit confirm. The
                        // operation is irrecoverable — once tmutil deletes a
                        // snapshot the user cannot get it back without a
                        // restore from Time Machine.
                        confirmThin = true
                    }
                }
            }
        }
        .confirmationDialog(
            thinUrgency >= 4
                ? "Aggressively thin Time Machine snapshots?"
                : "Thin Time Machine snapshots?",
            isPresented: $confirmThin,
            titleVisibility: .visible
        ) {
            Button(thinUrgency >= 4 ? "Purge as much as possible" : "Thin",
                   role: .destructive) {
                let u = thinUrgency
                Task {
                    let out = await Task.detached { BigScanSnapshots.thin(urgency: u) }.value
                    await MainActor.run {
                        SharedStore.stage.flash("Snapshots thinned: \(out.prefix(80))")
                        Task { snapshots = await Task.detached { BigScanSnapshots.list() }.value }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(thinUrgency >= 4
                 ? "Urgency 4 asks macOS to delete as many local snapshots as it can right now. This cannot be undone."
                 : "macOS will delete local snapshots up to the chosen urgency. This cannot be undone.")
        }
    }

    private var lensControls: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Lens", selection: $lens) {
                    ForEach(BigScanLens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                lensSpecificControls

                // P1: exclude list + duplicates checkbox
                Divider().padding(.vertical, 2)
                HStack(spacing: 12) {
                    Toggle(isOn: $computeDuplicates) {
                        Text("Always compute duplicates")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .help("Compute duplicate hashes even outside the Duplicates lens (slow on large trees)")

                    Spacer()

                    Button {
                        showExcludeEditor.toggle()
                    } label: {
                        Label("Exclude \(excludedDirNames.count) dir\(excludedDirNames.count == 1 ? "" : "s")",
                              systemImage: "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .popover(isPresented: $showExcludeEditor) {
                        BigScanExcludeEditor(excluded: $excludedDirNames)
                    }
                }

                // P1: sort + filter for file lenses
                if [.bigFiles, .oldFiles].contains(lens) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                        TextField("Filter by name", text: $fileFilterText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Spacer()
                        Button {
                            fileSortAscending.toggle()
                        } label: {
                            Label(fileSortAscending ? "Smallest first" : "Largest first",
                                  systemImage: fileSortAscending ? "arrow.up" : "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lensSpecificControls: some View {
        switch lens {
        case .tree, .byType:
            EmptyView()
        case .bigFiles:
            HStack {
                Text("Minimum size").foregroundStyle(.secondary)
                Slider(value: $bigMinMB, in: 5...500, step: 5)
                    .frame(maxWidth: 360)
                Text("\(Int(bigMinMB)) MB").monospacedDigit().frame(width: 70, alignment: .trailing)
            }
        case .oldFiles:
            Picker("Older than", selection: $oldAge) {
                ForEach(BigScanOldAge.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
        case .duplicates:
            HStack {
                Text("Skip files smaller than").foregroundStyle(.secondary)
                Slider(value: $dupesMinMB, in: 0.1...100, step: 0.1)
                    .frame(maxWidth: 360)
                Text("\(String(format: "%.1f", dupesMinMB)) MB").monospacedDigit().frame(width: 80, alignment: .trailing)
                Spacer()
                Text("Run Scan again after changing this.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var resultsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(lens.rawValue).headerText()
                    Spacer()
                }
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Still scanning…").foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                } else if result == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No scan yet")
                            .headerText()
                        Text("Big Scan walks the folder above and surfaces what's actually eating disk — top hogs by size, oldest files, duplicates, and per-category totals. Time Machine snapshots and privacy-protected folders are flagged separately.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 420)
                            .multilineTextAlignment(.center)
                        Button {
                            startScan()
                        } label: {
                            Label("Start scan", systemImage: "play.fill")
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    lensContent
                }
            }
        }
    }

    @ViewBuilder
    private var lensContent: some View {
        switch lens {
        case .tree:       treeLens
        case .byType:     byTypeLens
        case .bigFiles:   bigFilesLens
        case .oldFiles:   oldFilesLens
        case .duplicates: duplicatesLens
        }
    }

    // ---- Tree lens ----------------------------------------------------------

    private var treeLens: some View {
        let activePath = crumbs.last ?? path
        let node = result?.tree[activePath]
        let kids = node?.children ?? []
        let max = kids.first?.size ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            if kids.isEmpty {
                Text("No entries (empty folder, or macOS blocked access to everything here).")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(kids) { c in
                    BigScanTreeRow(child: c, maxSize: max,
                                   isSelected: selectedPath == c.path,
                                   onSelect: { selectedPath = c.path },
                                   onDrillIn: {
                                       if c.isDirectory { crumbs.append(c.path) }
                                   },
                                   onReveal: { reveal(c.path) },
                                   onTrash: { trashConfirm = BigScanTrashConfirm(paths: [c.path]) })
                }
            }
        }
    }

    // ---- By-type lens -------------------------------------------------------

    private var byTypeLens: some View {
        let cats = sortedCategories
        let maxSize = cats.first?.1 ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(cats, id: \.0) { pair in
                let (cat, total) = pair
                BigScanCategoryRow(
                    category: cat,
                    total: total,
                    maxSize: maxSize,
                    expanded: expandedCategory == cat,
                    onToggle: {
                        expandedCategory = (expandedCategory == cat) ? nil : cat
                    }
                )
                if expandedCategory == cat, let files = result?.byCategory[cat], !files.isEmpty {
                    let m = files.first?.size ?? 1
                    ForEach(files) { f in
                        BigScanFileRow(file: f, maxSize: m,
                                       isSelected: selectedPath == f.path,
                                       onSelect: { selectedPath = f.path },
                                       onReveal: { reveal(f.path) },
                                       onTrash: { trashConfirm = BigScanTrashConfirm(paths: [f.path]) })
                            .padding(.leading, 28)
                    }
                }
            }
        }
    }

    // ---- Big files lens -----------------------------------------------------

    private var bigFilesLens: some View {
        var files = result?.topBigFiles ?? []
        files = files.filter { $0.size >= Int64(bigMinMB) * 1024 * 1024 }
        // P1: text filter
        if !fileFilterText.isEmpty {
            let q = fileFilterText.lowercased()
            files = files.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        }
        // P1: sort direction
        files = fileSortAscending ? files.sorted { $0.size < $1.size } : files.sorted { $0.size > $1.size }
        let total = files.count
        // P1: show-more cap
        let shown = Array(files.prefix(bigFilesShowCount))
        let m = shown.first?.size ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            if shown.isEmpty {
                Text("No files at or above \(Int(bigMinMB)) MB in this scan.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(shown) { f in
                    BigScanFileRow(file: f, maxSize: m,
                                   isSelected: selectedPath == f.path,
                                   onSelect: { selectedPath = f.path },
                                   onReveal: { reveal(f.path) },
                                   onTrash: { trashConfirm = BigScanTrashConfirm(paths: [f.path]) })
                }
                // P1: show-more button
                if total > bigFilesShowCount {
                    Button("\(total - bigFilesShowCount) more — Show all") {
                        bigFilesShowCount = max(bigFilesShowCount + 150, total)
                    }
                    .font(.callout).buttonStyle(.borderless)
                    .foregroundStyle(Color.troveAccent)
                    .padding(.top, 4)
                }
            }
        }
    }

    // ---- Old files lens -----------------------------------------------------

    private var oldFilesLens: some View {
        var files = result?.topOldFiles ?? []
        // P1: text filter
        if !fileFilterText.isEmpty {
            let q = fileFilterText.lowercased()
            files = files.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        }
        // P1: sort direction
        files = fileSortAscending ? files.sorted { $0.size < $1.size } : files.sorted { $0.size > $1.size }
        let total = files.count
        // P1: show-more cap
        let shown = Array(files.prefix(oldFilesShowCount))
        let m = shown.first?.size ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            if shown.isEmpty {
                Text("No qualifying old files in this scan.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(shown) { f in
                    BigScanFileRow(file: f, maxSize: m,
                                   isSelected: selectedPath == f.path,
                                   onSelect: { selectedPath = f.path },
                                   onReveal: { reveal(f.path) },
                                   onTrash: { trashConfirm = BigScanTrashConfirm(paths: [f.path]) })
                }
                // P1: show-more button
                if total > oldFilesShowCount {
                    Button("\(total - oldFilesShowCount) more — Show all") {
                        oldFilesShowCount = max(oldFilesShowCount + 150, total)
                    }
                    .font(.callout).buttonStyle(.borderless)
                    .foregroundStyle(Color.troveAccent)
                    .padding(.top, 4)
                }
            }
        }
    }

    // ---- Duplicates lens ----------------------------------------------------

    private var duplicatesLens: some View {
        let groups = result?.duplicates ?? []
        let totalWasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
        return VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                Text("No duplicates detected (size + partial-hash match). If you just changed the size threshold, click Scan again.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                // Caveat: 2-file groups are matched by size + partial-hash only.
                // 3+ file groups use a full SHA-256. Verify before deleting.
                // P2: raw .orange → token
                Label("Pairs use partial-hash comparison — verify before deleting.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.troveWarning)
                HStack {
                    Text("Wasted space across \(groups.count) groups:").foregroundStyle(.secondary)
                    Text(totalWasted.human).bold()
                }
                ForEach(groups) { g in
                    BigScanDupeGroupRow(
                        group: g,
                        selectedPath: $selectedPath,
                        onReveal: { reveal($0) },
                        onTrash: { trashConfirm = BigScanTrashConfirm(paths: [$0]) },
                        onTrashAllButFirst: {
                            // Keep first, trash the rest — confirmed.
                            let rest = Array(g.files.dropFirst())
                            if !rest.isEmpty { trashConfirm = BigScanTrashConfirm(paths: rest) }
                        }
                    )
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Sub-view: nav subtitle
    // -----------------------------------------------------------------------

    private var navSubtitle: String {
        let base = (path as NSString).lastPathComponent
        if let r = result {
            return "\(base) · \(r.totalBytes.human) · cached \(StorageCacheAge.describe(r.computedAt))"
        }
        return base
    }

    // -----------------------------------------------------------------------
    // MARK: Actions
    // -----------------------------------------------------------------------

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let u = panel.url { path = u.path }
    }

    private func startScan() {
        if loading { return }
        // P1: only compute duplicates when on the Duplicates lens or the
        // checkbox is set — hashing is expensive on large trees.
        let shouldComputeDupes = (lens == .duplicates) || computeDuplicates
        let opts = BigScanWalker.Options(
            root: path,
            oldAge: oldAge,
            bigFilesMinBytes: Int64(bigMinMB) * 1024 * 1024,
            dupesMinBytes: Int64((dupesMinMB * 1024 * 1024).rounded()),
            includeDuplicates: shouldComputeDupes,
            excludedDirNames: excludedDirNames
        )
        loading = true
        progress = .init()
        startedAt = Date()
        crumbs = []
        let walker = BigScanWalker(options: opts)
        let captured = path
        task = Task {
            do {
                let r = try await walker.run { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.result = r
                    self.loading = false
                    self.task = nil
                    BigScanCache.shared.save(rootPath: captured, result: r)
                    SharedStore.stage.flash("Scan complete · \(r.totalBytes.human) across \(r.filesScanned) files")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.loading = false
                    self.task = nil
                    let n = self.progress.files
                    SharedStore.stage.flash(
                        "Scan cancelled · scanned \(n) file\(n == 1 ? "" : "s")",
                        kind: .warning
                    )
                }
            } catch {
                await MainActor.run {
                    self.loading = false
                    self.task = nil
                    // red-team: distinguish TCC-walled / permission-denied
                    // failures (where the user has a one-click fix in System
                    // Settings → Full Disk Access) from generic I/O errors.
                    // We surface the deep-link toast for TCC-shaped failures
                    // and a plain toast for anything else, so the action
                    // button is never misleading.
                    let nsErr = error as NSError
                    let isPermissionShaped =
                        (nsErr.domain == "BigScan" && nsErr.code == 1) ||
                        (nsErr.domain == NSCocoaErrorDomain
                         && (nsErr.code == NSFileReadNoPermissionError
                             || nsErr.code == NSFileReadNoSuchFileError)) ||
                        (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == 1 /* EPERM */)
                    if isPermissionShaped {
                        SharedStore.stage.flash(
                            "Scan failed: \(error.localizedDescription)",
                            kind: .warning,
                            actionLabel: "Open Settings") {
                            TCCDeepLink.fullDiskAccess.open()
                        }
                    } else {
                        SharedStore.stage.flash("Scan failed: \(error.localizedDescription)",
                                                kind: .error)
                    }
                }
            }
        }
    }

    private func cancelScan() {
        task?.cancel()
    }

    // red-team: invoked from a .onReceive(.troveSystemWillSleep) hook in
    // body. An in-flight scan crossing an 8-hour suspend would resume with
    // wildly stale FS state (paths potentially deleted, sizes changed) and
    // burn CPU on the wake side. Cleaner to cancel; cache is preserved.
    fileprivate func cancelScanForSleep() {
        if loading { task?.cancel() }
    }

    private func reseedFromCache() {
        result = BigScanCache.shared.loaded(rootPath: path)
        selectedPath = nil
    }

    private func reveal(_ p: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    private func revealSelection() {
        if let p = selectedPath { reveal(p) }
    }

    private func performTrash(paths: [String]) {
        // P1 fix: run the FileManager calls off-main (trashItem can block on
        // slow volumes / network shares), then publish results back on MainActor.
        Task {
            let (ok, failed): (Int, [String]) = await Task.detached(priority: .userInitiated) {
                var ok = 0
                var failed: [String] = []
                // red-team-sec: defense-in-depth path validation. trashItem itself
                // rejects empty strings, but a row with an unusual character (NUL,
                // newline) shouldn't reach FileManager at all — and we never want to
                // accept a relative path here even if a future code path produced
                // one. Reject before we even try.
                for p in paths {
                    guard !p.isEmpty,
                          !p.contains("\0"),
                          !p.contains("\n"),
                          (p as NSString).isAbsolutePath else {
                        failed.append("(invalid path)")
                        continue
                    }
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                        ok += 1
                    } catch {
                        failed.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (ok, failed)
            }.value

            // Back on MainActor for UI updates.
            if !failed.isEmpty {
                SharedStore.stage.flash("Trashed \(ok); \(failed.count) failed (\(failed.first ?? ""))")
            } else {
                SharedStore.stage.flash("Moved \(ok) to Trash")
            }
            if let sp = selectedPath, paths.contains(sp) { selectedPath = nil }
            // red-team: remove the trashed paths from the current in-memory
            // result tree so the rows disappear immediately. Without this, the
            // user sees "Moved N to Trash" but the rows stay visible until they
            // hit Scan again — confusing on a successful destructive op.
            if !paths.isEmpty, let r = self.result {
                let gone = Set(paths)
                var trimmedTree = r.tree
                // Snapshot keys before mutation — Swift dictionaries don't promise
                // safe in-place mutation during iteration.
                for k in Array(trimmedTree.keys) {
                    guard let node = trimmedTree[k] else { continue }
                    let kept = node.children.filter { !gone.contains($0.path) }
                    if kept.count != node.children.count {
                        trimmedTree[k] = BigScanTreeNode(path: node.path,
                                                        totalSize: node.totalSize,
                                                        children: kept,
                                                        computedAt: node.computedAt)
                    }
                }
                let filterFiles: ([BigScanFile]) -> [BigScanFile] = { $0.filter { !gone.contains($0.path) } }
                var newByCat: [BigScanCategory: [BigScanFile]] = [:]
                for (cat, files) in r.byCategory { newByCat[cat] = filterFiles(files) }
                let newDupes = r.duplicates.compactMap { g -> BigScanDuplicateGroup? in
                    let kept = g.files.filter { !gone.contains($0) }
                    if kept.count < 2 { return nil }
                    return BigScanDuplicateGroup(key: g.key, size: g.size, files: kept)
                }
                self.result = BigScanResult(
                    root: r.root, computedAt: r.computedAt, elapsed: r.elapsed,
                    filesScanned: r.filesScanned, dirsScanned: r.dirsScanned,
                    skippedNoAccess: r.skippedNoAccess, totalBytes: r.totalBytes,
                    topBigFiles: filterFiles(r.topBigFiles),
                    topOldFiles: filterFiles(r.topOldFiles),
                    byCategory: newByCat, categoryTotals: r.categoryTotals,
                    duplicates: newDupes, tree: trimmedTree)
            }
            // Don't re-scan automatically; user can hit Scan to refresh.
        }
    }

    private func elapsedString(since: Date) -> String {
        let s = Date().timeIntervalSince(since)
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60; let r = Int(s) % 60
        return "\(m)m \(r)s"
    }
}

// ===========================================================================
// MARK: - Row views & supporting structs
// ===========================================================================

fileprivate struct BigScanTrashConfirm {
    let paths: [String]
}

fileprivate struct BigScanBreadcrumb: View {
    let crumbs: [String]
    let root: String
    let onSelect: (Int) -> Void
    let onRoot: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
            Button((root as NSString).lastPathComponent) { onRoot() }
                .buttonStyle(.link)
            ForEach(Array(crumbs.enumerated()), id: \.offset) { (idx, p) in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button((p as NSString).lastPathComponent) { onSelect(idx) }
                    .buttonStyle(.link)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .font(.callout)
    }
}

fileprivate struct BigScanTreeRow: View {
    let child: BigScanChild
    let maxSize: Int64
    let isSelected: Bool
    let onSelect: () -> Void
    let onDrillIn: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: child.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name).font(.body).lineLimit(1)
                Text(child.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint.opacity(0.85))
                        .frame(width: g.size.width * (maxSize > 0 ? CGFloat(Double(child.size)/Double(maxSize)) : 0))
                }
            }
            .frame(width: 140, height: 6)
            Text(child.size.human)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
            if child.isDirectory {
                Button { onDrillIn() } label: { Image(systemName: "chevron.right.circle") }
                    .buttonStyle(.borderless).help("Drill in")
            }
            Button { onReveal() } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            Button(role: .destructive) { onTrash() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Move to Trash")
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        // P2: raw Color.accentColor → token
        .background(isSelected ? Color.troveAccent.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

fileprivate struct BigScanFileRow: View {
    let file: BigScanFile
    let maxSize: Int64
    let isSelected: Bool
    let onSelect: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.category.symbol).foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(file.path).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("· modified \(BigScanFileRow.df.string(from: file.modified))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint.opacity(0.85))
                        .frame(width: g.size.width * (maxSize > 0 ? CGFloat(Double(file.size)/Double(maxSize)) : 0))
                }
            }
            .frame(width: 140, height: 6)
            Text(file.size.human)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
            Button { onReveal() } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            Button(role: .destructive) { onTrash() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Move to Trash")
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        // P2: raw Color.accentColor → token
        .background(isSelected ? Color.troveAccent.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

fileprivate struct BigScanCategoryRow: View {
    let category: BigScanCategory
    let total: Int64
    let maxSize: Int64
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary).frame(width: 12)
            Image(systemName: category.symbol).foregroundStyle(.tint).frame(width: 18)
            Text(category.rawValue).font(.body)
            Spacer(minLength: 12)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint.opacity(0.85))
                        .frame(width: g.size.width * (maxSize > 0 ? CGFloat(Double(total)/Double(maxSize)) : 0))
                }
            }
            .frame(width: 180, height: 6)
            Text(total.human)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

// ===========================================================================
// MARK: - P1: Stacked bar breakdown (proportional per-category)
// ===========================================================================

fileprivate struct BigScanStackedBar: View {
    let categoryTotals: [BigScanCategory: Int64]
    let totalBytes: Int64

    /// Palette of token-adjacent hues — cycled per category in allCases order
    /// so the bar is visually distinctive without raw literal colours.
    private static let segmentColors: [Color] = [
        .troveAccent, .troveSuccess, .troveWarning, .troveError,
        Color(hue: 0.55, saturation: 0.7, brightness: 0.75),
        Color(hue: 0.75, saturation: 0.6, brightness: 0.80),
        Color(hue: 0.08, saturation: 0.8, brightness: 0.85),
        Color(hue: 0.33, saturation: 0.65, brightness: 0.70),
        Color(hue: 0.15, saturation: 0.7, brightness: 0.80),
        Color(hue: 0.90, saturation: 0.6, brightness: 0.75),
    ]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                let sorted = BigScanCategory.allCases
                    .enumerated()
                    .compactMap { (idx, cat) -> (BigScanCategory, Int, CGFloat)? in
                        guard let bytes = categoryTotals[cat], bytes > 0 else { return nil }
                        let fraction = CGFloat(Double(bytes) / Double(totalBytes))
                        return (cat, idx, fraction)
                    }
                    .sorted { $0.2 > $1.2 }
                ForEach(Array(sorted.enumerated()), id: \.offset) { (i, entry) in
                    let (cat, colorIdx, fraction) = entry
                    let color = Self.segmentColors[colorIdx % Self.segmentColors.count]
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .frame(width: max(1, geo.size.width * fraction))
                        .help("\(cat.rawValue): \((categoryTotals[cat] ?? 0).human)")
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

// ===========================================================================
// MARK: - P1: Exclude editor popover
// ===========================================================================

fileprivate struct BigScanExcludeEditor: View {
    @Binding var excluded: Set<String>
    @State private var newName: String = ""

    private static let presets: [String] = [
        "node_modules", ".git", "build", ".build", "DerivedData",
        ".gradle", "__pycache__", ".venv", "vendor",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclude directory names")
                .headerText()
            Text("Directories whose base-name matches are skipped entirely during scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Existing exclusions
            ForEach(Array(excluded).sorted(), id: \.self) { name in
                HStack {
                    Text(name).font(.callout.monospaced())
                    Spacer()
                    Button {
                        excluded.remove(name)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Color.troveError)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Add custom
            HStack {
                TextField("Add name…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { excluded.insert(trimmed); newName = "" }
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Presets
            Text("Common presets")
                .font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button(preset) {
                        excluded.insert(preset)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(excluded.contains(preset))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 300, idealWidth: 340)
    }
}

/// Minimal horizontal-wrapping flow layout for the preset chips.
fileprivate struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var y: CGFloat = 0; var x: CGFloat = 0; var rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing; x = bounds.minX; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

fileprivate struct BigScanDupeGroupRow: View {
    let group: BigScanDuplicateGroup
    @Binding var selectedPath: String?
    let onReveal: (String) -> Void
    let onTrash: (String) -> Void
    let onTrashAllButFirst: () -> Void

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                Image(systemName: "square.on.square").foregroundStyle(.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.files.count) copies · \(group.size.human) each")
                        .font(.body)
                    Text((group.files.first.map { ($0 as NSString).lastPathComponent } ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(group.wastedBytes.human) wasted")
                    .font(.system(.callout, design: .monospaced))
                Button(role: .destructive) {
                    onTrashAllButFirst()
                } label: { Label("Trash extras", systemImage: "trash") }
                    .help("Move all but the first copy to Trash")
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                ForEach(group.files, id: \.self) { p in
                    HStack(spacing: 10) {
                        Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 14)
                        Text(p).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { onReveal(p) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) { onTrash(p) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.leading, 30).padding(.vertical, 2)
                    // P2: raw Color.accentColor → token
                    .background(selectedPath == p ? Color.troveAccent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPath = p }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
