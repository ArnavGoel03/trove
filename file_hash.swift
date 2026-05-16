// Trove — File Hash pane.
//   • Drop files (or pick) to compute MD5 + SHA1 + SHA256 in a single streaming pass.
//   • Compare-against field for one-click integrity checks.
//   • Bounded concurrency, per-row cancellation, per-row error surfacing.
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import CommonCrypto

// ===========================================================================
// MARK: - Streaming hash core
// ===========================================================================

/// Three-in-one CommonCrypto streaming hasher. One pass over the file feeds
/// MD5, SHA1, SHA256 simultaneously — one read of (potentially gigabytes of)
/// data, three digests out the other end.
///
/// Red-team #1 (huge files): we never materialize the file in memory; chunks
/// are 1 MiB and reused. `Data.withUnsafeBytes` hands us a stable pointer per
/// chunk so the CC_*_Update calls don't copy.
// MD5/SHA1 are flagged "cryptographically broken" by Apple's deprecation
// annotations — fair for security use, but file-integrity verification
// (matching against an upstream-published checksum) is the legitimate
// non-security use of these algorithms. CC_*_Init/Update/Final calls below
// emit deprecation warnings; they are intentional and harmless here.
final class HashTripleHasher {
    private var md5 = CC_MD5_CTX()
    private var sha1 = CC_SHA1_CTX()
    private var sha256 = CC_SHA256_CTX()

    init() {
        CC_MD5_Init(&md5)
        CC_SHA1_Init(&sha1)
        CC_SHA256_Init(&sha256)
    }

    func update(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let len = CC_LONG(raw.count)
            CC_MD5_Update(&md5, base, len)
            CC_SHA1_Update(&sha1, base, len)
            CC_SHA256_Update(&sha256, base, len)
        }
    }

    func finalize() -> (md5: String, sha1: String, sha256: String) {
        var md5Out  = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        var sha1Out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        var sha2Out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_MD5_Final(&md5Out, &md5)
        CC_SHA1_Final(&sha1Out, &sha1)
        CC_SHA256_Final(&sha2Out, &sha256)
        return (HashHex.encode(md5Out), HashHex.encode(sha1Out), HashHex.encode(sha2Out))
    }
}

enum HashHex {
    static func encode(_ bytes: [UInt8]) -> String {
        // Lowercase hex; sized buffer beats String(format:) in a hot loop.
        let table: [Character] = Array("0123456789abcdef")
        var out = [Character]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(table[Int(b >> 4)])
            out.append(table[Int(b & 0x0F)])
        }
        return String(out)
    }
}

