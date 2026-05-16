// ===========================================================================
//  outputs_library.swift — Outputs Library pane
//
//  A persistent, searchable list of every file the Trove app has produced.
//  Producers (pdf.swift, image_tools.swift, recorder.swift, …) call
//      OutputsLibrary.shared.record(url:, producer:, sourceLabel:, kind:)
//  immediately after they finish writing a file to disk. This file is
//  self-contained — types are all `Outputs*` prefixed. main.swift adds the
//  Pane case + view-switch entry separately.
//
//  Persistence: JSON at  ~/Library/Application Support/Trove/outputs-library.json
//  • atomic write (.tmp.<uuid> + replaceItemAt)
//  • 200ms debounced
//  • auto-pruned on load (entries whose file is gone)
//  • capped at 500 entries (oldest evicted)
//  • corrupt JSON → quarantined to outputs-library-corrupt-<ts>.json + flash
//
//  Re-edit hooks (Notification.Name posted by the row menu, listened-to by
//  the destination tool view):
//      "trove.openInPDFTool"     userInfo: ["url": URL, "op": String]
//      "trove.openInImageTools"  userInfo: ["url": URL]
// ===========================================================================

import SwiftUI
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Data model
// ===========================================================================

/// One row in the library — a single file produced by a Trove operation.
/// `urlPath` is a POSIX path string (not URL) so the on-disk JSON is
/// human-debuggable. `kind` is a short tag used for the row's icon and to
/// route the "Re-edit…" submenu options.
struct OutputEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let urlPath: String          // POSIX path
    let producer: String         // "pdf.merge", "image_tools.convert", "ocr.capture", "recorder", …
    let sourceLabel: String      // human note like "Combined 4 files" or original filename
    let createdAt: Date
    let bytes: Int64
    let kind: String             // "pdf" | "image" | "text" | "video" | "other"

    var url: URL { URL(fileURLWithPath: urlPath) }
}

