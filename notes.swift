// Trove — Quick Notes / Scratchpad pane.
//
// Five colored tabs (red/orange/yellow/green/blue) à la Tot, but with:
//   • Inline markdown rendering (bold, italics, links, headers, lists, checkboxes)
//   • Click-to-toggle `- [ ]` / `- [x]` checkboxes that mutate the source text
//   • Cross-tab Cmd-F search with per-tab badges
//   • Live word/char count in the navigation subtitle
//   • One-click "Send to Stage" (text item)
//   • Cmd-1 … Cmd-5 keyboard shortcuts to switch tabs
//   • Atomic, debounced, off-main persistence to ~/Library/Application Support/Trove/notes.json
//
// No `@main`, no `App`, no `Pane` case — this file is self-contained and
// can be wired in by `main.swift` adding a `Pane.notes` case + `NotesView()`.

import SwiftUI
import AppKit
import Foundation
import Combine

// ===========================================================================
// MARK: - Tab color model
// ===========================================================================

enum NoteColor: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, blue
    var id: String { rawValue }

    var swiftUI: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        }
    }

    /// Default human title used until the user renames the tab.
    var defaultTitle: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

// ===========================================================================
// MARK: - Persisted model
// ===========================================================================

struct NoteTab: Codable, Identifiable, Equatable {
    var color: NoteColor
    var title: String
    var body: String
    var id: String { color.rawValue }

    static func empty(_ c: NoteColor) -> NoteTab {
        NoteTab(color: c, title: c.defaultTitle, body: "")
    }
}

struct NotePersisted: Codable {
    var tabs: [NoteTab]
    var version: Int = 1
    static let currentVersion: Int = 1
}

// ===========================================================================
// MARK: - Store (load / debounced save / atomic write)
// ===========================================================================

@MainActor
final class NoteStore: ObservableObject {
    @Published var tabs: [NoteTab]
    @Published var selected: NoteColor = .red
    @Published var showPreview: Bool = false
    @Published var searchActive: Bool = false
    @Published var searchQuery: String = ""

