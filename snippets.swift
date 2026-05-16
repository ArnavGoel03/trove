// Trove — Snippets
//   • Persistent library of named text templates: signatures, prompt scaffolds,
//     boilerplate. Click to copy; right-click for Stage / Edit / Duplicate / Delete.
//   • Storage:  ~/Library/Application Support/Trove/snippets.json
//
// One file, no @main / no App / no Pane. Compiles alongside main.swift.
//
// Red-team coverage (mirrored in summary):
//   1. Corrupt JSON  → catch in load(), fall back to []. Never crash.
//   2. Disk failure  → save() surfaces error via stage.flash + last in-memory state preserved.
//   3. Rapid edits   → 200ms debounce + serial dispatch queue serializes writes.
//   4. Huge bodies   → 1MB warns via flash, ≥10MB add/update returns .tooLarge (no save).
//   5. Schema drift  → custom init(from:) decodes every field via decodeIfPresent + defaults.
//   6. Weird names   → file is always snippets.json. Snippets identified by UUID, never name.
//   7. Stale sheet   → editor sheet uses local draft + guards against deleted ID on commit.

import SwiftUI
import AppKit
import Foundation

// ===========================================================================
// MARK: - Model
// ===========================================================================

struct Snippet: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var body: String
    var tags: [String]
    let createdAt: Date
    var useCount: Int
    var lastUsedAt: Date?
    var pinned: Bool

    init(id: UUID = UUID(),
         name: String,
         body: String,
         tags: [String] = [],
         createdAt: Date = Date(),
         useCount: Int = 0,
         lastUsedAt: Date? = nil,
         pinned: Bool = false) {
        self.id = id
        self.name = name
        self.body = body
        self.tags = tags
        self.createdAt = createdAt
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
    }

    // Custom decoding so future-added fields and previously-missing fields don't
    // explode on existing files. Every field except `id` has a sane default.
    enum CodingKeys: String, CodingKey {
        case id, name, body, tags, createdAt, useCount, lastUsedAt, pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id: tolerate missing by minting a fresh one — corrupt rows still load.
        self.id         = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name       = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        self.body       = (try? c.decode(String.self, forKey: .body)) ?? ""
        self.tags       = (try? c.decode([String].self, forKey: .tags)) ?? []
        self.createdAt  = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.useCount   = (try? c.decode(Int.self, forKey: .useCount)) ?? 0
        self.lastUsedAt = try? c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.pinned     = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
    }
}

enum SnippetError: LocalizedError {
    case tooLarge(bytes: Int)
    case emptyName
    var errorDescription: String? {
        switch self {
        case .tooLarge(let b): return "Snippet body is \(b / 1024) KB — limit is 10 MB."
        case .emptyName:       return "Snippet name can't be empty."
        }
    }
}

// ===========================================================================
// MARK: - Store
// ===========================================================================

@MainActor
final class SnippetStore: ObservableObject {
    // Fix 13: `visible` is now @Published, populated on snippets/search changes.
    var snippets: [Snippet] = [] {
        willSet { objectWillChange.send() }
        didSet  { recomputeVisible() }
    }
    var search: String = "" {
        willSet { objectWillChange.send() }
        didSet  { recomputeVisible() }
    }
    /// Surface load errors visually without blocking startup.
    @Published var lastErrorMessage: String? = nil
    @Published private(set) var visible: [Snippet] = []

