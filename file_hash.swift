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

/// Four-in-one CommonCrypto streaming hasher. One pass over the file feeds
/// MD5, SHA1, SHA256, and SHA512 simultaneously — one read of (potentially
/// gigabytes of) data, four digests out the other end.
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
    // P1 FIX: add SHA-512 as a fourth CC context in the same single-pass read.
    // No extra I/O cost — the file bytes already flow through the other three.
    private var sha512 = CC_SHA512_CTX()

    init() {
        CC_MD5_Init(&md5)
        CC_SHA1_Init(&sha1)
        CC_SHA256_Init(&sha256)
        CC_SHA512_Init(&sha512)
    }

    func update(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let len = CC_LONG(raw.count)
            CC_MD5_Update(&md5, base, len)
            CC_SHA1_Update(&sha1, base, len)
            CC_SHA256_Update(&sha256, base, len)
            CC_SHA512_Update(&sha512, base, len)
        }
    }

    func finalize() -> (md5: String, sha1: String, sha256: String, sha512: String) {
        var md5Out  = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        var sha1Out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        var sha2Out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        var sha5Out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_MD5_Final(&md5Out, &md5)
        CC_SHA1_Final(&sha1Out, &sha1)
        CC_SHA256_Final(&sha2Out, &sha256)
        CC_SHA512_Final(&sha5Out, &sha512)
        return (HashHex.encode(md5Out), HashHex.encode(sha1Out),
                HashHex.encode(sha2Out), HashHex.encode(sha5Out))
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

/// Streaming four-hash computation for a single URL.
/// - Throws if the URL is unreadable, is a directory, or any chunk read fails.
/// - Honors `Task.checkCancellation()` between chunks so cancelled rows stop fast.
func computeHashes(of url: URL,
                   progress: @escaping (Double) -> Void) async throws
                   -> (md5: String, sha1: String, sha256: String, sha512: String) {
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
    func start(gate: HashConcurrencyGate, vm: HashViewModel) {
        task = Task { [weak self, weak vm] in
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
                self.state = .done(md5: result.md5, sha1: result.sha1,
                                   sha256: result.sha256, sha512: result.sha512)
                // P2: increment O(1) done counter on the ViewModel.
                vm?.incrementDoneCount()
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
    case done(md5: String, sha1: String, sha256: String, sha512: String)
    case error(String)
}

// ===========================================================================
// MARK: - SHA256SUMS verification (power-user item #3)
// ===========================================================================
//
// Drag a `SHA256SUMS` (or `.sha256` / `.md5sums` / `.sha512sum` / etc.) file
// onto the Hash pane along with the target files. Trove parses the sums
// file, hashes each target found alongside it, and shows pass/fail per
// line. This is the workflow upstream Linux ISO sites push: download
// `ubuntu-24.04.iso` + `SHA256SUMS` + `SHA256SUMS.gpg`, then verify.
//
// Lines look like `<hex>  <filename>` (text mode, two spaces) or
// `<hex> *<filename>` (binary mode marker). Comments (`#`) and blank
// lines are ignored. Algorithm is inferred from hex length.

/// Hash algorithm inferred from a sums-file hex length.
enum SUMSAlgorithm: String {
    case md5, sha1, sha256, sha512

    init?(hexLength: Int) {
        switch hexLength {
        case 32:  self = .md5
        case 40:  self = .sha1
        case 64:  self = .sha256
        case 128: self = .sha512
        default:  return nil
        }
    }

    var displayName: String {
        switch self {
        case .md5:    return "MD5"
        case .sha1:   return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }
}

/// One parsed `<hex>  <filename>` line.
struct SUMSParsedLine: Hashable {
    let expectedHash: String   // lowercase hex
    let filename: String       // basename or relative path as written
    let algorithm: SUMSAlgorithm
}

/// Per-entry verification status.
enum SUMSEntryStatus: Equatable {
    case pending
    case match
    case mismatch(actual: String)
    case missing                 // target file not found next to the sums file
    case error(String)
}

/// One row in the verification card.
@MainActor
final class SUMSEntry: ObservableObject, Identifiable {
    let id = UUID()
    let line: SUMSParsedLine
    let targetURL: URL?          // resolved alongside the sums file; nil = missing
    @Published var status: SUMSEntryStatus
    @Published var progress: Double = 0
    /// Module-internal so the verifier in HashViewModel can store the
    /// hashing task without exposing it to the SwiftUI consumer side.
    var task: Task<Void, Never>? = nil

    init(line: SUMSParsedLine, targetURL: URL?) {
        self.line = line
        self.targetURL = targetURL
        self.status = (targetURL == nil) ? .missing : .pending
    }

    func cancel() { task?.cancel() }
}

/// One drop of a sums file produces one of these — wraps all parsed lines
/// plus the source sums URL so the verification card has a sensible title.
@MainActor
final class SUMSVerification: ObservableObject, Identifiable {
    let id = UUID()
    let sumsURL: URL
    let entries: [SUMSEntry]
    let summaryAlgorithm: SUMSAlgorithm   // most-frequent algorithm in the file

    init(sumsURL: URL, entries: [SUMSEntry]) {
        self.sumsURL = sumsURL
        self.entries = entries
        // The vast majority of sums files use one algorithm consistently;
        // pick the modal algorithm so the card subtitle is honest even if
        // someone hand-edited a mixed file.
        var freq: [SUMSAlgorithm: Int] = [:]
        for e in entries { freq[e.line.algorithm, default: 0] += 1 }
        self.summaryAlgorithm = freq.max(by: { $0.value < $1.value })?.key ?? .sha256
    }

    var passCount: Int {
        entries.reduce(0) { $0 + (($1.status == .match) ? 1 : 0) }
    }
    var failCount: Int {
        entries.reduce(0) { acc, e in
            switch e.status {
            case .mismatch, .missing, .error: return acc + 1
            default: return acc
            }
        }
    }
    var pendingCount: Int {
        entries.reduce(0) { $0 + (($1.status == .pending) ? 1 : 0) }
    }
}

/// Stateless parser for sums files.
enum SUMSParser {
    /// File extensions and exact filenames Trove recognizes as sums files.
    /// Mixed-case matched so `Sha256Sums` and `SHA256SUMS.txt` both hit.
    private static let knownExtensions: Set<String> = [
        "md5", "md5sum", "md5sums",
        "sha1", "sha1sum", "sha1sums",
        "sha256", "sha256sum", "sha256sums",
        "sha512", "sha512sum", "sha512sums",
        "sums", "checksum", "checksums",
    ]
    private static let knownBasenames: Set<String> = [
        "md5sums", "sha1sums", "sha256sums", "sha512sums",
        "checksums", "checksums.txt",
        "md5sums.txt", "sha1sums.txt", "sha256sums.txt", "sha512sums.txt",
    ]

    /// True if `url` looks like a sums file by extension or by exact basename.
    static func looksLikeSUMSFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if knownExtensions.contains(ext) { return true }
        let base = url.lastPathComponent.lowercased()
        if knownBasenames.contains(base) { return true }
        return false
    }

    /// Parse `data` (as UTF-8 text) into `[SUMSParsedLine]`. Tolerant:
    /// skips blank lines, comment lines, and lines whose first token is
    /// not a recognized hex length — never throws on bad input.
    static func parse(_ data: Data) -> [SUMSParsedLine] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [SUMSParsedLine] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Coreutils format: `<hash><sp><sp-or-asterisk><filename>`.
            // We tolerate any whitespace run between the two fields, and
            // a leading `*` on the filename (binary-mode marker per
            // GNU `md5sum --binary`).
            //
            // red-team: filenames can contain spaces — splitting on the
            // first whitespace run (not every whitespace) keeps the
            // remainder of the line intact as the filename.
            guard let firstWS = line.firstIndex(where: { $0.isWhitespace }) else { continue }
            let hashPart = String(line[..<firstWS]).lowercased()
            guard let algo = SUMSAlgorithm(hexLength: hashPart.count) else { continue }
            guard hashPart.allSatisfy({ $0.isHexDigit }) else { continue }
            var rest = line[firstWS...].drop(while: { $0.isWhitespace })
            if rest.first == "*" { rest = rest.dropFirst() }   // binary-mode marker
            let filename = String(rest)
            guard !filename.isEmpty else { continue }
            out.append(SUMSParsedLine(expectedHash: hashPart,
                                      filename: filename,
                                      algorithm: algo))
        }
        return out
    }

    /// Read + parse a URL from disk. Returns `nil` on I/O failure or empty
    /// parse so the caller can fall through to treating the file as a
    /// regular hashing target.
    static func tryParse(_ url: URL) -> [SUMSParsedLine]? {
        // red-team-sec: cap reads at 8 MiB so an "accidentally renamed
        // bzImage.sha256" doesn't try to slurp a kernel into RAM as text.
        // Real sums files for entire distros stay well under this — Debian's
        // SHA256SUMS for a release is ~10 KiB.
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        if data.count > 8 * 1024 * 1024 { return nil }
        let parsed = parse(data)
        return parsed.isEmpty ? nil : parsed
    }
}

// ===========================================================================
// MARK: - Pane view model
// ===========================================================================

@MainActor
final class HashViewModel: ObservableObject {
    @Published var rows: [HashRow] = []
    @Published var compareText: String = ""
    /// Power-user item #3: one `SUMSVerification` per dropped sums file.
    /// Newest first so freshly-dropped verifications float to the top of
    /// the pane without the user having to scroll.
    @Published var verifications: [SUMSVerification] = []

    // P1 FIX: gate auto-copy behind a persisted pref (default OFF).
    // Previously the single-file-complete path silently clobbered the
    // clipboard; the user now opts in explicitly.
    @AppStorage("file_hash.autoCopySHA256") var autoCopySHA256: Bool = false

    // speed: hashing is part I/O, part CPU (MD5+SHA1+SHA256+SHA512 simultaneously
    // on every chunk is non-trivial AES-NI-free CPU work). Scale concurrency with
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
        // Power-user item #3: any sums-looking file is consumed by the
        // verifier instead of being added to the rows list. We do this BEFORE
        // the symlink resolution / dedupe loop so the SUMS file itself is
        // never hashed (which would be pointless and noisy).
        var remaining: [URL] = []
        for u in urls {
            if SUMSParser.looksLikeSUMSFile(u),
               let parsed = SUMSParser.tryParse(u) {
                ingestSUMSFile(at: u, lines: parsed)
            } else {
                remaining.append(u)
            }
        }
        let postFilterURLs = remaining
        for u in postFilterURLs {
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
            row.start(gate: gate, vm: self)
        }
    }

    func remove(_ row: HashRow) {
        row.cancel()
        // P2: decrement done counter if this row was completed.
        if case .done = row.state { decrementDoneCount() }
        rows.removeAll { $0.id == row.id }
    }

    // ---- SHA256SUMS verify (power-user item #3) -------------------------

    /// Build a `SUMSVerification` from a parsed sums file and kick off a hash
    /// task per entry. Targets are resolved relative to the sums file's
    /// parent directory (the canonical layout for distro releases).
    ///
    /// red-team-sec: filenames coming from the sums file are untrusted text.
    /// We refuse anything containing path separators or `..` components, and
    /// resolve only against the sums file's parent dir — so a hostile
    /// `SHA256SUMS` cannot trick us into hashing `/etc/passwd` and reporting
    /// "match" or "mismatch" (which would leak the existence/contents of
    /// arbitrary files).
    private func ingestSUMSFile(at sumsURL: URL, lines: [SUMSParsedLine]) {
        let parent = sumsURL.deletingLastPathComponent()
        var entries: [SUMSEntry] = []
        for line in lines {
            let target = resolveSUMSTarget(filename: line.filename, under: parent)
            entries.append(SUMSEntry(line: line, targetURL: target))
        }
        let v = SUMSVerification(sumsURL: sumsURL, entries: entries)
        // Newest first — fresh drop floats above older verifications.
        verifications.insert(v, at: 0)
        for entry in entries where entry.targetURL != nil {
            startVerifyTask(entry, in: v)
        }
        // Toast so a drop on a busy pane is acknowledged even when the
        // verification card scrolls below the fold.
        let suffix = entries.count == 1 ? "" : "s"
        SharedStore.stage.flash(
            "Verifying \(entries.count) \(v.summaryAlgorithm.displayName) entry\(suffix) from \(sumsURL.lastPathComponent)",
            kind: .info)
    }

    /// Hash the entry's target file and compare to the expected hex. We
    /// re-use the existing `computeHashes` streaming pipeline for free
    /// (single-pass, gated, cancellation-aware) and pick off the algorithm
    /// the sums file actually asked for.
    private func startVerifyTask(_ entry: SUMSEntry, in v: SUMSVerification) {
        guard let target = entry.targetURL else { return }
        entry.task = Task { [weak self, weak entry, weak v] in
            guard let self else { return }
            let acquired = await self.gate.acquire()
            defer { if acquired { Task { await self.gate.release() } } }
            do {
                let result = try await computeHashes(of: target) { p in
                    Task { @MainActor in entry?.progress = p }
                }
                if Task.isCancelled { return }
                let actual: String
                switch entry?.line.algorithm {
                case .md5:    actual = result.md5
                case .sha1:   actual = result.sha1
                case .sha256: actual = result.sha256
                case .sha512: actual = result.sha512
                case .none:   return
                }
                let expected = entry?.line.expectedHash ?? ""
                await MainActor.run {
                    guard let entry else { return }
                    entry.status = (actual.lowercased() == expected)
                        ? .match
                        : .mismatch(actual: actual)
                    // If this was the last pending entry, flash a summary.
                    if let v, v.pendingCount == 0 {
                        self.flashVerificationSummary(v)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    entry?.status = .error(error.localizedDescription)
                    if let v, v.pendingCount == 0 {
                        self.flashVerificationSummary(v)
                    }
                }
            }
        }
    }

    /// Resolve a sums-file-relative filename to an absolute URL, refusing
    /// anything that could escape the parent dir. Returns nil if the file
    /// doesn't exist at the expected location — the entry then renders as
    /// "missing target" instead of triggering an open / hash.
    private func resolveSUMSTarget(filename: String, under parent: URL) -> URL? {
        // Sanitize: refuse absolute paths and any `..` component. coreutils
        // sums files use plain basenames or repo-relative paths; both are
        // fine as long as they stay inside `parent`.
        if filename.hasPrefix("/") { return nil }
        let comps = filename.split(separator: "/", omittingEmptySubsequences: true)
        if comps.contains(where: { $0 == ".." }) { return nil }
        let url = parent.appendingPathComponent(filename).standardizedFileURL
        // Defence-in-depth: re-check after standardization.
        let parentPath = parent.standardizedFileURL.path + "/"
        let urlPath = url.path
        guard urlPath.hasPrefix(parentPath) || urlPath == parent.standardizedFileURL.path else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func flashVerificationSummary(_ v: SUMSVerification) {
        let total = v.entries.count
        let pass = v.passCount
        if v.failCount == 0 {
            SharedStore.stage.flash("✓ \(pass)/\(total) entries verified — all match",
                                    kind: .info)
        } else {
            SharedStore.stage.flash("\(pass)/\(total) match · \(v.failCount) failed",
                                    kind: .warning)
        }
    }

    /// User removes a verification card; cancel any pending hashes for it.
    func remove(_ v: SUMSVerification) {
        for e in v.entries { e.cancel() }
        verifications.removeAll { $0.id == v.id }
    }

    func clearAll() {
        for r in rows { r.cancel() }
        rows.removeAll()
        // P2: reset the counter when all rows are removed.
        doneRowCount = 0
    }

    /// P2: O(1) done-count. Incremented by HashRow when it transitions to
    /// .done; decremented when a row is removed. This replaces the O(n) scan
    /// that `hasDoneRows` previously forced on every toolbar render pass.
    @Published private(set) var doneRowCount: Int = 0

    /// Called from HashRow.start() completion path via MainActor to increment
    /// the counter. Using a simple increment avoids re-scanning rows[].
    func incrementDoneCount() { doneRowCount += 1 }
    func decrementDoneCount() { if doneRowCount > 0 { doneRowCount -= 1 } }

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
    @State private var lastAutoCopiedSHA256: String = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Power-user item #3: SUMS verifications float to the top.
                ForEach(vm.verifications) { v in
                    SUMSVerificationCard(verification: v, vm: vm)
                }
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
                // P1 FIX: export menu for MD5SUMS / SHA1SUMS / SHA256SUMS /
                // SHA512SUMS variants — replaces the single SHA256SUMS button.
                // P2: use O(1) counter instead of O(n) hasDoneRows scan.
                if vm.doneRowCount > 0 {
                    Menu {
                        ForEach(HashAlgorithmExport.allCases) { alg in
                            Button {
                                HashSaveHelpers.saveSUMS(rows: vm.rows, algorithm: alg, stage: stage)
                            } label: {
                                Label(alg.filename, systemImage: "doc.text")
                            }
                        }
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .help("Export MD5SUMS / SHA1SUMS / SHA256SUMS / SHA512SUMS")
                }

                // P1 FIX: auto-copy pref toggle (default OFF).
                Toggle(isOn: $vm.autoCopySHA256) {
                    Label("Auto-copy SHA256", systemImage: "doc.on.clipboard")
                }
                .help("When ON: automatically copies the SHA256 hash to the clipboard when a single file finishes hashing. Default: OFF.")
                .toggleStyle(.checkbox)

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
        .onReceive(vm.objectWillChange) { _ in
            // P1 FIX: auto-copy SHA256 is now gated behind vm.autoCopySHA256
            // (default OFF) to avoid silently clobbering the clipboard.
            // When enabled and a single file finishes, copy SHA256 and show
            // a toast. When disabled, still show a toast (without copying) so
            // the user knows hashing completed.
            DispatchQueue.main.async {
                guard vm.rows.count == 1,
                      case .done(_, _, let sha256, _) = vm.rows[0].state,
                      sha256 != lastAutoCopiedSHA256 else { return }
                lastAutoCopiedSHA256 = sha256
                if vm.autoCopySHA256 {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(sha256, forType: .string)
                    stage.flash("SHA256 copied")
                } else {
                    stage.flash("Hashing complete")
                }
            }
        }
    }

    // ----- compare field --------------------------------------------------

    private var compareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                    Text("Compare against").headerText()
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
        case .done(let md5, let sha1, let sha256, let sha512):
            VStack(alignment: .leading, spacing: 6) {
                HashLine(label: "MD5",    value: md5,    matched: vm.matches(md5),    sourceURL: row.url, stage: stage)
                HashLine(label: "SHA1",   value: sha1,   matched: vm.matches(sha1),   sourceURL: row.url, stage: stage)
                HashLine(label: "SHA256", value: sha256, matched: vm.matches(sha256), sourceURL: row.url, stage: stage)
                HashLine(label: "SHA512", value: sha512, matched: vm.matches(sha512), sourceURL: row.url, stage: stage)
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
// MARK: - SUMS verification card (power-user item #3)
// ===========================================================================

private struct SUMSVerificationCard: View {
    @ObservedObject var verification: SUMSVerification
    let vm: HashViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                ForEach(verification.entries) { entry in
                    SUMSEntryRow(entry: entry)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verification.sumsURL.lastPathComponent)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([verification.sumsURL])
            } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.plain)
            .help("Reveal the sums file in Finder")
            Button(role: .destructive) {
                vm.remove(verification)
            } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.plain)
            .help("Remove this verification")
        }
    }

    private var subtitle: String {
        let total = verification.entries.count
        let plural = total == 1 ? "" : "s"
        if verification.pendingCount > 0 {
            return "\(verification.summaryAlgorithm.displayName) · \(verification.pendingCount) of \(total) hashing…"
        }
        if verification.failCount == 0 {
            return "\(verification.summaryAlgorithm.displayName) · \(verification.passCount)/\(total) match\(plural)"
        }
        return "\(verification.summaryAlgorithm.displayName) · \(verification.passCount) match · \(verification.failCount) failed"
    }

    /// Aggregate icon — green check if all-pass, red triangle on any
    /// mismatch/missing/error, blue arrows while still computing.
    private var statusSymbol: String {
        if verification.pendingCount > 0 { return "arrow.triangle.2.circlepath" }
        if verification.failCount == 0   { return "checkmark.seal.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if verification.pendingCount > 0 { return .secondary }
        if verification.failCount == 0   { return .green }
        return .orange
    }
}