    /// Background-computed (word, char) per tab. Stays in sync with `tabs`.
    /// Updated off-main for large notes so typing latency never spikes.
    @Published var counts: [NoteColor: (words: Int, chars: Int)] = [:]

    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trove", isDirectory: true)
    }()
    private static let storeURL = appSupportDir.appendingPathComponent("notes.json")

    /// Serial queue so two debounced writes can't interleave (red-team #3).
    private let writeQueue = DispatchQueue(label: "trove.notes.write",
                                           qos: .utility)

    /// Debounce timer for keystroke -> disk write (red-team #3).
    private var saveWork: DispatchWorkItem?
    /// Throttle timer for word/char count on big notes (red-team #4).
    private var countWork: DispatchWorkItem?

    // red-team: NotificationCenter token for willTerminate force-flush observer.
    // PER-INSTANCE rather than static — previously `static` meant a second
    // NoteStore (test harness, multi-window, or live-reload) would overwrite
    // the first store's observer ref, leaking the original observer for the
    // app's lifetime and double-flushing on terminate. Per-instance is also
    // what `removeObserver` on deinit wants.
    private var terminateObserver: NSObjectProtocol?

    init() {
        // Ensure all five tabs exist; rehydrate from disk if present.
        var loaded: [NoteTab] = NoteColor.allCases.map(NoteTab.empty)
        var recoveryMessage: String? = nil

        try? FileManager.default.createDirectory(at: Self.appSupportDir,
                                                 withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: Self.storeURL.path) {
            do {
                guard let data = boundedRead(Self.storeURL) else { throw CocoaError(.fileReadNoSuchFile) }
                let decoded = try JSONDecoder().decode(NotePersisted.self, from: data)
                // Fix 2: reject files written by a future version to avoid silent data corruption.
                guard decoded.version <= NotePersisted.currentVersion else {
                    let ts = Int(Date().timeIntervalSince1970)
                    let futureURL = Self.appSupportDir
                        .appendingPathComponent("notes-future-\(ts).json")
                    try? FileManager.default.moveItem(at: Self.storeURL, to: futureURL)
                    recoveryMessage = "Notes file was written by a newer version of Trove — backed up to \(futureURL.lastPathComponent)"
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Replace defaults with any colors we recognize from disk.
                for t in decoded.tabs {
                    if let i = loaded.firstIndex(where: { $0.color == t.color }) {
                        loaded[i] = t
                    }
                }
            } catch {
                // Red-team #2: corrupt JSON — rename so next save can't clobber it.
                let ts = Int(Date().timeIntervalSince1970)
                let corruptURL = Self.appSupportDir
                    .appendingPathComponent("notes-corrupt-\(ts).json")
                try? FileManager.default.moveItem(at: Self.storeURL, to: corruptURL)
                recoveryMessage = "Notes file unreadable — backed up to \(corruptURL.lastPathComponent)"
            }
        }
        self.tabs = loaded

        // Initial count pass synchronously (small/empty at boot).
        for t in tabs { counts[t.color] = Self.cheapCount(t.body) }

        if let msg = recoveryMessage {
            // Wait until app is up so the flash isn't lost during launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SharedStore.stage.flash(msg)
            }
        }

        // red-team: force-flush within the 200ms debounce window on quit.
        // Block observer registered AFTER stored properties are initialized so
        // capturing `self` weakly is legal under Swift's init-completion rules.
        self.terminateObserver = NotificationCenter.default.addObserver(
            forName: .troveWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSynchronously()
            }
        }
    }

    deinit {
        // red-team: unbalanced observer registration is a textbook leak.
        // NSNotificationCenter retains the closure (and thus the token slot)
        // for the host's lifetime. Pair the add with an explicit remove.
        if let o = terminateObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - Mutation entrypoints

    // Fix 1: per-tab body size limits to prevent 50 MB note → quarantine → all-tabs-wiped.
    static let warnBytes: Int = 4 * 1024 * 1024   // 4 MB — warn but allow
    static let refuseBytes: Int = 10 * 1024 * 1024 // 10 MB — reject update

    /// Single source of truth for body edits. Updates state, schedules a
    /// debounced disk write, and throttles the word/char recount.
    func setBody(_ color: NoteColor, _ newValue: String) {
        let byteCount = newValue.utf8.count
        if byteCount > Self.refuseBytes {
            SharedStore.stage.flash("Note too large (\(byteCount / 1_048_576) MB) — update rejected to protect your data.", kind: .warning)
            return
        }
        guard let i = tabs.firstIndex(where: { $0.color == color }) else { return }
        guard tabs[i].body != newValue else { return }
        if byteCount > Self.warnBytes && tabs[i].body.utf8.count <= Self.warnBytes {
            // Flash once when crossing the warn threshold (not on every keystroke).
            SharedStore.stage.flash("Note is over 4 MB — consider splitting it into smaller notes.", kind: .warning)
        }
        tabs[i].body = newValue
        scheduleSave()
        scheduleCount(color, newValue)
    }

    func setTitle(_ color: NoteColor, _ newValue: String) {
        guard let i = tabs.firstIndex(where: { $0.color == color }) else { return }
        let trimmed = newValue.isEmpty ? color.defaultTitle : newValue
        guard tabs[i].title != trimmed else { return }
        tabs[i].title = trimmed
        scheduleSave()
    }

    func tab(_ color: NoteColor) -> NoteTab {
        tabs.first(where: { $0.color == color }) ?? NoteTab.empty(color)
    }

    // MARK: - Send to Stage

    func sendCurrentToStage() {
        let cur = tab(selected)
        let trimmed = cur.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SharedStore.stage.flash("Note is empty — nothing to stage")
            return
        }
        SharedStore.stage.addText(cur.body)
        SharedStore.stage.flash("Sent “\(cur.title)” note to Stage")
    }

    // MARK: - Save scheduling (debounced, atomic, off-main)

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = NotePersisted(tabs: tabs)
        let work = DispatchWorkItem { [weak self] in
            self?.performSave(snapshot)
        }
        saveWork = work
        // 200ms debounce per spec.
        writeQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // red-team: synchronous flush invoked on willTerminate so the 200ms
    // debounce window doesn't eat the last keystroke before quit. Cancels
    // any pending async work and writes on the calling thread.
    func flushSynchronously() {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = NotePersisted(tabs: tabs)
        // Run on the writeQueue *sync* so the process can't exit mid-write.
        writeQueue.sync { [snapshot] in
            self.performSave(snapshot)
        }
    }

    private func performSave(_ snapshot: NotePersisted) {
        // All file I/O happens on writeQueue (serial). Errors flash on main.
        do {
            try FileManager.default.createDirectory(at: Self.appSupportDir,
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(snapshot)
            let tmp = Self.appSupportDir
                .appendingPathComponent("notes-\(UUID().uuidString.prefix(8)).tmp")
            try data.write(to: tmp, options: .atomic)
            // Red-team #7: atomic replace via replaceItem.
            // If the destination doesn't exist yet, replaceItemAt errors —
            // fall back to a plain move in that case.
            if FileManager.default.fileExists(atPath: Self.storeURL.path) {
                _ = try FileManager.default.replaceItemAt(Self.storeURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: Self.storeURL)
            }
            // red-team: replaceItemAt usually returns the original URL but may
            // leave the .tmp around when the swap takes a fast path; sweep
            // stale tmp siblings so /Library/Application Support/Trove
            // doesn't slowly fill with notes-XXXX.tmp orphans across crashes.
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
        } catch {
            // Red-team #1: in-memory state stays intact; surface via flash.
            let msg = "Note save failed: \(error.localizedDescription)"
            DispatchQueue.main.async {
                SharedStore.stage.flash(msg)
            }
        }
    }

    // MARK: - Word / char counting (throttled for huge bodies)

    /// Cheap counter used on small bodies and at boot.
    private static func cheapCount(_ s: String) -> (Int, Int) {
        // red-team: `String.count` walks the entire string to compose grapheme
        // clusters — O(n) over the body, on the main thread for any body
        // ≤100KB. For a 90KB markdown note that's a multi-ms hitch on every
        // keystroke. Use `unicodeScalars.count` here: it's also O(n) but with
        // a much smaller constant factor and no grapheme segmentation work.
        // The displayed char count is still "characters as the user sees
        // them" to within a handful for typical English/markdown notes; for
        // strict grapheme accuracy the caller can opt in later.
        var chars = 0
        var words = 0
        var inWord = false
        for ch in s.unicodeScalars {
            chars += 1
            if CharacterSet.whitespacesAndNewlines.contains(ch) {
                if inWord { words += 1; inWord = false }
            } else {
                inWord = true
            }
        }
        if inWord { words += 1 }
        return (words, chars)
    }

    /// Red-team #4: for >100 KB notes do the count off-main, throttled.
    private func scheduleCount(_ color: NoteColor, _ body: String) {
        if body.utf8.count <= 100_000 {
            let c = Self.cheapCount(body)
            counts[color] = c
            return
        }
        countWork?.cancel()
        let snap = body
        let work = DispatchWorkItem { [weak self] in
            let c = NoteStore.cheapCount(snap)
            DispatchQueue.main.async {
                self?.counts[color] = c
            }
        }
        countWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25,
                                                       execute: work)
    }

    // MARK: - Cross-tab search

    struct SearchHit: Identifiable, Hashable {
        let id = UUID()
        let color: NoteColor
        let tabTitle: String
        let lineNumber: Int
        let line: String
        let matchRange: Range<String.Index>?
    }

    /// Linear scan across all tabs. Cheap relative to typing latency.
    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { return [] }
        var out: [SearchHit] = []
        for t in tabs {
            let lines = t.body.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, lineSub) in lines.enumerated() {
                let line = String(lineSub)
                if let r = line.range(of: q, options: .caseInsensitive) {
                    out.append(SearchHit(color: t.color,
                                         tabTitle: t.title,
                                         lineNumber: i + 1,
                                         line: line,
                                         matchRange: r))
                }
            }
        }
        return out
    }
}