    private func recomputeVisible() {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [Snippet] = q.isEmpty
            ? snippets
            : snippets.filter { s in
                if s.name.lowercased().contains(q) { return true }
                if s.body.lowercased().contains(q) { return true }
                if s.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
                return false
            }
        visible = filtered.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.createdAt > b.createdAt
        }
    }

    /// 1 MB soft warn, 10 MB hard refuse — stored as bytes for utf8 cost.
    static let warnBytes: Int = 1 * 1024 * 1024
    static let maxBytes:  Int = 10 * 1024 * 1024

    private let fileURL: URL
    /// Serial queue → no torn writes even if save() is called from many places at once.
    private let ioQueue = DispatchQueue(label: "trove.snippets.io", qos: .utility)
    /// Debounce token; cancelled and replaced on each save() call within 200 ms.
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if let u = fileURL {
            self.fileURL = u
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
            self.fileURL = appSupport
                .appendingPathComponent("Trove", isDirectory: true)
                .appendingPathComponent("snippets.json")
        }
        load()
    }

    // MARK: filtered + sorted view
    // Fix 13: visible is now @Published (see above). Computed inline removed.

    // MARK: CRUD

    /// Returns nil on success or a SnippetError describing why it was rejected.
    @discardableResult
    func add(_ s: Snippet) -> SnippetError? {
        if let e = validate(s) { return e }
        snippets.append(s)
        save()
        return nil
    }

    @discardableResult
    func update(_ s: Snippet) -> SnippetError? {
        if let e = validate(s) { return e }
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return nil }
        snippets[i] = s
        save()
        return nil
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].pinned.toggle()
        save()
    }

    func recordUse(_ id: UUID) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].useCount &+= 1
        snippets[i].lastUsedAt = Date()
        save()
    }

    func duplicate(_ id: UUID) -> Snippet? {
        guard let src = snippets.first(where: { $0.id == id }) else { return nil }
        let copy = Snippet(name: src.name + " copy",
                           body: src.body,
                           tags: src.tags,
                           pinned: false)
        snippets.append(copy)
        save()
        return copy
    }

    private func validate(_ s: Snippet) -> SnippetError? {
        let trimmed = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyName }
        // red-team: a pathological paste (e.g. drag of an entire chat
        // transcript into the Name field) could blow up sidebar layout and
        // make the snippet unidentifiable in the list. Names are single-line
        // UI labels — keep them sane. We don't propagate as an error because
        // the caller (`add` / `update`) snapshots from the editor sheet; just
        // truncate to a generous-but-bounded length.
        // Note: this mutates the caller's struct via the by-value snapshot
        // path; tag this as advisory rather than a hard rejection.
        let bytes = s.body.utf8.count
        if bytes > Self.maxBytes { return .tooLarge(bytes: bytes) }
        return nil
    }

    /// red-team: enforce a hard ceiling on the human-visible name. UI rows
    /// `lineLimit(1)` anyway, but stale long names make the JSON ugly and
    /// search slow. Truncate at 200 chars (graphemes) — strictly more than any
    /// reasonable label, less than any pathological paste.
    static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200 { return trimmed }
        return String(trimmed.prefix(200))
    }

    /// Returns true when the body is between warn and max — caller can flash a heads-up.
    func isOversizeWarn(_ body: String) -> Bool {
        let n = body.utf8.count
        return n > Self.warnBytes && n <= Self.maxBytes
    }

    // MARK: persistence

    func load() {
        let url = self.fileURL
        // Run synchronously on init to avoid a flash-of-empty-list, but defensive
        // about every failure mode: missing file, bad JSON, weird permissions.
        do {
            guard let data = boundedRead(url) else { return }
            // Empty file → treat as fresh install, not a crash.
            guard !data.isEmpty else {
                self.snippets = []
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([Snippet].self, from: data)
            self.snippets = decoded
        } catch let e as NSError where e.domain == NSCocoaErrorDomain
                                  && e.code == NSFileReadNoSuchFileError {
            // First launch — fine.
            self.snippets = []
        } catch {
            // Corrupt / truncated / unreadable. Keep app alive and surface.
            self.snippets = []
            self.lastErrorMessage = "Couldn't read snippets.json — starting empty."
            // Best-effort: rename the bad file out of the way so the next save
            // doesn't accidentally append to garbage.
            let bak = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: bak)
        }
    }

    /// Debounced + queue-serialized save. Captures a snapshot on the main actor,
    /// then writes off-thread via a temp file + atomic replaceItem so we never
    /// leave a half-written file if the process is killed mid-write.
    func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Snapshot on main, then perform actual disk I/O on the io queue.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let snapshot = self.snippets
                let url = self.fileURL
                self.ioQueue.async {
                    let result = Self.writeSnapshot(snapshot, to: url)
                    if case .failure(let err) = result {
                        // In-memory state is already authoritative — we just
                        // couldn't persist it. Tell the user, don't drop data.
                        Task { @MainActor in
                            SharedStore.stage.flash("Couldn't save snippets: \(err.localizedDescription)")
                        }
                    }
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Off-main writer. Encodes, writes to a sibling .tmp, then atomically replaces.
    /// `replaceItem` swaps inodes so a reader either sees the old file or the new
    /// file — never an in-progress one.
    nonisolated private static func writeSnapshot(_ snippets: [Snippet], to url: URL) -> Result<Void, Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snippets)

            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".snippets-\(UUID().uuidString.prefix(8)).tmp")
            try data.write(to: tmp, options: [.atomic])

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

// ===========================================================================
// MARK: - Public View
// ===========================================================================