private struct SUMSEntryRow: View {
    @ObservedObject var entry: SUMSEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.line.filename)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = detailLine {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if case .pending = entry.status, entry.targetURL != nil {
                ProgressView(value: entry.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
            }
            if let target = entry.targetURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .help("Reveal the target file in Finder")
            }
        }
        .padding(.vertical, 2)
        // a11y: collapse the row into one navigable element with a spoken
        // status so VoiceOver users can sweep verifications quickly.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.line.filename), \(a11yStatus)")
    }

    private var icon: String {
        switch entry.status {
        case .pending:   return "clock"
        case .match:     return "checkmark.circle.fill"
        case .mismatch:  return "xmark.octagon.fill"
        case .missing:   return "questionmark.circle.fill"
        case .error:     return "exclamationmark.triangle.fill"
        }
    }
    private var tint: Color {
        switch entry.status {
        case .pending:   return .secondary
        case .match:     return .green
        case .mismatch:  return .red
        case .missing:   return .orange
        case .error:     return .red
        }
    }
    /// Bottom line of the row — shows expected hash on pending, actual on
    /// mismatch (so the user can copy it), or the error string.
    private var detailLine: String? {
        switch entry.status {
        case .pending:
            // Truncate to first 16 hex chars so 64-char SHA-256 lines don't
            // dominate the row vertically; the user can hover to see the
            // full file via Reveal in Finder.
            return "expected " + String(entry.line.expectedHash.prefix(16)) + "…"
        case .match:
            return nil
        case .mismatch(let actual):
            return "actual " + String(actual.prefix(16)) + "… ≠ expected " + String(entry.line.expectedHash.prefix(16)) + "…"
        case .missing:
            return "file not found next to sums file"
        case .error(let s):
            return s
        }
    }
    private var a11yStatus: String {
        switch entry.status {
        case .pending:  return "hashing"
        case .match:    return "verified, hashes match"
        case .mismatch: return "verification failed, hashes do not match"
        case .missing:  return "target file not found"
        case .error(let s): return "error: \(s)"
        }
    }
}