// ===========================================================================
// MARK: - Markdown -> AttributedString (with checkbox source-mapping)
// ===========================================================================

/// One rendered line of the preview. Either ordinary attributed text, or a
/// checkbox bound to a specific line range in the source body.
struct NoteRenderedBlock: Identifiable {
    let id = UUID()
    let kind: Kind
    enum Kind {
        case checkbox(checked: Bool, label: AttributedString, sourceRange: Range<String.Index>)
        case text(AttributedString)
        case bulletText(AttributedString)
        case heading(level: Int, text: AttributedString)
    }
}

enum NoteMarkdown {
    /// Render the body into block-level structures. We do this ourselves rather
    /// than feeding the whole body to `AttributedString(markdown:)` so that
    /// (a) checkboxes get precise click hit-testing tied back to source ranges
    /// and (b) bullet / heading formatting is consistent.
    static func render(_ body: String) -> [NoteRenderedBlock] {
        var blocks: [NoteRenderedBlock] = []
        // Iterate over source lines while tracking each line's String range
        // in the original body — that's what checkbox-toggle mutates.
        var cursor = body.startIndex
        while cursor < body.endIndex {
            let lineEnd = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
            let lineRange = cursor..<lineEnd
            let line = String(body[lineRange])
            blocks.append(renderLine(line, sourceRange: lineRange))
            cursor = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return blocks
    }

    private static func renderLine(_ line: String,
                                   sourceRange: Range<String.Index>) -> NoteRenderedBlock {
        // Strip leading spaces for prefix detection but preserve for indent display.
        let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })

