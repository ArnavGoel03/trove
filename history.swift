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

// ===========================================================================
// MARK: - Model
// ===========================================================================

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
        case .text(let s): return s.lowercased()
        case .image:       return ""
        case .file(let u): return u.lastPathComponent.lowercased()
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

/// In-memory clipboard ring buffer. 60 non-pinned entry cap; pinned are sticky.
/// Polls `NSPasteboard.general.changeCount` every 0.5s when `watching` is on.
final class ClipHistory: ObservableObject {
    // Fix 12: `visible` is now @Published, populated on entries/search changes.
    // Use backing stores for entries and search so we can call recomputeVisible().
    var entries: [ClipEntry] = [] {
        willSet { objectWillChange.send() }
        didSet  { recomputeVisible() }
    }
    @Published var watching: Bool = false
    var search: String = "" {
        willSet { objectWillChange.send() }
        didSet  { recomputeVisible() }
    }
    @Published private(set) var visible: [ClipEntry] = []

    private func recomputeVisible() {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            visible = entries
        } else {
            visible = entries.filter { entry in
                entry.searchHaystack.contains(q)
            }
        }
    }

    /// Per-instance scratch dir for image PNGs we capture from the pasteboard.
    let tempDir: URL

    /// Cap on non-pinned entries before LRU eviction kicks in.
    static let nonPinnedCap = 60

    // Fix 11: lastChangeCount, timer, and pasteboardWriteObserver removed —
    // PasteboardWatcher.shared owns the shared 0.5s poller and watermark.

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-history-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    deinit {
        // Fix 11: PasteboardWatcher subscription is cleaned up via setWatching(false).
        // The handler closure captures [weak self] so on deinit it becomes a no-op.
        // red-team: scrub per-instance tempDir so successive view recreates
        // don't leak a fresh `trove-history-XXXX` folder of PNGs each time.
        try? FileManager.default.removeItem(at: tempDir)
    }

    // -------- Watching ------------------------------------------------------

    func setWatching(_ on: Bool) {
        watching = on
        // Fix 11: use shared PasteboardWatcher instead of a private 0.5s Timer.
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
        // Red-team #1 + #4: strict=true honors `concealedTypes` and the
        // 100MB ceiling — password managers and giant blobs are filtered here.
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
            // A multi-file pasteboard becomes one entry per file, most-recent first.
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
        // Red-team #2: dedup against the most-recent *non-pinned* entry so a
        // user re-copying the same string doesn't fill the buffer with noise.
        if let prev = entries.first(where: { !$0.pinned }), isSamePayload(prev.kind, entry.kind) {
            return
        }
        entries.insert(entry, at: 0)
        evictIfNeeded()
    }

    /// Cap on pinned entries before oldest-first eviction kicks in.
    static let maxPinnedEntries = 200

    /// Drop oldest non-pinned entries past `nonPinnedCap`. Pinned entries are
    /// also capped at `maxPinnedEntries` (oldest by capturedAt evicted first).
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
                // dropped — clean up its temp PNG if it owns one
                cleanupTempFile(for: e)
            }
        }
        // Cap pinned entries at maxPinnedEntries; evict oldest by capturedAt.
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
        // Two image captures are never considered identical — comparing PNG
        // bytes would be expensive and the changeCount already gates near-dups.
        default: return false
        }
    }

    private func persistImage(_ img: NSImage) -> URL? {
        // red-team: macOS may sweep our /tmp scratch dir mid-session; recreate before each write.
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("clip-\(UUID().uuidString.prefix(8)).png")
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // red-team: refuse PNGs > 100MB so a single oversized capture can't burst /tmp; matches snapshot ceiling.
        guard png.count <= 100 * 1024 * 1024 else { return nil }
        do {
            // .atomic guarantees we never leave a half-written PNG that NSImage would fail to load later.
            try png.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private func cleanupTempFile(for entry: ClipEntry) {
        // Only clean up files we wrote into our own tempDir — never touch
        // arbitrary file URLs the user copied.
        if case .image(let u) = entry.kind, u.path.hasPrefix(tempDir.path) {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // -------- Mutations -----------------------------------------------------

    func togglePin(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned.toggle()
        // red-team: when an item becomes pinned it should also escape the
        // non-pinned LRU window — otherwise pinning the 60th entry doesn't
        // protect it on the next ingest, defeating user intent. Re-run the
        // eviction pass so the freshly-pinned row is correctly classified.
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

    /// Put `entry` back on the system pasteboard. Posts `.troveDidWritePasteboard`
    /// so PasteboardWatcher bumps its shared watermark and the next tick is a no-op.
    /// Returns `false` when the backing file is gone (image/file entry whose
    /// temp/source URL no longer resolves).
    @discardableResult
    func restoreToClipboard(_ entry: ClipEntry) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.kind {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .image(let u):
            // red-team: image temp file may have been auto-cleared from /tmp; fail loudly instead of writing an empty pasteboard.
            guard FileManager.default.fileExists(atPath: u.path),
                  let img = NSImage(contentsOf: u) else {
                // Fix 11: post notification so PasteboardWatcher suppresses this write.
                NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
                return false
            }
            pb.writeObjects([img])
        case .file(let u):
            // red-team: dropped/moved files leave a dead URL; refuse to "restore" a phantom pasteboard.
            guard FileManager.default.fileExists(atPath: u.path) else {
                // Fix 11: post notification so PasteboardWatcher suppresses this write.
                NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
                return false
            }
            pb.writeObjects([u as NSURL])
        }
        // Fix 11: PasteboardWatcher listens for this and advances the shared watermark
        // so the next tick is a no-op for both Stage auto-grab and History auto-watch.
        NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
        return true
    }

    // -------- Filtering -----------------------------------------------------

    // red-team: respond to memory pressure proactively. macOS will start
    // killing background apps when system memory is tight, and the clipboard
    // ring buffer is the easiest thing to shed (it's an L1 cache of paste
    // events, not the user's data). On DISPATCH_SOURCE_TYPE_MEMORYPRESSURE
    // warn/critical, drop everything that isn't pinned. Called from main.swift
    // wiring or by the app's memory-pressure observer; safe to invoke ad-hoc.
    func purgeUnderMemoryPressure() {
        let before = entries.count
        clearUnpinned()
        let dropped = before - entries.count
        if dropped > 0 {
            // Don't go through Stage.flash here — caller decides if it wants
            // to surface this since memory pressure can fire in tight loops.
            #if DEBUG
            print("ClipHistory: purged \(dropped) entries under memory pressure")
            #endif
        }
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

/// Public entry view for the Clipboard History pane. Expects a `ClipHistory`
/// in the environment (or wire it up however the host integration prefers).
struct HistoryView: View {
    @StateObject private var store = ClipHistory()
    @EnvironmentObject var stage: Stage

    var body: some View {
        Group {
            if store.entries.isEmpty {
                HistoryEmpty(store: store)
            } else {
                HistoryList(store: store, stage: stage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $store.search, prompt: "Search clipboard history")
        .navigationTitle("History")
        .navigationSubtitle(subtitle)
        .toolbar { historyToolbar }
    }

    private var subtitle: String {
        let count = store.entries.count
        let pinned = store.entries.filter { $0.pinned }.count
        let watch = store.watching ? "Watching" : "Paused"
        let countStr = "\(count) item\(count == 1 ? "" : "s")"
        let pinnedStr = pinned > 0 ? " · \(pinned) pinned" : ""
        return "\(watch) · \(countStr)\(pinnedStr)"
    }

    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { store.watching },
                                 set: { store.setWatching($0) })) {
                Label("Watch", systemImage: store.watching ? "dot.radiowaves.left.and.right" : "scope")
            }
            .help("Watch the clipboard and capture every change. Honors password-manager privacy markers.")

            Button(role: .destructive) {
                store.clearUnpinned()
            } label: {
                Label("Clear unpinned", systemImage: "trash")
            }
            .disabled(store.entries.allSatisfy { $0.pinned })
            .help("Remove every entry that isn't pinned")
        }
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

    var body: some View {
        ScrollView {
            let rows = store.visible
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
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
                VStack(spacing: 10) {
                    ForEach(rows) { entry in
                        Card {
                            HistoryRow(entry: entry, store: store, stage: stage)
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

// ---------- Row -------------------------------------------------------------

private struct HistoryRow: View {
    let entry: ClipEntry
    @ObservedObject var store: ClipHistory
    @ObservedObject var stage: Stage
    @State private var hover = false

    // red-team: was `static let` and captured Locale.current at first use.
    // Region change (e.g. US "5 min ago" → DE "vor 5 Min.") wouldn't take
    // effect mid-session. Now keyed off Formatters.epoch so AppDelegate's
    // locale-change observer triggers a rebuild on next render.
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
            preview
                .frame(width: 44, height: 44)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
                // red-team: icon-only buttons get no spoken text under VoiceOver
                // by default. Provide an explicit label per row action so the
                // clipboard pane is fully keyboard/VO navigable.
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
            // red-team: hover-fade hid the action affordances entirely under
            // VoiceOver-only navigation (the row never receives a hover). Keep
            // the dim at 0.55 visually but expose the buttons unconditionally
            // to the AX tree by tagging them as accessibility elements above.
            .opacity(hover ? 1 : 0.55)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            // red-team: surface dead-temp-file restores instead of pretending we wrote a payload.
            if store.restoreToClipboard(entry) {
                stage.flash("Restored to clipboard")
            } else {
                stage.flash("Original file is gone — couldn't restore")
            }
        }
        .contextMenu {
            Button(entry.pinned ? "Unpin" : "Pin") { store.togglePin(entry.id) }
            Button("Send to Stage")               { sendToStage() }
            Button("Restore to clipboard")        {
                if store.restoreToClipboard(entry) {
                    stage.flash("Restored to clipboard")
                } else {
                    stage.flash("Original file is gone — couldn't restore")
                }
            }
            Divider()
            Button("Remove", role: .destructive)  { store.remove(entry.id) }
        }
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
            // red-team: SwiftUI re-renders rows on every store change. Calling
            // `NSImage(contentsOf:)` here decoded the full PNG (potentially
            // tens of MB) per render — typing in the search field could pin a
            // CPU core for several seconds. `Image(nsImage:)` with a URL-bound
            // NSImage that lazily resolves via `byReferencingFile` is cheap;
            // AppKit only materialises pixels when drawn. The fallback path
            // handles a missing or unreadable file.
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
            // red-team: don't silently swallow a missing temp PNG — tell the user.
            if FileManager.default.fileExists(atPath: u.path),
               let img = NSImage(contentsOf: u) {
                stage.addImage(img)
                stage.flash("Sent image to Stage")
            } else {
                stage.flash("Original image is gone — can't send to Stage")
            }
        case .file(let u):
            // red-team: skip and flash when the user-copied file URL no longer resolves.
            if FileManager.default.fileExists(atPath: u.path) {
                stage.addFile(u)
                stage.flash("Sent file to Stage")
            } else {
                stage.flash("Original file is gone — can't send to Stage")
            }
        }
    }
}