// ===========================================================================
// MARK: - Save helpers (statics so closures don't capture view state)
// ===========================================================================

private enum HashSaveHelpers {
    private static let kSaveDirKey = "file_hash.saveDir.last"

    /// Build the canonical shasum format: one row per completed file,
    /// `<hash>  <basename>` with EXACTLY two spaces between hash and name
    /// (this is the format `shasum -a N -c <file>` expects).
    /// MainActor-isolated because HashRow's `state` is.
    @MainActor
    static func sumsBody(_ rows: [HashRow], algorithm: HashAlgorithmExport) -> String {
        var lines: [String] = []
        for r in rows {
            if case .done(let md5, let sha1, let sha256, let sha512) = r.state {
                let hash: String
                switch algorithm {
                case .md5:    hash = md5
                case .sha1:   hash = sha1
                case .sha256: hash = sha256
                case .sha512: hash = sha512
                }
                lines.append("\(hash)  \(r.url.lastPathComponent)")
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

    /// Write a SUMS-style file via NSSavePanel for the given algorithm.
    @MainActor
    static func saveSUMS(rows: [HashRow], algorithm: HashAlgorithmExport, stage: Stage) {
        let body = sumsBody(rows, algorithm: algorithm)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage.flash("Nothing to save — no completed hashes yet")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = algorithm.filename
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.message = "Save a `\(algorithm.verifyCommand)`-compatible checksum file."
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

/// P1 FIX: export algorithm selector for MD5SUMS / SHA1SUMS / SHA256SUMS /
/// SHA512SUMS variants.
private enum HashAlgorithmExport: String, CaseIterable, Identifiable {
    case md5    = "MD5"
    case sha1   = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
    var id: String { rawValue }
    var filename: String { "\(rawValue)SUMS" }
    var verifyCommand: String {
        switch self {
        case .md5:    return "md5 -c"
        case .sha1:   return "shasum -a 1 -c"
        case .sha256: return "shasum -a 256 -c"
        case .sha512: return "shasum -a 512 -c"
        }
    }
}