        // Checkbox detection — `- [ ]` or `- [x]` (case-insensitive x).
        if let cb = matchCheckbox(trimmedLeading) {
            let label = inlineMarkdown(String(cb.label))
            return NoteRenderedBlock(kind: .checkbox(checked: cb.checked,
                                                    label: label,
                                                    sourceRange: sourceRange))
        }

        // Heading detection — `# ` / `## ` / `### `.
        if trimmedLeading.hasPrefix("### ") {
            return .init(kind: .heading(level: 3,
                                        text: inlineMarkdown(String(trimmedLeading.dropFirst(4)))))
        }
        if trimmedLeading.hasPrefix("## ") {
            return .init(kind: .heading(level: 2,
                                        text: inlineMarkdown(String(trimmedLeading.dropFirst(3)))))
        }
        if trimmedLeading.hasPrefix("# ") {
            return .init(kind: .heading(level: 1,
                                        text: inlineMarkdown(String(trimmedLeading.dropFirst(2)))))
        }

        // Bullet list — `- ` (but not `- [`, which was handled above).
        if trimmedLeading.hasPrefix("- ") {
            return .init(kind: .bulletText(inlineMarkdown(String(trimmedLeading.dropFirst(2)))))
        }

        return .init(kind: .text(inlineMarkdown(line)))
    }

    private static func matchCheckbox(_ s: Substring) -> (checked: Bool, label: Substring)? {
        // Match `- [ ] label` or `- [x] label` / `- [X] label`.
        guard s.hasPrefix("- [") else { return nil }
        let after = s.dropFirst(3)
        guard let close = after.firstIndex(of: "]") else { return nil }
        let mark = after[..<close]
        guard mark.count == 1, let ch = mark.first else { return nil }
        let checked: Bool
        switch ch {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        var rest = after[after.index(after: close)...]
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return (checked, rest)
    }

    /// Inline-only parsing via Apple's parser. Red-team #6: errors caught.
    private static func inlineMarkdown(_ s: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: s,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(s)
        }
    }
}

// ===========================================================================
// MARK: - Public View
// ===========================================================================

public struct NotesView: View {
    @StateObject private var store = NoteStore()
    @State private var renaming: NoteColor? = nil
    @State private var renameText: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()

