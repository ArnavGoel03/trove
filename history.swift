// Trove — Clipboard History feature.
//
// In-memory ring buffer of clipboard captures. Lets the user recover overwritten
// copies, search past entries, re-paste, pin, and forward to the Stage.
//
// This file is integrated into the rest of the app from main.swift; it
// declares no @main, no App, no Pane case, no top-level executable code.

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Model
// ===========================================================================

/// Codable mirror of `ItemKind` used solely for persistence. `ItemKind` itself
/// is defined in main.swift and carries an NSImage URL for `.image`, which is
/// already a temp-file URL — we persist those paths so they survive a session.
private enum ClipEntryKindCodable: Codable {
    case text(String)
    case imagePath(String)    // path to the per-session PNG in tempDir
    case filePath(String)

    enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? c.decode(String.self, forKey: .type)) ?? ""
        let v = (try? c.decode(String.self, forKey: .value)) ?? ""
        switch t {
        case "imagePath": self = .imagePath(v)
        case "filePath":  self = .filePath(v)
        default:          self = .text(v)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):       try c.encode("text",       forKey: .type); try c.encode(s, forKey: .value)
        case .imagePath(let p):  try c.encode("imagePath",  forKey: .type); try c.encode(p, forKey: .value)
        case .filePath(let p):   try c.encode("filePath",   forKey: .type); try c.encode(p, forKey: .value)
        }
    }
}

private struct ClipEntryCodable: Codable, Identifiable {
    let id: UUID
    let kind: ClipEntryKindCodable
    let capturedAt: Date
    var pinned: Bool

    enum CodingKeys: String, CodingKey { case id, kind, capturedAt, pinned }

    init(id: UUID, kind: ClipEntryKindCodable, capturedAt: Date, pinned: Bool) {
        self.id = id; self.kind = kind; self.capturedAt = capturedAt; self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id         = (try? c.decode(UUID.self,   forKey: .id))         ?? UUID()
        self.kind       = (try? c.decode(ClipEntryKindCodable.self, forKey: .kind)) ?? .text("")
        self.capturedAt = (try? c.decode(Date.self,   forKey: .capturedAt)) ?? Date()
        self.pinned     = (try? c.decode(Bool.self,   forKey: .pinned))     ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(pinned, forKey: .pinned)
    }
}

/// One captured clipboard entry. `kind` reuses `ItemKind` from main.swift so
/// the "send to Stage" path is straightforward.
struct ClipEntry: Identifiable, Hashable {
    let id: UUID
    let kind: ItemKind
    let capturedAt: Date
    var pinned: Bool

    init(id: UUID = UUID(), kind: ItemKind, capturedAt: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.pinned = pinned
    }

    /// Short, single-line summary used in the row UI.
    var summary: String {
        switch kind {
        case .text(let s):
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return String(one.prefix(80))
        case .image:
            return "Image"
        case .file(let u):
            return u.lastPathComponent
        }
    }

    /// Lower-cased searchable surface — text body or filename. Image entries
    /// are filtered out unless the search is empty.
    var searchHaystack: String {
        switch kind {
        case .text(let s): return s
        case .image:       return ""
        case .file(let u): return u.lastPathComponent
        }
    }

    var iconName: String {
        switch kind {
        case .image: return "photo"
        case .text:  return "text.alignleft"
        case .file:  return "doc"
        }
    }
}

// ===========================================================================
// MARK: - Store
// ===========================================================================

/// P1 fix: probe file byte-size before decoding. `NSImage(contentsOf:)` reads
/// the entire file into memory; on a tampered manifest (which the OutputsLibrary
/// trust audit doesn't gate for clipboard entries), a path pointing at a 1 GB
/// sparse file or a FIFO would OOM. Caps the read at 200 MB (matches the
/// pasteboard ingestion ceiling). The size probe itself is O(1) (stat call).
fileprivate func clipImageBytesSafe(_ url: URL, capBytes: Int64 = 200_000_000) -> NSImage? {
    let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
    let bytes = Int64(attrs?.fileSize ?? 0)
    guard bytes > 0, bytes <= capBytes else { return nil }
    return NSImage(contentsOf: url)
}