/// Drop-in pane. Wire up from RootView with `SnippetsView()`.
struct SnippetsView: View {
    @StateObject private var store = SnippetStore()
    @EnvironmentObject var stage: Stage

    @State private var editorTarget: SnippetEditorTarget? = nil
    @State private var deleteCandidate: Snippet? = nil

    var body: some View {
        Group {
            if store.snippets.isEmpty {
                SnippetsEmpty(onNew: { editorTarget = .new })
            } else {
                snippetList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $store.search, prompt: "Search snippets")
        .navigationTitle("Snippets")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editorTarget = .new } label: {
                    Label("New", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
                .help("Create a new snippet")
            }
        }
        .sheet(item: $editorTarget) { target in
            SnippetEditorSheet(
                store: store,
                target: target,
                onClose: { editorTarget = nil }
            )
            .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 480)
        }
        .confirmationDialog(
            "Delete this snippet?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { snip in
            Button("Delete", role: .destructive) {
                store.delete(snip.id)
                stage.flash("Deleted \(snip.name)")
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { snip in
            Text("\"\(snip.name)\" will be removed from your snippet library.")
        }
        .onAppear {
            if let msg = store.lastErrorMessage {
                stage.flash(msg)
                store.lastErrorMessage = nil
            }
        }
    }

    private var subtitle: String {
        let total = store.snippets.count
        let shown = store.visible.count
        if total == 0 { return "No snippets yet" }
        return "\(shown) of \(total) snippet\(total == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var snippetList: some View {
        let rows = store.visible
        if rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matches for \"\(store.search)\"")
                    .headerText()
                Text("Try a different query, or clear the search to see all \(store.snippets.count) snippet\(store.snippets.count == 1 ? "" : "s").")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { snip in
                        SnippetRow(
                            snippet: snip,
                            onCopy: { copy(snip) },
                            onTogglePin: { store.togglePin(snip.id) }
                        )
                        .contextMenu {
                            Button("Copy") { copy(snip) }
                            Button("Send to Stage") {
                                stage.addText(snip.body)
                                store.recordUse(snip.id)
                                stage.flash("Sent \(snip.name) to Stage")
                            }
                            Divider()
                            Button("Edit…") { editorTarget = .edit(snip.id) }
                            Button("Duplicate") {
                                if let copy = store.duplicate(snip.id) {
                                    stage.flash("Duplicated as \(copy.name)")
                                }
                            }
                            Button(snip.pinned ? "Unpin" : "Pin") { store.togglePin(snip.id) }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                deleteCandidate = snip
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func copy(_ snip: Snippet) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snip.body, forType: .string)
        // red-team: without broadcasting our own pasteboard write, an active
        // ClipHistory watcher would ingest the snippet body 0.5s later as a
        // "new" clipboard event — duplicating the snippet into the history
        // ring buffer on every click. Match Stage.copyAllAs* convention.
        NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
        store.recordUse(snip.id)
        stage.flash("Copied \(snip.name)")
    }
}

// ===========================================================================
// MARK: - Row
// ===========================================================================

private struct SnippetRow: View {
    let snippet: Snippet
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    @State private var hover = false