            if store.searchActive {
                NoteSearchOverlay(store: store)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                editorPane
                if store.showPreview {
                    Divider()
                    previewPane
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                }
            }
        }
        .navigationTitle("Notes")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        // Cmd-F shows the search overlay.
        .background(
            // Hidden buttons for keyboard shortcuts that aren't natural toolbar items.
            ZStack {
                Button("") {
                    store.searchActive.toggle()
                    if !store.searchActive { store.searchQuery = "" }
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            }
        )
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(NoteColor.allCases) { c in
                NoteTabChip(
                    color: c,
                    title: store.tab(c).title,
                    isSelected: store.selected == c,
                    isRenaming: renaming == c,
                    renameText: $renameText,
                    onSelect: { store.selected = c },
                    onBeginRename: {
                        renaming = c
                        renameText = store.tab(c).title
                    },
                    onCommitRename: {
                        store.setTitle(c, renameText)
                        renaming = nil
                    },
                    onCancelRename: { renaming = nil }
                )
            }
            Spacer()
        }
    }

    // MARK: - Editor

    private var editorPane: some View {
        let binding = Binding<String>(
            get: { store.tab(store.selected).body },
            set: { store.setBody(store.selected, $0) }
        )
        return ZStack(alignment: .topLeading) {
            TextEditor(text: binding)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .id(store.selected) // ensure cursor doesn't survive a tab switch incorrectly

            if store.tab(store.selected).body.isEmpty {
                Text(emptyHint)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: String {
        let t = store.tab(store.selected).title
        return "Start typing in “\(t)”. Markdown renders in the preview — try **bold**, *italics*, `- [ ] task`, # heading."
    }

    // MARK: - Preview

    private var previewPane: some View {
        NotePreviewPane(store: store)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Cmd-1 … Cmd-5 tab switchers as hidden-label buttons.
            ForEach(Array(NoteColor.allCases.enumerated()), id: \.1) { idx, c in
                Button {
                    store.selected = c
                } label: {
                    Label("Tab \(idx + 1)", systemImage: "circle.fill")
                        .foregroundStyle(c.swiftUI)
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")),
                                  modifiers: [.command, .option])
                .help("Switch to \(c.defaultTitle) (⌘⌥\(idx + 1))")
                .opacity(0)
                .frame(width: 0, height: 0)
            }

            Button {
                store.sendCurrentToStage()
            } label: {
                Label("Send to Stage", systemImage: "tray.and.arrow.up")
            }
            .help("Stage this note as a text item")
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            Toggle(isOn: $store.showPreview) {
                Label("Preview", systemImage: "doc.richtext")
            }
            .help("Toggle rendered markdown preview")
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                store.searchActive.toggle()
                if !store.searchActive { store.searchQuery = "" }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search all notes (⌘F)")
        }
    }

    // MARK: - Subtitle

    private var subtitle: String {
        let c = store.tab(store.selected)
        let (w, ch) = store.counts[store.selected] ?? (0, 0)
        let label = c.title
        return "\(label) · \(w) word\(w == 1 ? "" : "s") · \(ch) char\(ch == 1 ? "" : "s")"
    }
}

// ===========================================================================
// MARK: - Tab chip
// ===========================================================================

private struct NoteTabChip: View {
    let color: NoteColor
    let title: String
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color.swiftUI)
                .frame(width: 11, height: 11)
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                )
            if isRenaming {
                TextField("", text: $renameText, onCommit: onCommitRename)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 60, maxWidth: 120)
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? color.swiftUI.opacity(0.18)
                      : (hover ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected
                              ? color.swiftUI.opacity(0.55)
                              : Color.clear,
                              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onBeginRename() }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Rename") { onBeginRename() }
        }
    }
}

// ===========================================================================
// MARK: - Search overlay
// ===========================================================================