// red-team-sec: Trusted producer directories. A hostile actor with write access
// to outputs-library.json could otherwise plant entries pointing at /etc/passwd,
// ~/.ssh/id_rsa, etc., and the user's "Open" click would launch the default
// editor on those files. Anything outside this whitelist is dropped on load.
private enum OutputsTrustedRoots {
    static let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [URL] = [
            home.appendingPathComponent("Library/Caches/Trove",      isDirectory: true),
            home.appendingPathComponent("Downloads/Trove",           isDirectory: true),
            home.appendingPathComponent("Movies/Trove",              isDirectory: true),
            home.appendingPathComponent("Pictures/Trove",            isDirectory: true),
            home.appendingPathComponent("Documents/Trove",           isDirectory: true),
        ]
        // /tmp and the per-process NSTemporaryDirectory are also trusted —
        // producers stage there before atomic-move to a user-visible folder.
        out.append(URL(fileURLWithPath: "/tmp", isDirectory: true))
        out.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        return out.map { Self.canonicalize($0) }
    }()

    /// Canonicalize a path: resolve symlinks + standardize (`..`, `.`, `//`).
    /// We use this for both the trusted-root comparison and the idempotency
    /// key in `record()`.
    static func canonicalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// True iff `url` resolves under one of the trusted producer directories.
    /// Symlink-resolved on both sides to defeat `~/Library/Caches/Trove/foo`
    /// being a symlink to `/etc/passwd`.
    static func isTrusted(_ url: URL) -> Bool {
        let resolved = canonicalize(url).path
        for root in roots {
            let rootPath = root.path
            // Require either an exact match or a "/"-bounded prefix so that
            // "/tmp_evil/..." doesn't pass the "/tmp" check.
            if resolved == rootPath { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if resolved.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// iCloud-evicted placeholder detection. macOS replaces dataless files
    /// with a hidden `.foo.icloud` stub; `FileManager.fileExists` returns
    /// true for the stub itself but the real file isn't on disk.
    static func isiCloudPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") && name.hasSuffix(".icloud") { return true }
        // Real path may exist alongside a sibling `.<name>.icloud` stub.
        let dir = url.deletingLastPathComponent()
        let sidecar = dir.appendingPathComponent(".\(name).icloud")
        return FileManager.default.fileExists(atPath: sidecar.path)
            && !FileManager.default.fileExists(atPath: url.path)
    }
}

// ===========================================================================
// MARK: - Notification names (re-edit hooks)
// ===========================================================================

extension Notification.Name {
    /// Posted by OutputsLibraryView when the user picks "Open in <op>" on a
    /// PDF row. `userInfo` is `["url": URL, "op": String]` where `op` is one
    /// of: "organize", "split", "compress", "rotate", "watermark", "crop",
    /// "pageNumbers", "protect", "unlock", "ocr", "repair", "merge".
    static let troveOpenInPDFTool = Notification.Name("trove.openInPDFTool")
    /// Posted by OutputsLibraryView when the user picks "Open in Image Tools"
    /// on an image row. `userInfo` is `["url": URL]`.
    static let troveOpenInImageTools = Notification.Name("trove.openInImageTools")
}

// ===========================================================================
// MARK: - Store
// ===========================================================================

@MainActor
final class OutputsLibrary: ObservableObject {
    static let shared = OutputsLibrary()

    @Published private(set) var entries: [OutputEntry] = []
    @Published var search: String = ""
    @Published private(set) var groupedVisible: [(producer: String, items: [OutputEntry])] = []

    private var cancellables: Set<AnyCancellable> = []

    // red-team: keep manifest small. 500 entries × ~250 bytes JSON ≈ 125 KB —
    // small enough to load synchronously on launch, big enough to outlast a
    // week of heavy use.
    static let maxEntries = 500

    // Persistence locations -----------------------------------------------
    // red-team: nonisolated so the writeQueue closure (Sendable, nonisolated)
    // can reference them without hopping back to MainActor for a static URL.
    nonisolated private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trove", isDirectory: true)
    }()
    nonisolated private static let storeURL = appSupportDir.appendingPathComponent("outputs-library.json")

    // Serial write queue so two debounced flushes can't interleave.
    private let writeQueue = DispatchQueue(label: "trove.outputs-library.write",
                                           qos: .utility)
    private var saveWork: DispatchWorkItem?

    // Terminate observer — flush before exit so the last `record(...)` makes it
    // to disk even if the user quits inside the 200ms debounce window.
    private var terminateObserver: NSObjectProtocol?

    // ---------------------------------------------------------------------
    // MARK: Init / load
    // ---------------------------------------------------------------------
    init() {
        try? FileManager.default.createDirectory(at: Self.appSupportDir,
                                                 withIntermediateDirectories: true)

        var loaded: [OutputEntry] = []
        var corruptMessage: String? = nil

        if FileManager.default.fileExists(atPath: Self.storeURL.path) {
            do {
                guard let data = boundedRead(Self.storeURL) else { throw CocoaError(.fileReadNoSuchFile) }
                loaded = try JSONDecoder().decode([OutputEntry].self, from: data)
            } catch {
                // Red-team #1: corrupt JSON → quarantine, fresh empty array, flash.
                let ts = Int(Date().timeIntervalSince1970)
                let quarantine = Self.appSupportDir
                    .appendingPathComponent("outputs-library-corrupt-\(ts).json")
                try? FileManager.default.moveItem(at: Self.storeURL, to: quarantine)
                corruptMessage = "Outputs library was unreadable — backed up to \(quarantine.lastPathComponent)"
                loaded = []
            }
        }

        // red-team-sec: a hostile JSON could contain 100k entries OR entries
        // pointing at /etc/passwd. Order matters here:
        //   1. cap BEFORE stat-ing — defends against DoS from a giant file.
        //   2. sort newest-first so a hostile actor can't push genuine recent
        //      entries off the end of the cap with stale-dated injections.
        //   3. drop anything outside the trusted-roots whitelist (sync).
        //   4. publish, then prune missing/iCloud-evicted in the background.
        // speed: dedup the raw `urlPath` synchronously (producers are well-
        // behaved so urlPath is already canonical at write time), then re-
        // dedup canonically + prune missing entries in the background. Cuts
        // pane-appear latency from ~O(n) filesystem syscalls to ~O(1) on
        // launch.
        loaded.sort { $0.createdAt > $1.createdAt }
        var rawSeen = Set<String>()
        loaded = loaded.filter { rawSeen.insert($0.urlPath).inserted }
        if loaded.count > Self.maxEntries {
            loaded = Array(loaded.prefix(Self.maxEntries))
        }
        // red-team-sec: trust check stays synchronous — never show an
        // untrusted entry, even for a frame. isTrusted does a symlink
        // resolve per entry but the cost is dwarfed by the existence stats
        // we're deferring below.
        loaded = loaded.filter { OutputsTrustedRoots.isTrusted($0.url) }

        // Publish the trusted set immediately so the pane appears with rows
        // visible. Existence pruning + canonical-path dedup happen on a
        // background task and patch `entries` when done.
        self.entries = loaded

        // speed: defer Red-team #6 (auto-prune missing) + canonical re-dedup
        // to a background task. fileExists + resolvingSymlinksInPath on 500
        // entries is the dominant launch cost; users perceive the pane as
        // instantly populated, and any rows backing missing files vanish a
        // beat later. iCloud-evicted entries are KEPT (intentional UX).
        let snapshot = loaded
        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var canonicalSeen = Set<String>()
            let pruned: [OutputEntry] = snapshot.compactMap { entry in
                let key = OutputsTrustedRoots.canonicalize(entry.url).path
                guard canonicalSeen.insert(key).inserted else { return nil }
                let exists = fm.fileExists(atPath: entry.urlPath)
                    || OutputsTrustedRoots.isiCloudPlaceholder(entry.url)
                return exists ? entry : nil
            }
            // Only mutate if anything actually changed — avoids a needless
            // @Published republish that would invalidate the list view.
            if pruned.count != snapshot.count {
                await MainActor.run {
                    guard let self = self else { return }
                    // red-team: user may have called record() during the
                    // background pass. Reconcile by id so newly-added
                    // entries aren't dropped — only prune entries present
                    // in our snapshot that didn't survive the check.
                    let survivorIDs = Set(pruned.map { $0.id })
                    let snapshotIDs = Set(snapshot.map { $0.id })
                    self.entries = self.entries.filter { e in
                        !snapshotIDs.contains(e.id) || survivorIDs.contains(e.id)
                    }
                    self.scheduleSave()
                }
            }
        }

        if let msg = corruptMessage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SharedStore.stage.flash(msg)
            }
            // Persist the clean state immediately so the broken file isn't
            // re-quarantined on the next launch (we already moved it, but the
            // empty manifest also makes intent clear).
            scheduleSave()
        }

        // Flush on quit so a "record then immediately quit" sequence never
        // loses the last entry inside the 200ms debounce. The observer
        // closure isn't @MainActor-isolated even though it runs on .main —
        // hop explicitly so Swift 6 strict isolation passes.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: .troveWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSynchronously()
            }
        }

        // Memoize grouped-visible so OutputsLibraryView.body doesn't call
        // Self.group(visible) on every render pass.
        Publishers.CombineLatest($entries, $search)
            .map { entries, query -> [(producer: String, items: [OutputEntry])] in
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let vis: [OutputEntry] = q.isEmpty ? entries : entries.filter { e in
                    let name = (e.urlPath as NSString).lastPathComponent.lowercased()
                    return name.contains(q)
                        || e.producer.lowercased().contains(q)
                        || e.sourceLabel.lowercased().contains(q)
                }
                return Self.groupByProducer(vis)
            }
            .receive(on: RunLoop.main)
            // Use the `assign(to:)` Published form — it does NOT retain self,
            // breaking the retain cycle that `.assign(to:on:).store(in:)` creates.
            .assign(to: &$groupedVisible)
    }

    /// Mirror of `OutputsLibraryView.group(_:)` so the store can drive
    /// `groupedVisible` via Combine without reaching into the view. R2
    /// hoisted the grouping into the store; this is the helper it needed.
    nonisolated private static func groupByProducer(_ entries: [OutputEntry])
        -> [(producer: String, items: [OutputEntry])] {
        var order: [String] = []
        var bucket: [String: [OutputEntry]] = [:]
        for e in entries {
            if bucket[e.producer] == nil { order.append(e.producer) }
            bucket[e.producer, default: []].append(e)
        }
        return order.map { p in (producer: p, items: bucket[p] ?? []) }
    }

    deinit {
        if let o = terminateObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Public API
    // ---------------------------------------------------------------------

    /// Record a freshly-produced file. Idempotent on canonical path: a second
    /// record() with the same (symlink-resolved + standardized) path replaces
    /// the existing entry so re-runs that overwrite a file don't bloat the
    /// manifest.
    func record(url: URL, producer: String, sourceLabel: String, kind: String) {
        // red-team-sec: refuse to record outside the trusted producer dirs.
        // Producers are in-process callers so this is a defense-in-depth
        // guardrail — keeps a buggy producer from poisoning the manifest with
        // a path the load-time filter would later drop anyway.
        guard OutputsTrustedRoots.isTrusted(url) else {
            #if DEBUG
            print("OutputsLibrary.record: refused untrusted path \(url.path)")
            #endif
            return
        }

        let canonical = OutputsTrustedRoots.canonicalize(url).path
        let bytes: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: canonical)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }()
        let entry = OutputEntry(
            id: UUID(),
            urlPath: canonical,
            producer: producer,
            sourceLabel: sourceLabel,
            createdAt: Date(),
            bytes: bytes,
            kind: kind
        )
        // red-team: compare canonical-against-canonical so a path that differs
        // only in symlinks / `.` segments / trailing slash dedupes correctly.
        entries.removeAll { existing in
            OutputsTrustedRoots.canonicalize(existing.url).path == canonical
        }
        entries.insert(entry, at: 0)

        // Red-team #2: enforce cap (oldest evicted).
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        scheduleSave()
    }

    /// Remove from the manifest AND delete the file on disk. Caller is
    /// expected to have confirmed with the user already.
    /// On delete failure (permission denied, iCloud-not-downloaded) we keep
    /// the entry in the list and flash an error so the user can retry.
    func delete(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[i]
        let url = entry.url
        do {
            // Red-team #4: file may be missing, in iCloud, or permission-denied.
            // Treat ".file already gone" as success.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            entries.remove(at: i)
            scheduleSave()
        } catch {
            SharedStore.stage.flash("Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Drop entries whose file no longer exists on disk. Doesn't touch any
    /// files. Used by the toolbar "Forget missing" button. iCloud-evicted
    /// entries are explicitly kept — they aren't missing, just dataless.
    func forgetMissing() {
        let fm = FileManager.default
        let before = entries.count
        entries.removeAll { entry in
            !fm.fileExists(atPath: entry.urlPath)
                && !OutputsTrustedRoots.isiCloudPlaceholder(entry.url)
        }
        let dropped = before - entries.count
        if dropped > 0 {
            scheduleSave()
            SharedStore.stage.flash("Forgot \(dropped) missing output\(dropped == 1 ? "" : "s")")
        } else {
            SharedStore.stage.flash("Nothing to forget — all outputs present")
        }
    }

    /// Remove ALL entries from the manifest. Does NOT delete the actual files.
    /// Caller is expected to have confirmed.
    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// Filtered + sorted view used by OutputsLibraryView.
    /// Sort: newest first (already maintained in `entries`).
    /// Filter: case-insensitive substring match against basename, producer,
    /// and sourceLabel.
    var visible: [OutputEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            let name = (e.urlPath as NSString).lastPathComponent.lowercased()
            return name.contains(q)
                || e.producer.lowercased().contains(q)
                || e.sourceLabel.lowercased().contains(q)
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Persistence
    // ---------------------------------------------------------------------

    /// Debounced save — coalesces a burst of record() calls (e.g. PDF split
    /// producing 30 part files) into a single disk write 200ms after the last
    /// mutation.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem { [weak self] in
            self?.performSave(snapshot)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Force-flush within the debounce window — invoked on willTerminate.
    /// red-team: previously called `performSave` inside `writeQueue.sync`, but
    /// `performSave` itself does `writeQueue.async { … }`, so the work was
    /// scheduled (not executed) before the app exited — defeating the entire
    /// point of "flush before quit". Call the actual write body synchronously
    /// here so the on-disk file is current when the process dies.
    private func flushSynchronously() {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = entries
        writeQueue.sync {
            Self.writeSnapshotSync(snapshot)
        }
    }

    /// Actual disk write. Atomic via .tmp.<uuid> + replaceItemAt (or moveItem
    /// when target doesn't exist yet). Runs on writeQueue serial DispatchQueue
    /// so two writes can't interleave. Errors surface via flash but leave
    /// in-memory state untouched.
    private func performSave(_ snapshot: [OutputEntry]) {
        writeQueue.async {
            Self.writeSnapshotSync(snapshot)
        }
    }

    /// Synchronous write body shared by `performSave` (async) and
    /// `flushSynchronously` (sync-on-quit). MUST be called on `writeQueue`.
    nonisolated private static func writeSnapshotSync(_ snapshot: [OutputEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: Self.appSupportDir,
                withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(snapshot)
            let tmp = Self.appSupportDir
                .appendingPathComponent("outputs-library.tmp.\(UUID().uuidString.prefix(8)).json")
            try data.write(to: tmp, options: .atomic)
            // Red-team #5: atomic replace via replaceItemAt; fall back to
            // moveItem when target doesn't yet exist.
            if FileManager.default.fileExists(atPath: Self.storeURL.path) {
                _ = try FileManager.default.replaceItemAt(Self.storeURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: Self.storeURL)
            }
            // red-team: replaceItemAt occasionally leaves the source `.tmp`
            // file behind on APFS clones. Also a crash during the rename
            // window can strand the .tmp alongside the manifest. Sweep any
            // sibling outputs-library.tmp.* on every successful write so the
            // app-support dir doesn't grow unbounded across the app's life.
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
            if let siblings = try? FileManager.default.contentsOfDirectory(
                at: Self.appSupportDir, includingPropertiesForKeys: nil) {
                for s in siblings where s.lastPathComponent
                        .hasPrefix("outputs-library.tmp.") && s != tmp {
                    try? FileManager.default.removeItem(at: s)
                }
            }
        } catch {
            let msg = "Outputs library save failed: \(error.localizedDescription)"
            DispatchQueue.main.async {
                SharedStore.stage.flash(msg)
            }
        }
    }
}

// ===========================================================================
// MARK: - Helpers
// ===========================================================================

private enum OutputsKindIcon {
    /// SF Symbol for a kind tag. Falls back to a generic doc.
    static func symbol(for kind: String) -> String {
        switch kind {
        case "pdf":   return "doc.richtext"
        case "image": return "photo"
        case "text":  return "doc.text"
        case "video": return "video"
        default:      return "doc"
        }
    }
}

/// Cached relative-date formatter — building one per-row at 60 fps wastes work.
private let outputsRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// Human label for a producer ID — used for section headers. Falls back to
/// the raw ID if we don't know it.
private func outputsProducerLabel(_ id: String) -> String {
    switch id {
    case "pdf.merge":         return "PDF — Merge"
    case "pdf.split":         return "PDF — Split"
    case "pdf.compress":      return "PDF — Compress"
    case "pdf.rotate":        return "PDF — Rotate"
    case "pdf.organize":      return "PDF — Organize"
    case "pdf.pageNumbers":   return "PDF — Page numbers"
    case "pdf.watermark":     return "PDF — Watermark"
    case "pdf.crop":          return "PDF — Crop"
    case "pdf.protect":       return "PDF — Protect"
    case "pdf.unlock":        return "PDF — Unlock"
    case "pdf.toJPG":         return "PDF — Render JPG"
    case "pdf.toPNG":         return "PDF — Render PNG"
    case "pdf.imagesToPDF":   return "PDF — Images to PDF"
    case "pdf.repair":        return "PDF — Repair"
    case "pdf.ocr":           return "PDF — OCR"
    case "image_tools.convert": return "Image Tools"
    case "ocr.capture":       return "OCR Capture"
    case "recorder":          return "Screen Recorder"
    default:                  return id
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

/// The Outputs Library pane — searchable list of every file Trove produced.
/// No-arg init; consumes `OutputsLibrary.shared` directly.
public struct OutputsLibraryView: View {
    @ObservedObject private var store = OutputsLibrary.shared

    /// Pending delete confirmation. When non-nil, an alert is presented.
    @State private var pendingDelete: OutputEntry? = nil
    /// Pending "clear all" confirmation.
    @State private var confirmClearAll: Bool = false

    public init() {}

    public var body: some View {
        let visible = store.visible
        let groups = store.groupedVisible

        Group {
            if store.entries.isEmpty {
                emptyState
            } else if visible.isEmpty {
                noMatches
            } else {
                List {
                    ForEach(groups, id: \.producer) { group in
                        Section(outputsProducerLabel(group.producer)) {
                            ForEach(group.items) { entry in
                                // The very first visible row gets keyboard
                                // shortcuts. Entries are newest-first across
                                // the whole list, so this is the latest output.
                                // Duplicating shortcuts across every row would
                                // make SwiftUI log warnings.
                                OutputsRow(entry: entry,
                                           isPrimary: entry.id == visible.first?.id,
                                           onDelete: { pendingDelete = entry })
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle("\(visible.count) of \(store.entries.count) outputs")
        .searchable(text: $store.search,
                    prompt: "Search outputs (name, producer)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Bulk Save — pick a folder, copy every visible (filtered)
                // entry into it with collision-safe naming.
                if visible.count > 1 {
                    Button {
                        OutputsSaveHelpers.saveAll(entries: visible)
                    } label: {
                        Label("Save All…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .help("Pick a folder and copy every visible output into it")
                }

                Button {
                    store.forgetMissing()
                } label: {
                    Label("Forget missing", systemImage: "eye.slash")
                }
                .help("Drop entries whose files were moved or deleted")
                .disabled(store.entries.isEmpty)

                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .help("Remove every entry from the library (files are kept)")
                .disabled(store.entries.isEmpty)
            }
        }
        .alert("Delete this file?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let e = pendingDelete { store.delete(e.id) }
                pendingDelete = nil
            }
        } message: {
            if let e = pendingDelete {
                Text("\(e.url.lastPathComponent)\nThis removes the file from disk.")
            } else {
                Text("")
            }
        }
        .alert("Clear all library entries?",
               isPresented: $confirmClearAll) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clear() }
        } message: {
            Text("Removes every entry from the library. The actual files are kept on disk.")
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Empty states
    // ---------------------------------------------------------------------
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No outputs yet")
                .font(.title3.weight(.semibold))
            Text("Files you merge, convert, capture, or record will show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noMatches: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No outputs match \"\(store.search)\"")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // ---------------------------------------------------------------------
    // MARK: Grouping (stable producer order, newest within each section)
    // ---------------------------------------------------------------------
    static func group(_ entries: [OutputEntry]) -> [(producer: String, items: [OutputEntry])] {
        // Preserve first-seen producer order (entries are newest-first, so
        // sections appear in the order the user most-recently used them).
        var order: [String] = []
        var bucket: [String: [OutputEntry]] = [:]
        for e in entries {
            if bucket[e.producer] == nil { order.append(e.producer) }
            bucket[e.producer, default: []].append(e)
        }
        return order.map { p in (producer: p, items: bucket[p] ?? []) }
    }
}

// ===========================================================================
// MARK: - Row
// ===========================================================================

/// Apply ⌘<key> only to the primary (latest) row. Avoids the duplicate-
/// shortcut warning SwiftUI logs when every row would bind the same key.
private struct OutputsPrimaryShortcut: ViewModifier {
    let isPrimary: Bool
    let key: KeyEquivalent
    init(isPrimary: Bool, key: Character) {
        self.isPrimary = isPrimary
        self.key = KeyEquivalent(key)
    }
    func body(content: Content) -> some View {
        if isPrimary {
            content.keyboardShortcut(key, modifiers: [.command])
        } else {
            content
        }
    }
}

/// One row in the Outputs Library list.
private struct OutputsRow: View {
    let entry: OutputEntry
    var isPrimary: Bool = false
    let onDelete: () -> Void

    /// red-team: a row that's been evicted to iCloud should look different
    /// (and ops should refuse) — opening the .icloud placeholder pops a
    /// dataless-file dialog from the OS, which is confusing UX.
    private var iniCloud: Bool {
        OutputsTrustedRoots.isiCloudPlaceholder(entry.url)
    }

    /// red-team-sec: only open paths still under the trusted whitelist.
    /// Defense-in-depth in case the JSON was tampered with after the
    /// initial load-time filter ran.
    private func safeOpen() {
        guard OutputsTrustedRoots.isTrusted(entry.url) else {
            SharedStore.stage.flash("Refused to open \(entry.url.lastPathComponent) — outside trusted output dirs")
            return
        }
        if iniCloud {
            SharedStore.stage.flash("\(entry.url.lastPathComponent) is in iCloud — download it in Finder first")
            return
        }
        NSWorkspace.shared.open(entry.url)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iniCloud ? "icloud.and.arrow.down" : OutputsKindIcon.symbol(for: entry.kind))
                .font(.system(size: 18))
                .frame(width: 26, alignment: .center)
                .foregroundStyle(iniCloud ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("from \(entry.sourceLabel)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(outputsRelativeFormatter.localizedString(
                        for: entry.createdAt, relativeTo: Date()))
                    if iniCloud {
                        Text("·")
                        Text("in iCloud")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.bytes.human)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            // Primary Save… button — matches pdf.swift outputRow.
            Button {
                OutputsSaveHelpers.saveOne(entry: entry)
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(iniCloud)
            .modifier(OutputsPrimaryShortcut(isPrimary: isPrimary, key: "s"))
            .help(isPrimary ? "Save… (⌘S)" : "Choose where to save this file")

            Menu {
                Button {
                    safeOpen()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .disabled(iniCloud)

                Button {
                    OutputsSaveHelpers.saveOneToDownloads(entry: entry)
                } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .disabled(iniCloud)
                .modifier(OutputsPrimaryShortcut(isPrimary: isPrimary, key: "d"))

                Button {
                    // red-team: `activateFileViewerSelecting` on a path that
                    // no longer exists opens a Finder window pointed at the
                    // parent and silently does nothing visible — confusing.
                    // Check first and flash a clearer message.
                    if FileManager.default.fileExists(atPath: entry.urlPath) {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    } else {
                        SharedStore.stage.flash("\(entry.url.lastPathComponent) is missing — use Forget missing to clean up")
                    }
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .modifier(OutputsPrimaryShortcut(isPrimary: isPrimary, key: "r"))

                Button {
                    SharedStore.stage.addFile(entry.url)
                    SharedStore.stage.flash("Added \(entry.url.lastPathComponent) to Stage")
                } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
                .disabled(iniCloud)

                Divider()

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(entry.url.path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }

                Divider()

                reEditMenu

            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete file (asks for confirmation)")
        }
        .padding(.vertical, 4)
        // Drag the row out to Finder, Mail, Slack, etc. — matches pdf.swift's
        // outputRow. Skip when the file is iCloud-evicted (the placeholder
        // can't be dragged as a real file).
        .onDrag {
            if iniCloud { return NSItemProvider() }
            return NSItemProvider(contentsOf: entry.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { safeOpen() }
                .disabled(iniCloud)
            Button("Save…") {
                OutputsSaveHelpers.saveOne(entry: entry)
            }
            .disabled(iniCloud)
            Button("Save to Downloads") {
                OutputsSaveHelpers.saveOneToDownloads(entry: entry)
            }
            .disabled(iniCloud)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("Send to Stage") {
                SharedStore.stage.addFile(entry.url)
            }
            .disabled(iniCloud)
            Button("Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.url.path, forType: .string)
            }
        }
    }

    /// Kind-dependent re-edit submenu. For `pdf` we offer routing to specific
    /// PDF ops via the trove.openInPDFTool notification; for `image` we
    /// post trove.openInImageTools. For anything else only "Send to Stage"
    /// makes sense (already in the parent menu).
    @ViewBuilder
    private var reEditMenu: some View {
        switch entry.kind {
        case "pdf":
            Menu {
                pdfReopenButton("Open in Organize",   op: "organize",    icon: "square.grid.3x3")
                pdfReopenButton("Open in Split",      op: "split",       icon: "scissors")
                pdfReopenButton("Open in Compress",   op: "compress",    icon: "arrow.down.right.and.arrow.up.left")
                pdfReopenButton("Open in Rotate",     op: "rotate",      icon: "rotate.right")
                pdfReopenButton("Open in Page Numbers", op: "pageNumbers", icon: "number")
                pdfReopenButton("Open in Watermark",  op: "watermark",   icon: "drop.halffull")
                pdfReopenButton("Open in Crop",       op: "crop",        icon: "crop")
                pdfReopenButton("Open in Protect",    op: "protect",     icon: "lock")
                pdfReopenButton("Open in Unlock",     op: "unlock",      icon: "lock.open")
                pdfReopenButton("Open in OCR",        op: "ocr",         icon: "doc.text.viewfinder")
                pdfReopenButton("Open in Repair",     op: "repair",      icon: "bandage")
            } label: {
                Label("Re-edit…", systemImage: "pencil.and.outline")
            }
        case "image":
            Button {
                NotificationCenter.default.post(
                    name: .troveOpenInImageTools,
                    object: nil,
                    userInfo: ["url": entry.url]
                )
            } label: {
                Label("Open in Image Tools", systemImage: "photo.on.rectangle")
            }
        default:
            EmptyView()
        }
    }

    private func pdfReopenButton(_ title: String, op: String, icon: String) -> some View {
        Button {
            // red-team-sec: refuse to dispatch a re-edit for an untrusted path.
            guard OutputsTrustedRoots.isTrusted(entry.url) else {
                SharedStore.stage.flash("Refused re-edit on untrusted path")
                return
            }
            if iniCloud {
                SharedStore.stage.flash("\(entry.url.lastPathComponent) is in iCloud — download it first")
                return
            }
            // red-team #6 (notification payload): `URL` is a value type in
            // Swift (bridged NSURL is a reference type but URL itself is a
            // struct). The receiver on `.onReceive` is delivered on the main
            // queue because we don't pass `object:` and `addObserver(forName:
            // object: queue:)` is invoked with `.main` at the listener side.
            // Posters here run on the main actor already, so payload is safe.
            NotificationCenter.default.post(
                name: .troveOpenInPDFTool,
                object: nil,
                userInfo: ["url": entry.url, "op": op]
            )
        } label: {
            Label(title, systemImage: icon)
        }
        .disabled(iniCloud)
    }
}

// ===========================================================================
// MARK: - Save helpers (statics — no captured view state)
// ===========================================================================

private enum OutputsSaveHelpers {
    private static let kSaveDirKey = "outputs_library.saveDir.last"

    /// Save As… for a single library entry. Pre-fills filename and remembers
    /// the last-used directory. Matches pdf.swift's saveOutput pattern.
    static func saveOne(entry: OutputEntry) {
        // red-team-sec: re-check the trust guard before writing — defense in
        // depth against a tampered JSON sneaking past the load-time filter.
        guard OutputsTrustedRoots.isTrusted(entry.url) else {
            SharedStore.stage.flash("Refused to save \(entry.url.lastPathComponent) — outside trusted output dirs")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.url.lastPathComponent
        if let ut = UTType(filenameExtension: entry.url.pathExtension) {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: entry.url, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved \(dest.lastPathComponent) to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Couldn't save: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads with collision-safe naming.
    static func saveOneToDownloads(entry: OutputEntry) {
        guard OutputsTrustedRoots.isTrusted(entry.url) else {
            SharedStore.stage.flash("Refused to save \(entry.url.lastPathComponent) — outside trusted output dirs")
            return
        }
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let dest = collisionFreeURL(in: downloads, name: entry.url.lastPathComponent)
        do {
            try fm.copyItem(at: entry.url, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved \(dest.lastPathComponent) to Downloads")
        } catch {
            SharedStore.stage.flash("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// Bulk save — pick a folder, copy every entry there with collision-safe
    /// naming. Reveals the destination folder when done.
    static func saveAll(entries: [OutputEntry]) {
        // Snapshot trusted, in-place files only — silently skip placeholders.
        let usable = entries.filter { e in
            OutputsTrustedRoots.isTrusted(e.url)
                && FileManager.default.fileExists(atPath: e.urlPath)
                && !OutputsTrustedRoots.isiCloudPlaceholder(e.url)
        }
        guard !usable.isEmpty else {
            SharedStore.stage.flash("Nothing to save — entries are missing or in iCloud")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Save All Here"
        panel.message = "Choose a destination folder for \(usable.count) output\(usable.count == 1 ? "" : "s")."
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            setLastSaveDir(dir)
            let fm = FileManager.default
            var copied = 0
            for e in usable {
                let dest = collisionFreeURL(in: dir, name: e.url.lastPathComponent)
                if (try? fm.copyItem(at: e.url, to: dest)) != nil { copied += 1 }
            }
            if copied > 0 {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                SharedStore.stage.flash("Saved \(copied) of \(usable.count) to \(dir.lastPathComponent)")
            } else {
                SharedStore.stage.flash("Save All failed — couldn't copy any files")
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

    /// Append " (2)", " (3)"… before the extension until the destination
    /// doesn't exist. Caps at 99 — mirrors pdf.swift's collisionFreeURL.
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