    private var preview: String {
        let firstLine = snippet.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(snippet.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if snippet.useCount > 0 {
                            Text("\(snippet.useCount)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.18), in: Capsule())
                                .foregroundStyle(.tint)
                                .help("Used \(snippet.useCount) time\(snippet.useCount == 1 ? "" : "s")")
                        }
                        if !snippet.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(snippet.tags.prefix(4), id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.secondary.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                if snippet.tags.count > 4 {
                                    Text("+\(snippet.tags.count - 4)")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Text(preview)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button(action: onTogglePin) {
                    Image(systemName: snippet.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(snippet.pinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(snippet.pinned ? "Unpin" : "Pin to top")
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hover ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onCopy() }
    }
}

// ===========================================================================
// MARK: - Empty state
// ===========================================================================

private struct SnippetsEmpty: View {
    let onNew: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No snippets yet").font(.title2.weight(.medium))
            Text("Save email signatures, prompt scaffolds, and boilerplate once. Click any saved snippet to copy it instantly, or send it to Stage.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
                .multilineTextAlignment(.center)
            Button(action: onNew) {
                Label("New snippet", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
            .keyboardShortcut("n", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// ===========================================================================
// MARK: - Editor sheet
// ===========================================================================

/// `Identifiable` wrapper so `.sheet(item:)` re-presents cleanly when the user
/// hops between New and Edit on different rows.
enum SnippetEditorTarget: Identifiable, Hashable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
        case .new:           return "new"
        case .edit(let id):  return id.uuidString
        }
    }
}

private struct SnippetEditorSheet: View {
    @ObservedObject var store: SnippetStore
    let target: SnippetEditorTarget
    let onClose: () -> Void

    @EnvironmentObject var stage: Stage

    @State private var name: String = ""
    @State private var draftBody: String = ""
    @State private var tagsText: String = ""
    @State private var loaded = false
    @State private var underlyingMissing = false
    @State private var inlineError: String? = nil

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bodyByteCount: Int { draftBody.utf8.count }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit snippet" : "New snippet")
                    .font(.title3.weight(.semibold))
                Spacer()
                if bodyByteCount > SnippetStore.warnBytes {
                    Label("Large snippet (\(bodyByteCount / 1024) KB)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(bodyByteCount > SnippetStore.maxBytes ? Color.red : Color.orange)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if underlyingMissing {
                        Label("This snippet was deleted from another window. You can save a new copy or close.",
                              systemImage: "exclamationmark.octagon")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.caption).foregroundStyle(.secondary)
                        TextField("e.g. Email signature", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Tags").font(.caption).foregroundStyle(.secondary)
                            Text("comma-separated").font(.caption).foregroundStyle(.tertiary)
                        }
                        TextField("work, prompt, signature", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Body").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(byteSummary)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        TextEditor(text: $draftBody)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.separator, lineWidth: 0.5)
                            )
                    }

                    if let err = inlineError {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing && !underlyingMissing ? "Save" : "Add") {
                    commit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || bodyByteCount > SnippetStore.maxBytes)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear { loadIfNeeded() }
    }

    private var byteSummary: String {
        let kb = Double(bodyByteCount) / 1024.0
        if bodyByteCount > SnippetStore.maxBytes {
            return String(format: "%.0f KB · over 10 MB limit", kb)
        }
        return String(format: "%.1f KB", kb)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new:
            name = ""; draftBody = ""; tagsText = ""
        case .edit(let id):
            // Red-team #7: snippet may have been deleted between sheet presentation
            // and load. Mark the sheet as orphaned and let the user save a copy.
            if let s = store.snippets.first(where: { $0.id == id }) {
                name = s.name
                draftBody = s.body
                tagsText = s.tags.joined(separator: ", ")
            } else {
                underlyingMissing = true
                name = ""; draftBody = ""; tagsText = ""
            }
        }
    }

    private func parsedTags() -> [String] {
        // red-team: previously a typo'd "work, work, prompt" persisted both
        // "work" entries, and tag chips in the row visually duplicated. Dedup
        // case-insensitively while preserving the user's original casing of
        // the first occurrence and the user's intended ordering.
        var seen = Set<String>()
        var out: [String] = []
        for raw in tagsText.split(separator: ",") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    private func commit() {
        inlineError = nil
        // red-team: clamp the name length here so the persisted record is
        // bounded; pathological pastes into the Name field don't survive.
        let cleanName = SnippetStore.sanitizedName(name)
        guard !cleanName.isEmpty else {
            inlineError = "Name can't be empty."
            return
        }

        // Hard refuse oversized bodies before any state mutates.
        if bodyByteCount > SnippetStore.maxBytes {
            inlineError = "Body is \(bodyByteCount / 1024) KB — must be under 10 MB."
            return
        }

        let warn = store.isOversizeWarn(draftBody)

        switch target {
        case .new:
            let s = Snippet(name: cleanName, body: draftBody, tags: parsedTags())
            if let err = store.add(s) {
                inlineError = err.localizedDescription
                return
            }
            stage.flash(warn ? "Saved \(cleanName) (large)" : "Saved \(cleanName)")
        case .edit(let id):
            // Red-team #7 again: editing a row that no longer exists. Save as new.
            if let existing = store.snippets.first(where: { $0.id == id }) {
                var updated = existing
                updated.name = cleanName
                updated.body = draftBody
                updated.tags = parsedTags()
                if let err = store.update(updated) {
                    inlineError = err.localizedDescription
                    return
                }
                stage.flash(warn ? "Updated \(cleanName) (large)" : "Updated \(cleanName)")
            } else {
                let s = Snippet(name: cleanName, body: draftBody, tags: parsedTags())
                if let err = store.add(s) {
                    inlineError = err.localizedDescription
                    return
                }
                stage.flash("Original was deleted — saved \(cleanName) as new")
            }
        }
        onClose()
    }
}