/// Streaming three-hash computation for a single URL.
/// - Throws if the URL is unreadable, is a directory, or any chunk read fails.
/// - Honors `Task.checkCancellation()` between chunks so cancelled rows stop fast.
func computeHashes(of url: URL,
                   progress: @escaping (Double) -> Void) async throws
                   -> (md5: String, sha1: String, sha256: String) {
    let fm = FileManager.default

    // Red-team #4 (directory dropped): refuse early with a clear error.
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw HashError.notFound
    }
    if isDir.boolValue { throw HashError.isDirectory }

    let attrs = try fm.attributesOfItem(atPath: url.path)
    let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

    // red-team-sec: reject sockets, FIFOs, devices, and other non-regular
    // files BEFORE opening the FileHandle. Hashing /dev/zero would run
    // forever; hashing a pipe/socket has no integrity meaning anyway. We
    // check `fileType` from POSIX attrs because `isRegularFileKey` on URL
    // can be cached at URL-creation time.
    if let ft = attrs[.type] as? FileAttributeType, ft != .typeRegular {
        throw HashError.notRegular
    }

    // Red-team #5 (permission denied / sandbox): FileHandle init throws a
    // localized OS error which we propagate so the row shows a useful message.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let hasher = HashTripleHasher()
    var read: Int64 = 0
    let chunkBytes = 1 << 20  // 1 MiB
    // speed: throttle MainActor hops. A 10 GiB file produces 10240 chunks; one
    // hop per chunk floods the main run loop and stalls SwiftUI. We only post
    // progress when the integer percentage advances OR at least 8 MiB has
    // accumulated since the last post — whichever comes first.
    var lastPostedPct: Int = -1
    var lastPostedBytes: Int64 = 0

    while true {
        try Task.checkCancellation()
        // Red-team #2 (file moved/truncated mid-hash): per-chunk read can throw,
        // we let it bubble up and surface in the row.
        guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
        hasher.update(chunk)
        read += Int64(chunk.count)
        if totalSize > 0 {
            let p = min(1.0, Double(read) / Double(totalSize))
            let pct = Int(p * 100)
            // speed: post on percentage change or every 8 MiB on huge files so
            // the bar still moves visibly for files where 1% is many seconds.
            if pct != lastPostedPct || (read - lastPostedBytes) >= (8 << 20) {
                lastPostedPct = pct
                lastPostedBytes = read
                await MainActor.run { progress(p) }
            }
        }
    }
    // speed: always post a final 1.0 so the UI doesn't leave a sub-100% bar
    // visible during the brief window before .done overwrites the view.
    if totalSize > 0 {
        await MainActor.run { progress(1.0) }
    }

    return hasher.finalize()
}

enum HashError: LocalizedError {
    case isDirectory
    case notFound
    case notRegular
    var errorDescription: String? {
        switch self {
        case .isDirectory: return "skipped: directory"
        case .notFound:    return "file not found"
        case .notRegular:  return "skipped: not a regular file (socket / FIFO / device)"
        }
    }
}

// ===========================================================================
// MARK: - Bounded concurrency gate
// ===========================================================================

/// Async semaphore: caps simultaneous file hashes at ~4 so dropping 200 files
/// at once doesn't open 200 FileHandles or hammer the disk in parallel.
/// (Red-team #3.)
actor HashConcurrencyGate {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    // red-team: returns true iff a permit was actually acquired. Callers MUST
    // only call release() when this returned true, otherwise `inFlight` drops
    // below zero on cancellation paths.
    @discardableResult
    func acquire() async -> Bool {
        if inFlight < limit {
            inFlight += 1
            return true
        }
        await withCheckedContinuation { cont in waiters.append(cont) }
        // resumer already incremented inFlight on our behalf — see release().
        return true
    }

    func release() {
        // red-team: when waking a waiter we hand the permit directly to them
        // (do not decrement+increment). The hand-off keeps inFlight at the
        // limit so a third party calling acquire() between this release and
        // the waiter's resume won't slip past the cap.
        //
        // red-team-2: previously `inFlight` was incremented only in the
        // fast path; the hand-off path implicitly relied on inFlight already
        // being at `limit` (since we just released a slot but didn't drop
        // the count). That invariant is correct — the slot transfers from
        // the releaser to the waiter without ever touching the counter.
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            return
        }
        inFlight -= 1
        if inFlight < 0 { inFlight = 0 }   // belt-and-suspenders
    }
}

// ===========================================================================
// MARK: - Row model
// ===========================================================================