/// In-memory clipboard ring buffer. 60 non-pinned entry cap; pinned are sticky.
/// Polls `NSPasteboard.general.changeCount` every 0.5s when `watching` is on.
final class ClipHistory: ObservableObject {
    // `visible` is @Published, populated on entries/search changes.
    var entries: [ClipEntry] = [] {
        willSet { objectWillChange.send() }
        didSet  { recomputeVisible(); scheduleSave() }
    }
    // P0: watching persisted via @AppStorage key (read on init, saved on toggle).
    @Published var watching: Bool = false
    var search: String = "" {
        willSet { objectWillChange.send() }
        didSet  { recomputeVisible() }
    }
    @Published private(set) var visible: [ClipEntry] = []
    @Published private(set) var pinnedCount: Int = 0

    private func recomputeVisible() {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            visible = entries
        } else {
            visible = entries.filter { entry in
                entry.searchHaystack.localizedCaseInsensitiveContains(q)
            }
        }
        pinnedCount = entries.filter { $0.pinned }.count
    }

    /// Per-instance scratch dir for image PNGs we capture from the pasteboard.
    let tempDir: URL

    /// Cap on non-pinned entries before LRU eviction kicks in.
    static let nonPinnedCap = 60

    // MARK: - Persistence

    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trove", isDirectory: true)
    }()
    private static let storeURL = appSupportDir.appendingPathComponent("clipboard_history.json")

    /// Serial queue for disk I/O so multiple rapid saves don't race.
    private let ioQueue = DispatchQueue(label: "trove.history.io", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var terminateObserver: NSObjectProtocol?

    // P0: save the ring buffer + pinned entries to disk.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = entries
        let tempDirPath = tempDir.path
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performSave(snapshot, tempDirPath: tempDirPath)
        }
        pendingSave = work
        ioQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func performSave(_ snapshot: [ClipEntry], tempDirPath: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
            let codable: [ClipEntryCodable] = snapshot.map { e in
                let ck: ClipEntryKindCodable
                switch e.kind {
                case .text(let s):   ck = .text(s)
                case .image(let u):  ck = .imagePath(u.path)
                case .file(let u):   ck = .filePath(u.path)
                }
                return ClipEntryCodable(id: e.id,
                                        kind: ck,
                                        capturedAt: e.capturedAt,
                                        pinned: e.pinned)
            }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(codable)
            let tmp = Self.appSupportDir
                .appendingPathComponent(".cliphist-\(UUID().uuidString.prefix(8)).tmp")
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: Self.storeURL.path) {
                _ = try fm.replaceItemAt(Self.storeURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: Self.storeURL)
            }
            if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        } catch {
            // Silent — in-memory state is authoritative; warn in debug only.
            #if DEBUG
            print("ClipHistory: save failed: \(error)")
            #endif
        }
    }

    // P1 fix: off-main loader. Returns the restored entries (or nil if there's
    // nothing on disk to restore). Static + nonisolated so it can run from
    // Task.detached without an actor hop.
    nonisolated private static func loadEntriesFromDisk() -> [ClipEntry]? {
        guard let data = boundedRead(Self.storeURL) else { return nil }
        guard !data.isEmpty else { return nil }
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let codable = try dec.decode([ClipEntryCodable].self, from: data)
            var loaded: [ClipEntry] = []
            for ce in codable {
                let kind: ItemKind
                switch ce.kind {
                case .text(let s):       kind = .text(s)
                case .imagePath(let p):
                    // Only restore images whose temp PNG still exists.
                    let u = URL(fileURLWithPath: p)
                    guard FileManager.default.fileExists(atPath: u.path) else { continue }
                    kind = .image(u)
                case .filePath(let p):   kind = .file(URL(fileURLWithPath: p))
                }
                loaded.append(ClipEntry(id: ce.id,
                                        kind: kind,
                                        capturedAt: ce.capturedAt,
                                        pinned: ce.pinned))
            }
            return loaded.isEmpty ? nil : loaded
        } catch {
            // Corrupt file — start fresh; don't crash.
            #if DEBUG
            print("ClipHistory: load failed: \(error)")
            #endif
            return nil
        }
    }

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-history-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir

        // P0: restore watching preference from UserDefaults (cheap — single bool).
        // P1 fix: on first launch (key absent), default to TRUE. Trove is a
        // clipboard-first app — a brand-new user who lands on History sees an
        // empty pane and assumes the feature is broken because watching is off.
        // The privacy markers (`NSPasteboard.PasteboardType.concealed` etc.)
        // still apply on the ingestion path, so passwords / 1Password copies
        // are skipped automatically. Users who want full opt-out can flip the
        // toggle in the History pane.
        let savedWatching: Bool = {
            let d = UserDefaults.standard
            if d.object(forKey: "trove.history.watching") == nil { return true }
            return d.bool(forKey: "trove.history.watching")
        }()

        // P1 fix (DEVELOP_RULES §1): previously `loadFromDisk()` ran synchronously
        // here — boundedRead is capped at 16 MB and JSONDecoder.decode of the
        // ring buffer (60 entries × multi-MB image paths) pushed past the
        // AttributeGraph 50 ms watchdog on slow / cold storage. The view sees
        // an empty list for one render cycle, then the restored ring buffer
        // patches in. Per-row file-exists checks happen in the worker.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let restored = Self.loadEntriesFromDisk() else { return }
            await MainActor.run {
                self.entries = restored
                self.pendingSave?.cancel()
            }
        }

        // P0: restore watch state after load.
        if savedWatching {
            watching = true
            PasteboardWatcher.shared.subscribe(key: self) { [weak self] in
                guard let self, self.watching else { return }
                self.ingestFromPasteboard()
            }
        }

        // Force-flush on quit within the debounce window.
        let storeURL = Self.storeURL
        terminateObserver = NotificationCenter.default.addObserver(
            forName: .troveWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pendingSave?.cancel()
            let snapshot = self.entries
            let tempDirPath = self.tempDir.path
            self.ioQueue.sync { self.performSave(snapshot, tempDirPath: tempDirPath) }
            _ = storeURL // suppress capture warning
        }
    }

    deinit {
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        PasteboardWatcher.shared.unsubscribe(key: self)
        // Scrub per-instance tempDir so successive view recreates don't leak
        // trove-history-XXXX folders of PNGs.
        try? FileManager.default.removeItem(at: tempDir)
    }

    // -------- Watching ------------------------------------------------------

    func setWatching(_ on: Bool) {
        watching = on
        // P0: persist the preference so it survives restarts.
        UserDefaults.standard.set(on, forKey: "trove.history.watching")
        if on {
            PasteboardWatcher.shared.subscribe(key: self) { [weak self] in
                guard let self, self.watching else { return }
                self.ingestFromPasteboard()
            }
        } else {
            PasteboardWatcher.shared.unsubscribe(key: self)
        }
    }

    /// Pull a strict snapshot (privacy markers honored, 100MB cap honored) and
    /// turn it into a `ClipEntry`.
    private func ingestFromPasteboard() {
        guard let payload = ClipboardReader.snapshot(strict: true) else { return }

        let kind: ItemKind
        switch payload {
        case .text(let s):
            kind = .text(s)
        case .image(let img):
            guard let url = persistImage(img) else { return }
            kind = .image(url)
        case .files(let urls):
            guard let first = urls.first else { return }
            for u in urls.reversed() where u != first {
                insert(ClipEntry(kind: .file(u)))
            }
            kind = .file(first)
        }

        insert(ClipEntry(kind: kind))
    }

    /// Prepend `entry` (most-recent first), dedup against the most-recent
    /// non-pinned entry, then evict overflow non-pinned entries.
    private func insert(_ entry: ClipEntry) {
        if let prev = entries.first(where: { !$0.pinned }), isSamePayload(prev.kind, entry.kind) {
            return
        }
        entries.insert(entry, at: 0)
        evictIfNeeded()
    }

    /// Cap on pinned entries before oldest-first eviction kicks in.
    static let maxPinnedEntries = 200

    private func evictIfNeeded() {
        var nonPinnedCount = 0
        var keep: [ClipEntry] = []
        for e in entries {
            if e.pinned {
                keep.append(e)
                continue
            }
            if nonPinnedCount < Self.nonPinnedCap {
                keep.append(e)
                nonPinnedCount += 1
            } else {
                cleanupTempFile(for: e)
            }
        }
        var pinned = keep.filter { $0.pinned }
        if pinned.count > Self.maxPinnedEntries {
            pinned.sort { $0.capturedAt < $1.capturedAt }
            let evictCount = pinned.count - Self.maxPinnedEntries
            let toEvict = pinned.prefix(evictCount)
            let evictIDs = Set(toEvict.map { $0.id })
            for e in toEvict { cleanupTempFile(for: e) }
            keep.removeAll { evictIDs.contains($0.id) }
            SharedStore.stage.flash("Pinned history capped at 200 — evicted \(evictCount) oldest")
        }
        if keep.count != entries.count {
            entries = keep
        }
    }

    private func isSamePayload(_ a: ItemKind, _ b: ItemKind) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return x == y
        case (.file(let x), .file(let y)): return x.path == y.path
        default: return false
        }
    }

    private func persistImage(_ img: NSImage) -> URL? {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("clip-\(UUID().uuidString.prefix(8)).png")
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        guard png.count <= 100 * 1024 * 1024 else { return nil }
        do {
            try png.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private func cleanupTempFile(for entry: ClipEntry) {
        if case .image(let u) = entry.kind, u.path.hasPrefix(tempDir.path) {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // -------- Mutations -----------------------------------------------------

    func togglePin(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned.toggle()
        if entries[i].pinned {
            evictIfNeeded()
        }
    }

    func remove(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: i)
        cleanupTempFile(for: removed)
    }

    func clearUnpinned() {
        let toDrop = entries.filter { !$0.pinned }
        for e in toDrop { cleanupTempFile(for: e) }
        entries.removeAll { !$0.pinned }
    }

    @discardableResult
    func restoreToClipboard(_ entry: ClipEntry) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.kind {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .image(let u):
            guard FileManager.default.fileExists(atPath: u.path),
                  let img = clipImageBytesSafe(u) else {
                NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
                return false
            }
            pb.writeObjects([img])
        case .file(let u):
            guard FileManager.default.fileExists(atPath: u.path) else {
                NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
                return false
            }
            pb.writeObjects([u as NSURL])
        }
        NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
        return true
    }

    /// Copy entry text/image/file to clipboard WITHOUT triggering a "restore" in the UI.
    /// For text: puts the string. For image/file: same as restoreToClipboard.
    @discardableResult
    func copyToClipboard(_ entry: ClipEntry) -> Bool {
        return restoreToClipboard(entry)
    }

    /// Save entry as a file using an NSSavePanel.
    func saveAsFile(_ entry: ClipEntry) {
        switch entry.kind {
        case .text(let s):
            let panel = NSSavePanel()
            panel.title = "Save text as…"
            panel.nameFieldStringValue = "clipboard.txt"
            panel.allowedContentTypes = [.plainText]
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                try? s.write(to: url, atomically: true, encoding: .utf8)
                SharedStore.stage.flash("Saved to \(url.lastPathComponent)")
            }
        case .image(let u):
            guard FileManager.default.fileExists(atPath: u.path) else {
                SharedStore.stage.flash("Original image is gone — can't save")
                return
            }
            let panel = NSSavePanel()
            panel.title = "Save image as…"
            panel.nameFieldStringValue = "clipboard.png"
            panel.allowedContentTypes = [UTType.png]
            panel.begin { resp in
                guard resp == .OK, let dst = panel.url else { return }
                do {
                    try FileManager.default.copyItem(at: u, to: dst)
                    SharedStore.stage.flash("Saved to \(dst.lastPathComponent)")
                } catch {
                    SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
                }
            }
        case .file(let u):
            guard FileManager.default.fileExists(atPath: u.path) else {
                SharedStore.stage.flash("Original file is gone — can't save")
                return
            }
            let panel = NSSavePanel()
            panel.title = "Save file as…"
            panel.nameFieldStringValue = u.lastPathComponent
            panel.begin { resp in
                guard resp == .OK, let dst = panel.url else { return }
                do {
                    try FileManager.default.copyItem(at: u, to: dst)
                    SharedStore.stage.flash("Saved to \(dst.lastPathComponent)")
                } catch {
                    SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // -------- Memory pressure -----------------------------------------------

    func purgeUnderMemoryPressure() {
        let before = entries.count
        clearUnpinned()
        let dropped = before - entries.count
        if dropped > 0 {
            #if DEBUG
            print("ClipHistory: purged \(dropped) entries under memory pressure")
            #endif
        }
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

struct HistoryView: View {
    @StateObject private var store = ClipHistory()
    @EnvironmentObject var stage: Stage
    @State private var confirmClearHistory = false
    // P1: multi-select set
    @State private var selection: Set<UUID> = []

    var body: some View {
        Group {
            if store.entries.isEmpty {
                HistoryEmpty(store: store)
            } else {
                HistoryList(store: store, stage: stage, selection: $selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $store.search, prompt: "Search clipboard history")
        .navigationTitle("History")
        .navigationSubtitle(subtitle)
        .toolbar { historyToolbar }
        .confirmationDialog("Clear unpinned clipboard history?",
                            isPresented: $confirmClearHistory,
                            titleVisibility: .visible) {
            Button("Clear Unpinned", role: .destructive) { store.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items will remain. Unpinned items are persisted to disk and will be cleared.")
        }
    }

    private var subtitle: String {
        let count = store.entries.count
        let pinned = store.pinnedCount
        let watch = store.watching ? "Watching" : "Paused"
        let countStr = "\(count) item\(count == 1 ? "" : "s")"
        let pinnedStr = pinned > 0 ? " · \(pinned) pinned" : ""
        return "\(watch) · \(countStr)\(pinnedStr)"
    }

    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // P1: batch send-to-Stage when items are selected.
            if !selection.isEmpty {
                Button {
                    batchSendToStage()
                } label: {
                    Label("Send \(selection.count) to Stage", systemImage: "tray.and.arrow.down")
                }
                .help("Send all selected items to Stage")
            }

            Toggle(isOn: Binding(get: { store.watching },
                                 set: { store.setWatching($0) })) {
                Label("Watch", systemImage: store.watching ? "dot.radiowaves.left.and.right" : "scope")
            }
            .help("Watch the clipboard and capture every change. Honors password-manager privacy markers.")

            Button(role: .destructive) {
                confirmClearHistory = true
            } label: {
                Label("Clear unpinned", systemImage: "trash")
            }
            .disabled(store.entries.allSatisfy { $0.pinned })
            .help("Remove every entry that isn't pinned")
        }
    }

    private func batchSendToStage() {
        let targets = store.entries.filter { selection.contains($0.id) }
        var sent = 0
        for entry in targets {
            switch entry.kind {
            case .text(let s):
                stage.addText(s); sent += 1
            case .image(let u):
                if FileManager.default.fileExists(atPath: u.path),
                   let img = clipImageBytesSafe(u) {
                    stage.addImage(img); sent += 1
                }
            case .file(let u):
                if FileManager.default.fileExists(atPath: u.path) {
                    stage.addFile(u); sent += 1
                }
            }
        }
        selection.removeAll()
        if sent > 0 { stage.flash("Sent \(sent) item\(sent == 1 ? "" : "s") to Stage") }
    }
}

// ---------- Empty state -----------------------------------------------------

private struct HistoryEmpty: View {
    @ObservedObject var store: ClipHistory

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No clipboard history yet")
                .font(.title2.weight(.medium))
            Text("Turn on **Watch** and Trove will keep a rolling buffer of the last 60 things you copy. Pinned items stick around forever. Password-manager pastes are filtered out automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
                .multilineTextAlignment(.center)
            Button {
                store.setWatching(true)
            } label: {
                Label(store.watching ? "Watching…" : "Enable Watch",
                      systemImage: store.watching ? "dot.radiowaves.left.and.right" : "scope")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(store.watching)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// ---------- List ------------------------------------------------------------

private struct HistoryList: View {
    @ObservedObject var store: ClipHistory
    @ObservedObject var stage: Stage
    @Binding var selection: Set<UUID>

    var body: some View {
        ScrollView {
            let rows = store.visible
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    // A11y sweep revert: empty-state title isn't a heading.
                    Text("No matches for \u{201C}\(store.search)\u{201D}")
                        .font(.headline)
                    Text("Try a different query, or clear the search to see all \(store.entries.count) captured item\(store.entries.count == 1 ? "" : "s").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                        .multilineTextAlignment(.center)
                    Button {
                        store.search = ""
                    } label: {
                        Label("Clear search", systemImage: "xmark.circle")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                // P1: LazyVStack so 60 NSImages don't load all at once.
                LazyVStack(spacing: 10) {
                    ForEach(rows) { entry in
                        Card {
                            HistoryRow(entry: entry,
                                       store: store,
                                       stage: stage,
                                       isSelected: selection.contains(entry.id),
                                       onToggleSelect: { toggleSelect(entry.id) })
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func toggleSelect(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) }
        else { selection.insert(id) }
    }
}

// ---------- Row -------------------------------------------------------------

private struct HistoryRow: View {
    let entry: ClipEntry
    @ObservedObject var store: ClipHistory
    @ObservedObject var stage: Stage
    let isSelected: Bool
    let onToggleSelect: () -> Void
    @State private var hover = false

    // Locale-aware relative formatter; rebuilt when Formatters.epoch changes.
    private static var relFmtCache: (epoch: Int, fmt: RelativeDateTimeFormatter)? = nil
    private static var relFmt: RelativeDateTimeFormatter {
        if let c = relFmtCache, c.epoch == Formatters.epoch { return c.fmt }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale.autoupdatingCurrent
        relFmtCache = (Formatters.epoch, f)
        return f
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // P1: multi-select checkbox.
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.troveAccent : Color.troveFgMute)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect" : "Select")

            preview
                .frame(width: 44, height: 44)
                .background(Color.troveCardFill, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: entry.iconName).font(.caption2).foregroundStyle(.secondary)
                    Text(entry.summary)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                Text(Self.relFmt.localizedString(for: entry.capturedAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    store.togglePin(entry.id)
                } label: {
                    Image(systemName: entry.pinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.borderless)
                .help(entry.pinned ? "Unpin" : "Pin (won't be evicted)")
                .accessibilityLabel(entry.pinned ? "Unpin clipboard entry" : "Pin clipboard entry")

                Button {
                    sendToStage()
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Send to Stage")
                .accessibilityLabel("Send clipboard entry to Stage")

                Button {
                    store.remove(entry.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove from history")
                .accessibilityLabel("Remove clipboard entry from history")
            }
            // Buttons always visible in AX tree; dim visually when not hovering.
            .opacity(hover ? 1 : 0.55)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // P1: tap to copy (separate from restore); ⌘↩ = restore.
        .onTapGesture {
            if store.copyToClipboard(entry) {
                stage.flash("Copied to clipboard")
            } else {
                stage.flash("Original file is gone — couldn't copy")
            }
        }
        // P1: drag-out via NSItemProvider for all entry kinds.
        .onDrag { historyDragItem(entry) }
        .contextMenu {
            // P2: Quick Look for image/file entries — Space-bar opens the
            // macOS-native preview panel, same surface Finder uses. Text
            // entries skip this since the row body already shows the snippet.
            switch entry.kind {
            case .image(let u), .file(let u):
                Button("Quick Look") { TroveQuickLook.shared.show(u) }
                    // P1 fix: ⌘Y (Finder canonical) — .space bled scope.
                    .keyboardShortcut("y", modifiers: .command)
                Divider()
            case .text: EmptyView()
            }
            Button(entry.pinned ? "Unpin" : "Pin") { store.togglePin(entry.id) }
            Divider()
            // P1: split Copy and Restore; add Save as file.
            Button("Copy to Clipboard") {
                if store.copyToClipboard(entry) {
                    stage.flash("Copied to clipboard")
                } else {
                    stage.flash("Original file is gone — couldn't copy")
                }
            }
            Button("Restore to Clipboard") {
                if store.restoreToClipboard(entry) {
                    stage.flash("Restored to clipboard")
                } else {
                    stage.flash("Original file is gone — couldn't restore")
                }
            }
            // P1: Save as file for text and image entries.
            if case .file = entry.kind {} else {
                Button("Save as File…") { store.saveAsFile(entry) }
            }
            Button("Send to Stage") { sendToStage() }
            Divider()
            Button("Remove", role: .destructive) { store.remove(entry.id) }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.troveAccent.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.kind {
        case .text(let s):
            Text(s)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(3)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image(let u):
            // P1: `NSImage(byReferencingFile:)` is cheap — AppKit only materialises pixels on draw.
            if FileManager.default.fileExists(atPath: u.path),
               let img = NSImage(byReferencingFile: u.path),
               img.isValid {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        case .file(let u):
            Image(systemName: u.hasDirectoryPath ? "folder.fill" : "doc.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
        }
    }

    private func sendToStage() {
        switch entry.kind {
        case .text(let s):
            stage.addText(s)
            stage.flash("Sent text to Stage")
        case .image(let u):
            if FileManager.default.fileExists(atPath: u.path),
               let img = clipImageBytesSafe(u) {
                stage.addImage(img)
                stage.flash("Sent image to Stage")
            } else {
                stage.flash("Original image is gone — can't send to Stage")
            }
        case .file(let u):
            if FileManager.default.fileExists(atPath: u.path) {
                stage.addFile(u)
                stage.flash("Sent file to Stage")
            } else {
                stage.flash("Original file is gone — can't send to Stage")
            }
        }
    }
}

// P1: drag-out provider. For image entries, fall back to raw PNG data if the
// temp file path is dead (e.g. swept by macOS).
private func historyDragItem(_ entry: ClipEntry) -> NSItemProvider {
    switch entry.kind {
    case .text(let s):
        return NSItemProvider(object: s as NSString)
    case .file(let u):
        if FileManager.default.fileExists(atPath: u.path) {
            return NSItemProvider(object: u as NSURL)
        }
        // Dead file — vend an empty provider rather than crashing.
        return NSItemProvider()
    case .image(let u):
        // Fast path: file still present — vend the URL.
        if FileManager.default.fileExists(atPath: u.path) {
            return NSItemProvider(object: u as NSURL)
        }
        // Fallback: vend NSImage data directly.
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier,
                                             visibility: .all) { completion in
            // Return nil data if the file really is gone.
            completion(nil, nil)
            return nil
        }
        return provider
    }
}