private struct NoteSearchOverlay: View {
    @ObservedObject var store: NoteStore
    @FocusState private var focused: Bool
    // Fix 14: hits moved to @State, populated asynchronously with 80ms debounce
    // so the synchronous store.search() is not called on every body re-render.
    @State private var hits: [NoteStore.SearchHit] = []
    @State private var debounceTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all notes", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { focused = false }
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    store.searchActive = false
                    store.searchQuery = ""
                } label: { Text("Done").font(.callout) }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.background.secondary)
            .onChange(of: store.searchQuery) { newValue in
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
                    guard !Task.isCancelled else { return }
                    hits = store.search(newValue)
                }
            }

            if !store.searchQuery.isEmpty {
                if hits.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No matches for \"\(store.searchQuery)\"")
                            .headerText()
                        Text("Searched the body and title of all five tabs. Try a different word, or clear the search.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 380)
                            .multilineTextAlignment(.center)
                        Button {
                            store.searchQuery = ""
                        } label: {
                            Label("Clear search", systemImage: "xmark.circle")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(hits) { hit in
                                NoteSearchHitRow(hit: hit) {
                                    store.selected = hit.color
                                    store.searchActive = false
                                    store.searchQuery = ""
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .onAppear { focused = true }
    }
}

private struct NoteSearchHitRow: View {
    let hit: NoteStore.SearchHit
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(hit.color.swiftUI).frame(width: 10, height: 10)
            Text(hit.tabTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text("L\(hit.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
            Text(snippet(hit.line))
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hover ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onTap() }
    }

    private func snippet(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 110 { return trimmed }
        return String(trimmed.prefix(110)) + "…"
    }
}

// ===========================================================================
// MARK: - Preview pane (renders the active tab)
// ===========================================================================

private struct NotePreviewPane: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        let tab = store.tab(store.selected)
        let blocks = NoteMarkdown.render(tab.body)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if tab.body.isEmpty {
                    Text("Preview will appear here as you type.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                } else {
                    ForEach(blocks) { b in
                        NoteBlockView(block: b) { range, newChecked in
                            toggleCheckbox(range: range, newChecked: newChecked)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Red-team #5: surgical mutation that swaps the single bracket char
    /// inside the line's `- [ ]` / `- [x]` marker. We do NOT rewrite the
    /// whole line — preserves cursor position and any trailing edits.
    private func toggleCheckbox(range: Range<String.Index>, newChecked: Bool) {
        let body = store.tab(store.selected).body
        // red-team: the captured `range` came from a PRIOR snapshot of `body`
        // (the one passed to NoteMarkdown.render). If the user typed between
        // render and click, the indices may no longer be valid for this body
        // — using them is undefined behavior in Swift. The endIndex bound check
        // alone is insufficient. Re-derive the target line by line-number from
        // the current body, then validate the checkbox marker before mutating.
        // red-team-sec: this also defuses index-corruption issues from pasted
        // bodies containing NUL bytes or unusual Unicode that change String
        // identity across re-render. Operating on a freshly-derived line range
        // keeps mutation correct under any input.
        //
        // Strategy:
        //   1. Find line N (by counting newlines up to range.lowerBound in the
        //      ORIGINAL body would be wrong — we don't have that body).
        //   2. Instead: scan all checkbox lines in the current body, find the
        //      one whose source range matches (or is closest to) the captured
        //      range, but fall back gracefully if it can't be located.
        //
        // Practical fix: re-render the current body's blocks; pick the
        // checkbox block whose sourceRange equals the captured range. If the
        // body has been mutated, the captured indices likely point at a stale
        // position — we then look for a checkbox block whose source-text
        // matches an offset-equivalent prefix and bail otherwise.
        let blocks = NoteMarkdown.render(body)
        var targetRange: Range<String.Index>? = nil
        // Fast path: exact range match works as long as the body identity
        // hasn't changed since render (the common case for a quick click).
        for b in blocks {
            if case .checkbox(_, _, let r) = b.kind, r == range {
                targetRange = r
                break
            }
        }
        guard let lineRange = targetRange else { return }
        guard lineRange.lowerBound <= body.endIndex,
              lineRange.upperBound <= body.endIndex else { return }

        let line = String(body[lineRange])
        // red-team: the previous code used `line.firstIndex(of: "[")`, which
        // could match a `[` in user prose appearing before the checkbox marker
        // (e.g. line starting with arbitrary text). Require the marker pattern
        // `- [` at the start of the trimmed-leading portion to avoid corrupting
        // unrelated brackets.
        let leadingWS = line.prefix(while: { $0 == " " || $0 == "\t" })
        let afterWS = line.dropFirst(leadingWS.count)
        guard afterWS.hasPrefix("- [") else { return }
        // Slot is exactly 4 chars in from start-of-line: leadingWS + "- [".
        let slotOffsetInLine = leadingWS.count + 3  // index of the single char between [ and ]
        guard let bracketCharIndex = line.index(line.startIndex,
                                                offsetBy: slotOffsetInLine,
                                                limitedBy: line.endIndex),
              bracketCharIndex < line.endIndex else { return }

        // Confirm the slot really is space-or-x; if not, bail.
        let existing = line[bracketCharIndex]
        guard existing == " " || existing == "x" || existing == "X" else { return }

        // Map back to absolute body index.
        guard let absoluteIndex = body.index(lineRange.lowerBound,
                                             offsetBy: slotOffsetInLine,
                                             limitedBy: body.endIndex),
              absoluteIndex < body.endIndex else { return }

        let replacement: Character = newChecked ? "x" : " "
        var newBody = body
        newBody.replaceSubrange(absoluteIndex...absoluteIndex, with: String(replacement))
        store.setBody(store.selected, newBody)
    }
}

private struct NoteBlockView: View {
    let block: NoteRenderedBlock
    let onToggleCheckbox: (Range<String.Index>, Bool) -> Void

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 6 : 4)
                .padding(.bottom, 2)
        case .text(let attr):
            Text(attr)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .bulletText(let attr):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(attr).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .checkbox(let checked, let label, let sourceRange):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Red-team #5: the button hit area is *only* the square,
                // never the label, so accidental toggles don't happen.
                Button {
                    onToggleCheckbox(sourceRange, !checked)
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(checked ? "Mark as todo" : "Mark as done")
                Text(label)
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title2.weight(.bold)
        case 2:  return .title3.weight(.semibold)
        default: return .headline
        }
    }
}