@MainActor
final class HashRow: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    @Published var progress: Double = 0
    @Published var state: HashRowState = .computing

    private(set) var task: Task<Void, Never>? = nil

    init(url: URL) {
        self.url = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Begin hashing. Acquires the gate before opening the file handle.
    func start(gate: HashConcurrencyGate) {
        task = Task { [weak self] in
            guard let self else { return }
            // red-team: track acquisition. If the task is cancelled before we
            // ever held a permit we must not call release() — see gate.release
            // comment for the invariant.
            let acquired = await gate.acquire()
            defer {
                if acquired { Task { await gate.release() } }
            }
            do {
                let result = try await computeHashes(of: self.url) { p in
                    self.progress = p
                }
                if Task.isCancelled { return }
                self.state = .done(md5: result.md5, sha1: result.sha1, sha256: result.sha256)
            } catch is CancellationError {
                // Row was removed; nothing to surface.
                return
            } catch {
                if Task.isCancelled { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    /// Red-team #7 (cancellation): caller invokes this when the row is removed
    /// so an in-flight multi-GB hash doesn't keep churning on a dead row.
    func cancel() { task?.cancel() }
}

enum HashRowState {
    case computing
    case done(md5: String, sha1: String, sha256: String)
    case error(String)
}

// ===========================================================================
// MARK: - Pane view model
// ===========================================================================

@MainActor
final class HashViewModel: ObservableObject {
    @Published var rows: [HashRow] = []
    @Published var compareText: String = ""

    // speed: hashing is part I/O, part CPU (MD5+SHA1+SHA256 simultaneously on
    // every chunk is non-trivial AES-NI-free CPU work). Scale concurrency with
    // core count instead of the previous fixed 4, capped at 8 so we don't
    // thrash SSD parallel-queue depth or context-switch storm on big-iron Macs.
    private let gate = HashConcurrencyGate(
        limit: max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
    )

    /// Normalized form of the compare text. Red-team #6: trim whitespace,
    /// lowercase, and treat empty as "no comparison" (never matches anything).
    var compareNormalized: String {
        compareText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func addURLs(_ urls: [URL]) {
        // red-team: expand dropped folders to their regular-file children so
        // a folder drop hashes everything inside rather than being silently
        // skipped by the symlink-resolution + regular-file checks below.
        let urls = troveExpandFolders(urls, allowedExtensions: nil, cap: 1000)
        for u in urls {
            // Dedupe: same path already in the list? Skip silently.
            if rows.contains(where: { $0.url.path == u.path }) { continue }
            // red-team-sec: resolve symlinks before adding so a dropped alias
            // pointing at /dev/random surfaces as a "not a regular file"
            // error against the resolved target rather than silently kicking
            // off an infinite hash. Dedupe is on the resolved path too so
            // hard-linked dupes still collapse.
            let resolved = u.resolvingSymlinksInPath()
            if rows.contains(where: { $0.url.path == resolved.path }) { continue }
            let row = HashRow(url: resolved)
            rows.append(row)
            row.start(gate: gate)
        }
    }

    func remove(_ row: HashRow) {
        row.cancel()
        rows.removeAll { $0.id == row.id }
    }

    func clearAll() {
        for r in rows { r.cancel() }
        rows.removeAll()
    }

    /// True if any row is still hashing — drives the toolbar Cancel button
    /// visibility.
    var hasComputingRows: Bool {
        rows.contains(where: {
            if case .computing = $0.state { return true } else { return false }
        })
    }

    /// Cancel every in-flight hash without removing rows — partial progress
    /// stays visible, the row transitions out of `.computing`. Mirrors the
    /// row-level `cancel()` but in bulk so the user can stop a folder-drop of
    /// 100 multi-GB files with one click.
    func cancelAllComputing() {
        var cancelled = 0
        for r in rows {
            if case .computing = r.state {
                r.cancel()
                r.state = .error("Cancelled")
                cancelled += 1
            }
        }
        if cancelled > 0 {
            SharedStore.stage.flash("Cancelled \(cancelled) hashing row\(cancelled == 1 ? "" : "s")",
                                    kind: .warning)
        }
    }

    /// True if `hash` matches the (normalized) compare field. Empty compare
    /// always returns false — never a false-positive checkmark.
    func matches(_ hash: String) -> Bool {
        let cmp = compareNormalized
        guard !cmp.isEmpty else { return false }
        return hash.lowercased() == cmp
    }
}

// ===========================================================================
// MARK: - Pane view
// ===========================================================================

public struct FileHashView: View {
    @StateObject private var vm = HashViewModel()
    @EnvironmentObject var stage: Stage
    @State private var dropTargeted = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                compareCard
                dropCard
                if !vm.rows.isEmpty {
                    ForEach(vm.rows) { row in
                        HashRowCard(row: row, vm: vm, stage: stage)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Hash")
        .navigationSubtitle("\(vm.rows.count) file\(vm.rows.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Bulk export — write a canonical shasum-style SHA256SUMS file
                // across every completed row. Drives the CI/verify workflow
                // users actually do with hash output.
                if HashSaveHelpers.hasDoneRows(vm.rows) {
                    Button {
                        HashSaveHelpers.saveAllSHA256SUMS(rows: vm.rows, stage: stage)
                    } label: {
                        Label("Save All…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .help("Write a SHA256SUMS-style file (one line per file) you can verify with `shasum -c`")
                }

                if vm.hasComputingRows {
                    Button(role: .destructive) {
                        vm.cancelAllComputing()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Cancel every in-flight hash (Esc or ⌘.)")
                    Button("") { vm.cancelAllComputing() }
                        .keyboardShortcut(".", modifiers: [.command])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }

                Button {
                    pickFiles()
                } label: {
                    Label("Choose file…", systemImage: "doc.badge.plus")
                }
                .help("Open file picker")

                Button(role: .destructive) {
                    vm.clearAll()
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .disabled(vm.rows.isEmpty)
                .help("Remove all rows and cancel running hashes")
            }
        }
    }

    // ----- compare field --------------------------------------------------

    private var compareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                    Text("Compare against").font(.headline)
                    Spacer()
                    if !vm.compareNormalized.isEmpty {
                        Text("\(vm.compareNormalized.count) chars")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                TextField("Paste an expected MD5 / SHA1 / SHA256 hash to verify…",
                          text: $vm.compareText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Case-insensitive · whitespace trimmed · matches show a green check next to the corresponding hash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // ----- drop zone ------------------------------------------------------

    private var dropCard: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Drop files to hash").font(.title3.weight(.medium))
                Text("MD5 + SHA1 + SHA256 are computed in a single streaming pass — works on multi-GB files.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button { pickFiles() } label: {
                    Label("Choose file…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
                .accessibilityHint("Opens a file picker; folders are not accepted")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            // red-team-a11y: keep child elements individually navigable
            // (especially the Choose-file button) so keyboard / VoiceOver
            // users can still trigger the picker.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drop files to hash. Folders are not accepted.")
            // Drop-target highlight — tinted background + dashed accent border
            // while the user is hovering files over the card.
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(dropTargeted ? Color.accentColor.opacity(0.10) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        dropTargeted ? Color.accentColor : Color.clear,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            )
            // red-team: drop-target fade ignored Reduce Motion.
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil : .easeInOut(duration: 0.15),
                       value: dropTargeted)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // ----- handlers -------------------------------------------------------

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false  // RT#4: never accept dirs from picker
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            vm.addURLs(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var collected: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { obj, _ in
                if let u = obj { collected.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            vm.addURLs(collected)
        }
    }
}

// ===========================================================================
// MARK: - Per-row card
// ===========================================================================

private struct HashRowCard: View {
    @ObservedObject var row: HashRow
    let vm: HashViewModel
    let stage: Stage

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                content
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(row.url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(row.size.human)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            } label: { Image(systemName: "arrow.up.right.square") }
            .buttonStyle(.borderless).help("Reveal in Finder")

            Button(role: .destructive) {
                vm.remove(row)
            } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .help("Remove (cancels in-flight hashing)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.state {
        case .computing:
            HStack(spacing: 10) {
                ProgressView(value: row.progress)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                // speed: status label reads "Hashing…" so the row visually
                // announces the work in progress the instant it appears on
                // screen — no "computing 0%" ghost state before any bytes have
                // flowed through the hasher.
                Text("Hashing…")
                    .font(.callout).foregroundStyle(.secondary)
                if row.progress > 0 {
                    Text("\(Int(row.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("error: \(msg)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
        case .done(let md5, let sha1, let sha256):
            VStack(alignment: .leading, spacing: 6) {
                HashLine(label: "MD5",    value: md5,    matched: vm.matches(md5),    sourceURL: row.url, stage: stage)
                HashLine(label: "SHA1",   value: sha1,   matched: vm.matches(sha1),   sourceURL: row.url, stage: stage)
                HashLine(label: "SHA256", value: sha256, matched: vm.matches(sha256), sourceURL: row.url, stage: stage)
            }
        }
    }
}

private struct HashLine: View {
    let label: String
    let value: String
    let matched: Bool
    let sourceURL: URL
    let stage: Stage

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if matched {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("match").font(.caption.weight(.medium))
                }
                .foregroundStyle(.green)
                .help("Matches the compare field")
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(value, forType: .string)
                stage.flash("Copied \(label)")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(label) to clipboard")

            // More menu — secondary verbs that aren't worth a top-level button.
            // Style mirrors pdf.swift's outputRow.
            Menu {
                Button {
                    let pair = "\(value)  \(sourceURL.lastPathComponent)"
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(pair, forType: .string)
                    stage.flash("Copied \(label)  filename")
                } label: {
                    Label("Copy as \"hash  filename\"", systemImage: "doc.on.doc")
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(sourceURL.lastPathComponent, forType: .string)
                    stage.flash("Copied filename")
                } label: {
                    Label("Copy filename only", systemImage: "doc.on.doc")
                }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                } label: {
                    Label("Reveal source file in Finder", systemImage: "magnifyingglass")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        .contextMenu {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(value, forType: .string)
                stage.flash("Copied \(label)")
            } label: { Label("Copy \(label)", systemImage: "doc.on.doc") }
            Button {
                let pair = "\(value)  \(sourceURL.lastPathComponent)"
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(pair, forType: .string)
                stage.flash("Copied \(label)  filename")
            } label: { Label("Copy as \"hash  filename\"", systemImage: "doc.on.doc") }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(sourceURL.lastPathComponent, forType: .string)
                stage.flash("Copied filename")
            } label: { Label("Copy filename only", systemImage: "doc.on.doc") }
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            } label: { Label("Reveal source file in Finder", systemImage: "magnifyingglass") }
        }
    }
}

// ===========================================================================
// MARK: - Save helpers (statics so closures don't capture view state)
// ===========================================================================

private enum HashSaveHelpers {
    private static let kSaveDirKey = "file_hash.saveDir.last"

    /// Build the canonical shasum format: one row per completed file,
    /// `<sha256>  <basename>` with EXACTLY two spaces between hash and name
    /// (this is the format `shasum -a 256 -c SHA256SUMS` expects).
    /// MainActor-isolated because HashRow's `state` is.
    @MainActor
    static func sha256SumsBody(_ rows: [HashRow]) -> String {
        var lines: [String] = []
        for r in rows {
            if case .done(_, _, let sha256) = r.state {
                lines.append("\(sha256)  \(r.url.lastPathComponent)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func hasDoneRows(_ rows: [HashRow]) -> Bool {
        rows.contains { r in
            if case .done = r.state { return true } else { return false }
        }
    }

    /// Write a SHA256SUMS-style file via NSSavePanel. Remembers last directory.
    @MainActor
    static func saveAllSHA256SUMS(rows: [HashRow], stage: Stage) {
        let body = sha256SumsBody(rows)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage.flash("Nothing to save — no completed hashes yet")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SHA256SUMS"
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.message = "Save a `shasum -c`-compatible checksum file."
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                try body.data(using: .utf8)?.write(to: dest, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                stage.flash("Saved \(dest.lastPathComponent)")
            } catch {
                stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

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
}
