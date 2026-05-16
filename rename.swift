// Trove — Mass File Rename pane.
//   • Drop or pick N files (no folders).
//   • Six pattern modes: find/replace, regex, sequence, date, EXIF date, case.
//   • Live two-column "Original → New" preview with collision highlighting.
//   • Atomic batch apply with reverse-rollback on mid-batch failure.
//   • Undo last batch button — one-click revert.
//   • Step-ups over Power Rename: EXIF date, named-capture regex, send-to-Stage.
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Pattern model
// ===========================================================================

enum RenameMode: String, CaseIterable, Identifiable {
    case findReplace = "Find / replace"
    case regex       = "Regex"
    case sequence    = "Sequence"
    case dateCreated = "Date prefix"
    case exifDate    = "EXIF date"
    case caseChange  = "Case"
    var id: String { rawValue }
}

enum RenameCaseStyle: String, CaseIterable, Identifiable {
    case upper    = "UPPER"
    case lower    = "lower"
    case title    = "Title"
    case sentence = "Sentence"
    var id: String { rawValue }
}

/// All the user-tunable knobs the planner reads. One struct so the
/// preview pipeline takes a single input and we don't drift parameters.
struct RenameSettings {
    var mode: RenameMode = .findReplace

    // find/replace + regex
    var findText: String = ""
    var replaceText: String = ""
    var matchCase: Bool = false

    // sequence
    var sequencePrefix: String = "file-"
    var sequenceStart: Int = 1
    var sequencePadding: Int = 3

    // date
    var dateFormat: String = "yyyy-MM-dd"
    var dateSeparator: String = "_"

    // case
    var caseStyle: RenameCaseStyle = .lower
}

// ===========================================================================
// MARK: - Row model
// ===========================================================================

/// A single file in the batch. `newName` is recomputed by the planner; rows
/// also carry per-row errors (regex failures, on-disk collisions, etc.) so
/// the UI can flag them inline.
@MainActor
final class RenameRow: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let originalName: String
    @Published var newName: String = ""
    @Published var rowError: String? = nil
    /// Set on a successful per-file rename so the undo stack has the
    /// "where it ended up" half of the (before, after) pair.
    @Published var appliedURL: URL? = nil

    init(url: URL) {
        self.url = url
        self.originalName = url.lastPathComponent
        self.newName = url.lastPathComponent
    }
}

// ===========================================================================
// MARK: - EXIF date reader (red-team #4)
// ===========================================================================

/// Wraps `CGImageSourceCopyPropertiesAtIndex` with full guards. Missing /
/// corrupt EXIF returns nil — caller falls back to file creation date.
enum RenameExifReader {
    static func dateTimeOriginal(_ url: URL) -> Date? {
        // red-team-sec: CGImageSourceCreateWithURL accepts any URL but does
        // not follow path traversal — we're reading, not writing, so even a
        // bad path just returns nil.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        // EXIF dict; some images put DateTimeOriginal at the top level (TIFF),
        // most photos have it under {Exif}.
        let candidates: [String] = {
            var out: [String] = []
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String { out.append(s) }
                if let s = exif[kCGImagePropertyExifDateTimeDigitized] as? String { out.append(s) }
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                if let s = tiff[kCGImagePropertyTIFFDateTime] as? String { out.append(s) }
            }
            return out
        }()
        // EXIF spec: "yyyy:MM:dd HH:mm:ss". Use a fixed-locale parser so the
        // user's region/locale can't break it.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for s in candidates {
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func creationDate(_ url: URL) -> Date? {
        // red-team: resourceValues is the macOS-idiomatic accessor; falls
        // back to FileManager attributes if the volume doesn't carry them.
        if let vals = try? url.resourceValues(forKeys: [.creationDateKey]),
           let d = vals.creationDate { return d }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let d = attrs[.creationDate] as? Date { return d }
        return nil
    }
}

// ===========================================================================
// MARK: - Filename sanitizer (red-team-sec #6)
// ===========================================================================

/// Strip path-traversal characters and other filename-illegal bytes from a
/// caller-controlled replacement string. We do this AT THE NAME LEVEL — the
/// final new name never gets to contain `/`, `\`, NUL.
///
/// red-team-sec #6: without this, a user pasting `../../etc/passwd` into the
/// replacement field of find/replace would let `moveItem` walk the file
/// out of its parent directory. macOS resolves `/` in `lastPathComponent`
/// → directory traversal. Filter before the planner returns a name.
///
/// We also strip Unicode visual look-alikes for `/` that some renderers (and
/// some filesystems on imported volumes) treat as separators:
///   • U+FF0F FULLWIDTH SOLIDUS  ／
///   • U+2044 FRACTION SLASH     ⁄
///   • U+2215 DIVISION SLASH     ∕
///   • U+29F8 BIG SOLIDUS        ⧸
/// APFS/HFS+ on macOS don't treat these as separators, but a future filename
/// crossing volume boundaries (SMB, exFAT, network shares mapped from
/// non-Apple servers) could. Defense-in-depth: scrub them at the name level
/// so we never depend on the receiving FS's normalization rules.
///
/// Same for the NFKD-mapping equivalents — after sanitizing we also NFC-
/// normalize so visually-identical inputs collapse to a canonical form before
/// the collision check runs.
enum RenameSanitize {
    /// Characters never permitted in an output basename. The ASCII `/` is the
    /// primary one; back-slash and NUL are belt-and-braces; the rest are
    /// Unicode look-alikes that some non-Apple filesystems honor as
    /// separators (red-team-sec #6).
    static let stripped: Set<Character> = [
        "/", "\\", "\0",
        "\u{FF0F}", // ／ fullwidth solidus
        "\u{2044}", // ⁄ fraction slash
        "\u{2215}", // ∕ division slash
        "\u{29F8}", // ⧸ big solidus
        ":",        // colon — HFS+ path separator at the API layer
    ]

    /// Per HFS+/APFS, the maximum component length is 255 UTF-8 bytes
    /// (the on-disk format is UTF-16 but the POSIX layer enforces a byte
    /// budget for compatibility). Past this and `moveItem` throws ENAMETOOLONG.
    static let maxComponentBytes = 255

    static func clean(_ s: String) -> String {
        // Decompose to NFC first so look-alikes that exist only as combining
        // sequences collapse before we filter.
        let normalized = s.precomposedStringWithCanonicalMapping
        var out = String()
        out.reserveCapacity(normalized.count)
        for c in normalized where !stripped.contains(c) {
            // Also drop any C0/C1 control bytes — they're legal in some FSes
            // but break shell tools, Finder display, and our own globals.
            if let scalar = c.unicodeScalars.first, scalar.value < 0x20 { continue }
            out.append(c)
        }
        // Also reject the special directory components, just in case the
        // user pasted them as a literal name.
        if out == "." || out == ".." { return "" }
        return capLength(out)
    }

    /// Truncate a basename so its UTF-8 byte count fits the FS limit.
    /// red-team #5: cap output basename at 255 bytes to prevent
    /// `moveItem` from throwing ENAMETOOLONG mid-batch.
    static func capLength(_ s: String) -> String {
        if s.utf8.count <= maxComponentBytes { return s }
        var bytes = 0
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(after: idx)
            let chunk = s[idx..<next].utf8.count
            if bytes + chunk > maxComponentBytes { break }
            bytes += chunk
            idx = next
        }
        return String(s[..<idx])
    }

    /// As above but cap is applied at the *whole filename* level (stem+ext).
    /// Reserve room for the dotted extension so we don't lop off the ext.
    static func capFullName(stem: String, dottedExt: String) -> String {
        let extBytes = dottedExt.utf8.count
        if extBytes >= maxComponentBytes { return capLength(dottedExt) } // pathological
        let stemBudget = maxComponentBytes - extBytes
        var bytes = 0
        var idx = stem.startIndex
        while idx < stem.endIndex {
            let next = stem.index(after: idx)
            let chunk = stem[idx..<next].utf8.count
            if bytes + chunk > stemBudget { break }
            bytes += chunk
            idx = next
        }
        return String(stem[..<idx]) + dottedExt
    }
}

// ===========================================================================
// MARK: - Planner — turns settings + row index → new name
// ===========================================================================

enum RenamePlanError: LocalizedError {
    case regexInvalid(String)
    case sequenceOverflow
    var errorDescription: String? {
        switch self {
        case .regexInvalid(let m): return "Regex: \(m)"
        case .sequenceOverflow:    return "Sequence > 9999 (cap)"
        }
    }
}

/// Pure function: given settings and the file index in the batch, what's
/// the new filename? Returns the planned name OR a per-row error string.
/// Never throws to the caller; surfaces errors via `RenameRow.rowError`.
enum RenamePlanner {
    static func planName(for url: URL,
                         index: Int,
                         settings: RenameSettings) -> (name: String, error: String?) {
        let original = url.lastPathComponent
        let stem     = (original as NSString).deletingPathExtension
        let ext      = (original as NSString).pathExtension
        let dottedExt = ext.isEmpty ? "" : ".\(ext)"

        switch settings.mode {

        case .findReplace:
            if settings.findText.isEmpty {
                return (original, nil)
            }
            let opts: String.CompareOptions = settings.matchCase ? [] : [.caseInsensitive]
            let newStem = stem.replacingOccurrences(of: settings.findText,
                                                   with: settings.replaceText,
                                                   options: opts)
            let cleanedStem = RenameSanitize.clean(newStem)
            return (RenameSanitize.capFullName(stem: cleanedStem, dottedExt: dottedExt), nil)

        case .regex:
            if settings.findText.isEmpty { return (original, nil) }
            // red-team #4 (regex compile failure): surfaces inline as a row
            // error; the planner never throws to the caller.
            var options: NSRegularExpression.Options = []
            if !settings.matchCase { options.insert(.caseInsensitive) }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: settings.findText, options: options)
            } catch {
                return (original, RenamePlanError.regexInvalid(error.localizedDescription).errorDescription)
            }
            let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
            // NSRegularExpression supports $1...$9 backrefs in the template.
            // Named captures live in the pattern; the template still uses $N.
            //
            // red-team #4 (backref to non-matching group): per Apple docs +
            // ICU semantics, `stringByReplacingMatches(withTemplate:)` expands
            // a backref to a group that didn't participate in this match as
            // the empty string — NOT the literal "$1". Verified against
            // <NSRegularExpression.h>: "Group names not corresponding to a
            // capture group in the template are replaced with the empty
            // string." That means `(?:foo)|(bar)` against "foo" with template
            // "[$1]" yields "[]", not "[$1]". This is the documented behavior;
            // we don't need to special-case it.
            let newStem = regex.stringByReplacingMatches(in: stem,
                                                         options: [],
                                                         range: range,
                                                         withTemplate: settings.replaceText)
            let cleanedStem = RenameSanitize.clean(newStem)
            return (RenameSanitize.capFullName(stem: cleanedStem, dottedExt: dottedExt), nil)

        case .sequence:
            // red-team #5 (sequence cap): cap at 9999. We allow start = 1...9999;
            // with `padding` 3 the formatted string can grow past 4 digits but
            // we still cap the numeric value to avoid surprise.
            let n = settings.sequenceStart + index
            if n > 9999 {
                return (original, RenamePlanError.sequenceOverflow.errorDescription)
            }
            let pad = max(1, min(8, settings.sequencePadding))
            let num = String(format: "%0\(pad)d", n)
            let cleanedPrefix = RenameSanitize.clean(settings.sequencePrefix)
            return (RenameSanitize.capFullName(stem: "\(cleanedPrefix)\(num)", dottedExt: dottedExt), nil)

        case .dateCreated:
            guard let d = RenameExifReader.creationDate(url) else {
                return (original, "no creation date on disk")
            }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = settings.dateFormat
            let prefix = df.string(from: d)
            let sep = RenameSanitize.clean(settings.dateSeparator)
            let cleanedStem = RenameSanitize.clean(prefix) + sep + (original as NSString).deletingPathExtension
            return (RenameSanitize.capFullName(stem: cleanedStem, dottedExt: dottedExt), nil)

        case .exifDate:
            // red-team #3 (EXIF fallback): EXIF missing/corrupt → fall back
            // to file creation date. For non-image files (.pdf, .txt, …)
            // `CGImageSourceCreateWithURL` returns nil immediately, so the
            // fallback path always runs. The user-visible row error reads
            // "no EXIF / creation date" only when *both* sources are
            // unavailable — clear enough for the per-row UI.
            let date = RenameExifReader.dateTimeOriginal(url)
                       ?? RenameExifReader.creationDate(url)
            guard let d = date else {
                return (original, "no EXIF / creation date")
            }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = settings.dateFormat
            let prefix = df.string(from: d)
            let sep = RenameSanitize.clean(settings.dateSeparator)
            let cleanedStem = RenameSanitize.clean(prefix) + sep + (original as NSString).deletingPathExtension
            return (RenameSanitize.capFullName(stem: cleanedStem, dottedExt: dottedExt), nil)

        case .caseChange:
            let newStem: String
            switch settings.caseStyle {
            case .upper:
                newStem = stem.uppercased()
            case .lower:
                newStem = stem.lowercased()
            case .title:
                newStem = stem.capitalized   // word-by-word capitalization
            case .sentence:
                // First letter upper, rest lower.
                let lower = stem.lowercased()
                if let first = lower.first {
                    newStem = String(first).uppercased() + lower.dropFirst()
                } else {
                    newStem = lower
                }
            }
            return (RenameSanitize.capFullName(stem: newStem, dottedExt: dottedExt), nil)
        }
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

/// An (originalURL, renamedURL) pair captured at apply time so "Undo last
/// batch" can walk them in reverse. We snapshot URLs (not just names) so
/// undo works even after the user adds/removes rows post-apply.
struct RenameUndoPair {
    let original: URL
    let applied: URL
}

@MainActor
final class RenameViewModel: ObservableObject {
    @Published var rows: [RenameRow] = []
    @Published var settings = RenameSettings() {
        // speed: settings keystrokes (regex pattern, find/replace text, date
        // format) used to fire a synchronous full-batch replan on every char.
        // For a 500-file batch with a regex that's tens of NSRegularExpression
        // compiles per second on the main thread — SwiftUI dropped frames and
        // typing felt sticky. Debounce 250 ms and run the planner off-main on
        // a serial queue with latest-input-wins; the UI publishes back via
        // MainActor.run when the freshest run finishes.
        didSet { schedulePreviewRecompute() }
    }
    @Published var globalError: String? = nil
    /// Red-team #9: gate while a batch is in flight so the user can't queue
    /// a second batch on stale planned names.
    @Published var isApplying: Bool = false
    /// Undo bookkeeping for the most recent successful apply.
    @Published private(set) var lastUndo: [RenameUndoPair] = []

    // ----- preview debounce plumbing -------------------------------------
    // speed: serial queue means a slow regex compile on input N can't overlap
    // with input N+1's compile — but more importantly, `previewGeneration`
    // makes the older job's results dead-on-arrival, so stale results never
    // overwrite fresh ones (latest-input-wins).
    private let previewQueue = DispatchQueue(label: "trove.rename.preview", qos: .userInitiated)
    private var previewWorkItem: DispatchWorkItem? = nil
    private var previewGeneration: UInt64 = 0

    // ----- list mutation --------------------------------------------------

    func addURLs(_ urls: [URL]) {
        guard !isApplying else { return }
        // red-team: rather than reject dropped folders outright, expand them to
        // their regular-file children so a "rename everything in this folder"
        // drop just works. Cap at 1000 to keep a stray `~/` drop bounded.
        let urls = troveExpandFolders(urls, allowedExtensions: nil, cap: 1000)
        let fm = FileManager.default
        for u in urls {
            // red-team: drag may still deliver folders if expansion was a no-op
            // (e.g. a symlinked folder); keep the explicit guard as a backstop.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { continue }
            // red-team-sec: reject non-regular files (sockets, FIFOs, devices)
            // and symlinks whose target isn't a regular file. moveItem will
            // happily rename a symlink (changing the link's name, not the
            // target's), which is rarely what the user expects from this
            // pane. Treat the symlink itself as the row only if it's the
            // intended item — most file managers deliver the resolved URL.
            if let attrs = try? fm.attributesOfItem(atPath: u.path),
               let ft = attrs[.type] as? FileAttributeType,
               ft != .typeRegular && ft != .typeSymbolicLink {
                continue
            }
            // Dedupe by path.
            if rows.contains(where: { $0.url.path == u.path }) { continue }
            rows.append(RenameRow(url: u))
        }
        recomputePreview()
    }

    func remove(_ row: RenameRow) {
        guard !isApplying else { return }
        rows.removeAll { $0.id == row.id }
        recomputePreview()
    }

    func clearAll() {
        guard !isApplying else { return }
        // speed: invalidate any in-flight debounced preview so its main-thread
        // write-back becomes a no-op against the freshly-empty row list.
        previewWorkItem?.cancel()
        previewWorkItem = nil
        previewGeneration &+= 1
        rows.removeAll()
        lastUndo = []
        globalError = nil
    }

    // ----- preview pipeline ----------------------------------------------

    /// Recompute every row's `newName` from the current settings — SYNCHRONOUS
    /// path used by list mutations (addURLs / remove / undo / apply) where the
    /// user just changed the row set and expects the preview to update before
    /// the next frame. Settings-keystroke updates funnel through the debounced
    /// async path instead.
    func recomputePreview() {
        // speed: cancel any in-flight debounced job — its result would clobber
        // ours by ID and racing the sync update we're about to do.
        previewWorkItem?.cancel()
        previewWorkItem = nil
        previewGeneration &+= 1
        globalError = nil
        for (idx, row) in rows.enumerated() {
            let (name, err) = RenamePlanner.planName(for: row.url,
                                                     index: idx,
                                                     settings: settings)
            row.newName = name
            row.rowError = err
        }
        annotateCollisions()
    }

    /// speed: debounced + off-main preview recompute for the settings-keystroke
    /// path. Snapshot inputs on main, plan + collide-detect on the serial
    /// queue, publish back on main only if the generation tag still matches
    /// (latest-input-wins). 250 ms idle window — long enough that a fast typist
    /// finishing a 6-char regex doesn't trigger 6 replans, short enough that
    /// the preview still feels live.
    func schedulePreviewRecompute() {
        previewWorkItem?.cancel()
        previewGeneration &+= 1
        let gen = previewGeneration
        let settingsSnapshot = settings
        // Snapshot (rowID, URL) on main. Row URLs are immutable for the
        // lifetime of a row so we can safely use them off-main; we apply
        // results by ID, tolerating rows that were removed in the interim.
        let snap: [(id: UUID, url: URL)] = rows.map { ($0.id, $0.url) }
        let dirsToProbe: [URL] = Array(Set(rows.map { $0.url.deletingLastPathComponent() }))

        let work = DispatchWorkItem { [weak self] in
            // Stage 1: pure planner per row (no FS hits other than EXIF/creation
            // date for date modes — those already gracefully degrade).
            var planned: [(id: UUID, name: String, error: String?)] = []
            planned.reserveCapacity(snap.count)
            for (idx, item) in snap.enumerated() {
                let (name, err) = RenamePlanner.planName(for: item.url,
                                                         index: idx,
                                                         settings: settingsSnapshot)
                planned.append((item.id, name, err))
            }
            // Stage 2: collision pass (counts duplicates inside the batch and
            // optionally fileExists() on disk). fileExists is an I/O call —
            // doing this off-main is the whole point.
            var counts: [String: Int] = [:]
            var destPaths: [(id: UUID, url: URL, dest: URL, currentName: String, currentError: String?)] = []
            for (idx, item) in snap.enumerated() {
                let dir = item.url.deletingLastPathComponent()
                let dest = dir.appendingPathComponent(planned[idx].name)
                destPaths.append((item.id, item.url, dest, planned[idx].name, planned[idx].error))
                counts[dest.path, default: 0] += 1
            }
            _ = dirsToProbe // reserved for a future dir-listing cache; left as a hook

            let fm = FileManager.default
            for i in destPaths.indices {
                let entry = destPaths[i]
                // Don't overwrite a planner error.
                if entry.currentError != nil { continue }
                if entry.currentName.isEmpty {
                    destPaths[i].currentError = "empty name"
                    continue
                }
                if entry.dest.path == entry.url.path { continue }
                if (counts[entry.dest.path] ?? 0) > 1 {
                    destPaths[i].currentError = "duplicate planned name"
                    continue
                }
                if fm.fileExists(atPath: entry.dest.path) {
                    let sameInode: Bool = {
                        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
                        guard
                            let a = try? entry.url.resourceValues(forKeys: keys).fileResourceIdentifier,
                            let b = try? entry.dest.resourceValues(forKeys: keys).fileResourceIdentifier
                        else { return false }
                        return (a as AnyObject).isEqual(b as AnyObject)
                    }()
                    if sameInode { continue }
                    destPaths[i].currentError = "destination exists"
                    continue
                }
                // Hidden-file + reserved-DOS-name checks need originalName,
                // which we didn't snapshot — they're cheap so we leave the
                // final pass on main where we have the full row to read.
            }
            // Hop back to main and apply ONLY if we're still the freshest job.
            DispatchQueue.main.async {
                guard let self else { return }
                guard gen == self.previewGeneration else { return }
                // Build lookup so we can apply by ID even if rows reordered or
                // partially churned during the debounce window.
                var byID: [UUID: (name: String, error: String?)] = [:]
                for entry in destPaths {
                    byID[entry.id] = (entry.currentName, entry.currentError)
                }
                self.globalError = nil
                for row in self.rows {
                    guard let result = byID[row.id] else { continue }
                    row.newName = result.name
                    row.rowError = result.error
                }
                // Final pass: hidden-file + reserved-DOS warnings need the
                // RenameRow's originalName which only the main actor owns;
                // do them here.
                self.applyHiddenAndReservedWarnings()
            }
        }
        previewWorkItem = work
        // 250 ms idle window per spec.
        previewQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    /// Hidden-file (period-prefix) + reserved-DOS-name warnings. Split out from
    /// `annotateCollisions` because the debounced off-main path handles the
    /// FS-touching parts (fileExists, counts) but defers the row-state-touching
    /// warning pass back to the main actor.
    private func applyHiddenAndReservedWarnings() {
        for row in rows {
            if row.rowError != nil { continue }
            if !row.originalName.hasPrefix("."), row.newName.hasPrefix(".") {
                row.rowError = "warning: starts with '.', will be hidden in Finder"
                continue
            }
            let stem = (row.newName as NSString).deletingPathExtension.uppercased()
            if Self.reservedDOSNames.contains(stem) {
                row.rowError = "warning: '\(stem)' is reserved on Windows / OneDrive"
                continue
            }
        }
    }

    /// Reserved Windows / DOS basenames. macOS doesn't care, but flagging them
    /// helps users who sync renamed files to OneDrive / Dropbox / SMB shares.
    /// Compared case-insensitively against the stem (extension stripped).
    private static let reservedDOSNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
        "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9",
    ]

    /// Red-team #1 + #2: flag rows whose planned newName collides with another
    /// row in the batch, or with a file already on disk in the same dir.
    ///
    /// red-team #2 (case-only rename on case-insensitive APFS): renaming
    /// `foo.txt` → `Foo.txt` on the default APFS volume is a NO-OP at the FS
    /// level — both names refer to the same inode. `FileManager.fileExists`
    /// returns true for both spellings. We detect that case here so the
    /// apply path can take the temp-name dance (foo.txt → foo.tmp.XXX.txt
    /// → Foo.txt) instead of throwing "exists".
    ///
    /// red-team #6 (hidden file via period-prefix): warn (non-blocking) when
    /// a rename would produce a name starting with `.` — that file will be
    /// hidden in Finder and most shell tools. The user may want this, so we
    /// only warn unless the original was visible (i.e. user accidentally
    /// converted a visible file into a hidden one).
    ///
    /// red-team #7 (reserved DOS names): warn (non-blocking) when the stem
    /// matches a reserved Windows basename. macOS will happily create them,
    /// but Windows / SMB / OneDrive sync will not.
    private func annotateCollisions() {
        var counts: [String: Int] = [:]
        // group by destination-path (dir + newName); collisions are equal paths.
        var destPaths: [(row: RenameRow, dest: URL)] = []
        for row in rows {
            let dest = row.url.deletingLastPathComponent().appendingPathComponent(row.newName)
            destPaths.append((row, dest))
            counts[dest.path, default: 0] += 1
        }
        let fm = FileManager.default
        for (row, dest) in destPaths {
            // Don't overwrite an existing rowError from the planner.
            if row.rowError != nil { continue }
            if row.newName.isEmpty {
                row.rowError = "empty name"
                continue
            }
            // Same-path no-op is fine (means "no change for this row").
            if dest.path == row.url.path { continue }
            // red-team #1: collision within the planned batch.
            if (counts[dest.path] ?? 0) > 1 {
                row.rowError = "duplicate planned name"
                continue
            }
            // red-team #2 (case-only rename): if the only difference is letter
            // case AND the volume is case-insensitive, both paths resolve to
            // the same inode. That's not a real collision — apply() will do
            // the temp-name dance. Detect via `URLResourceKey.fileResourceIdentifierKey`:
            // identical identifiers ⇒ same on-disk file.
            if fm.fileExists(atPath: dest.path) {
                let sameInode: Bool = {
                    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
                    guard
                        let a = try? row.url.resourceValues(forKeys: keys).fileResourceIdentifier,
                        let b = try? dest.resourceValues(forKeys: keys).fileResourceIdentifier
                    else { return false }
                    // fileResourceIdentifier is opaque NSObject; compare by isEqual.
                    return (a as AnyObject).isEqual(b as AnyObject)
                }()
                if sameInode {
                    // Same-inode case-only rename → not an error; apply()
                    // will handle via the temp-name dance.
                    continue
                }
                // If `dest.path` is the current path of some OTHER row in the
                // batch, this is still a hard conflict for non-temp moveItem;
                // flag it.
                row.rowError = "destination exists"
                continue
            }
            // red-team #6: hidden-file warning. Only flag when the original
            // was visible (`!hasPrefix "."`) and the new name starts with `.`
            // — that's the surprising path. Period-prefix on something that
            // was already hidden is fine.
            if !row.originalName.hasPrefix("."), row.newName.hasPrefix(".") {
                row.rowError = "warning: starts with '.', will be hidden in Finder"
                continue
            }
            // red-team #7: reserved DOS names — warn so cross-platform users
            // know the rename will break on Windows / OneDrive / SMB.
            let stem = (row.newName as NSString).deletingPathExtension.uppercased()
            if Self.reservedDOSNames.contains(stem) {
                row.rowError = "warning: '\(stem)' is reserved on Windows / OneDrive"
                continue
            }
        }
    }

    // ----- apply ---------------------------------------------------------

    /// Apply every planned rename, atomic-ish: on any throw mid-batch, undo
    /// the already-applied renames in reverse and surface a summary. Red-team #3.
    func apply() {
        guard !isApplying else { return }
        guard !rows.isEmpty else { return }
        // red-team: a debounced preview job may still be sitting on the queue
        // with the LATEST settings. If we don't flush it, apply() would run
        // against the pre-debounce planned names. Cancel the pending job and
        // recompute synchronously so what the user sees is what we apply.
        if previewWorkItem != nil {
            recomputePreview()
        }

        // Refuse if ANY row has a hard row-level error — the user must clear
        // them first. This is the "atomic batch" contract.
        // red-team: rows whose error string starts with "warning:" are
        // soft warnings (hidden-file prefix, reserved DOS name) — the user
        // can still apply; we just made the row text red as a heads-up.
        let blocking = rows.filter { row in
            guard let e = row.rowError, !e.lowercased().hasPrefix("warning:") else { return false }
            return row.newName != row.originalName
        }
        if !blocking.isEmpty {
            globalError = "Refusing to apply — \(blocking.count) row(s) have errors. Fix or remove them first."
            return
        }
        // Refuse for in-batch duplicates even if rowError missed them (defense
        // in depth).
        let plannedNames = rows.map {
            $0.url.deletingLastPathComponent().appendingPathComponent($0.newName).path
        }
        if Set(plannedNames).count != plannedNames.count {
            globalError = "Refusing to apply — duplicate planned names in batch."
            return
        }

        isApplying = true
        globalError = nil
        var doneSoFar: [(row: RenameRow, from: URL, to: URL)] = []
        var perFileErrors: [String] = []

        for row in rows {
            // No-op rows: just record the identity pair so undo still works
            // symmetrically. (Identity move would no-op anyway — skip it.)
            if row.newName == row.originalName {
                row.appliedURL = row.url
                continue
            }
            let from = row.url
            let to = from.deletingLastPathComponent().appendingPathComponent(row.newName)
            do {
                try moveItemSafely(from: from, to: to)
                doneSoFar.append((row, from, to))
                row.appliedURL = to
            } catch {
                // red-team #1 (mid-batch failure): rollback in reverse, then
                // surface BOTH the trigger error and any rollback failures.
                let failedAt = row.originalName
                perFileErrors.append("\(failedAt): \(error.localizedDescription)")
                let rollbackFailures = rollback(doneSoFar)
                for r in rows { r.appliedURL = nil }
                isApplying = false
                var msg = "Apply failed at \"\(failedAt)\"; rolled back \(doneSoFar.count - rollbackFailures.count) of \(doneSoFar.count) prior renames. \(error.localizedDescription)"
                if !rollbackFailures.isEmpty {
                    msg += " · ROLLBACK INCOMPLETE: \(rollbackFailures.joined(separator: ", "))"
                }
                globalError = msg
                return
            }
        }

        // Success: build the undo stack and reset per-row state. Replace each
        // row's url with the new path so further edits target the new name.
        var undo: [RenameUndoPair] = []
        for row in rows {
            guard let applied = row.appliedURL else { continue }
            if applied.path != row.url.path {
                undo.append(RenameUndoPair(original: row.url, applied: applied))
            }
        }
        // Rebuild rows pointing at their new on-disk paths so re-running the
        // pipeline against the (now-renamed) list is well-defined.
        let oldSettings = settings
        let newRows: [RenameRow] = rows.map { r in
            let target = r.appliedURL ?? r.url
            return RenameRow(url: target)
        }
        rows = newRows
        lastUndo = undo
        isApplying = false
        // Re-run the preview against the new file list with the same settings,
        // so the user sees a clean state.
        settings = oldSettings
        if !perFileErrors.isEmpty {
            globalError = "Partial: " + perFileErrors.joined(separator: " · ")
        }
    }

    /// Returns the list of basenames that *failed* to roll back, so the caller
    /// can surface them. We keep walking after a failure so we unwind as far
    /// as we can (one stuck file shouldn't strand the rest).
    ///
    /// red-team #1 (rollback reliability): the rollback step uses the same
    /// case-insensitive-safe move helper as the forward path, so a case-only
    /// rename can be undone cleanly. If the FS permissions flipped mid-batch
    /// (rare but possible — e.g. the user revoked Full Disk Access while
    /// apply was running), we record the failure path-by-path instead of
    /// silently swallowing.
    @discardableResult
    private func rollback(_ done: [(row: RenameRow, from: URL, to: URL)]) -> [String] {
        var failures: [String] = []
        for entry in done.reversed() {
            do {
                try moveItemSafely(from: entry.to, to: entry.from)
            } catch {
                failures.append("\(entry.to.lastPathComponent)→\(entry.from.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        return failures
    }

    /// Move `from` → `to`, handling the case-insensitive-FS rename quirk.
    ///
    /// red-team #2: on default APFS (case-insensitive) the user renaming
    /// `foo.txt` → `Foo.txt` means `to.path != from.path` lexically but both
    /// resolve to the same inode. Plain `moveItem` may either:
    ///   (a) succeed without actually changing the on-disk case (silent
    ///       failure — Finder still shows `foo.txt`), or
    ///   (b) throw NSFileWriteFileExistsError (the most common observed
    ///       behavior on macOS 14+).
    /// We detect same-inode + different-spelling and do a temp-name dance:
    ///   foo.txt → foo.tmp.<uuid>.txt → Foo.txt
    /// which forces APFS to write the new spelling to disk.
    private func moveItemSafely(from: URL, to: URL) throws {
        let fm = FileManager.default
        let sameInode: Bool = {
            // If the destination doesn't exist we don't need to check.
            guard fm.fileExists(atPath: to.path) else { return false }
            let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
            guard
                let a = try? from.resourceValues(forKeys: keys).fileResourceIdentifier,
                let b = try? to.resourceValues(forKeys: keys).fileResourceIdentifier
            else { return false }
            return (a as AnyObject).isEqual(b as AnyObject)
        }()
        if sameInode && from.path != to.path {
            // Case-only rename on case-insensitive volume. Temp-name dance.
            let dir = from.deletingLastPathComponent()
            let stem = (to.lastPathComponent as NSString).deletingPathExtension
            let ext  = (to.lastPathComponent as NSString).pathExtension
            let dotted = ext.isEmpty ? "" : ".\(ext)"
            let tempName = "\(stem).tmp.\(UUID().uuidString.prefix(8))\(dotted)"
            let temp = dir.appendingPathComponent(tempName)
            try fm.moveItem(at: from, to: temp)
            do {
                try fm.moveItem(at: temp, to: to)
            } catch {
                // Try to put it back before propagating, so we don't leave a
                // ".tmp." orphan on disk.
                try? fm.moveItem(at: temp, to: from)
                throw error
            }
            return
        }
        // moveItem is cross-filesystem safe; we use it even though we expect
        // same-dir moves so a future "move to different folder" feature gets
        // the right semantics free.
        try fm.moveItem(at: from, to: to)
    }

    // ----- undo last batch ----------------------------------------------

    func undoLastBatch() {
        guard !isApplying else { return }
        guard !lastUndo.isEmpty else { return }
        isApplying = true
        var failures: [String] = []
        // Walk in reverse so swaps unwind correctly. Use moveItemSafely so
        // a case-only rename can be undone on case-insensitive APFS — red-team #2.
        for pair in lastUndo.reversed() {
            do {
                try moveItemSafely(from: pair.applied, to: pair.original)
            } catch {
                failures.append("\(pair.applied.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // After undo, rebuild rows to point at the (now restored) originals
        // where possible.
        let restored = lastUndo.map { $0.original }
        // Keep rows that aren't in the undo set + add restored ones.
        let appliedSet = Set(lastUndo.map { $0.applied.path })
        var keep: [RenameRow] = rows.filter { !appliedSet.contains($0.url.path) }
        for u in restored {
            if FileManager.default.fileExists(atPath: u.path) {
                keep.append(RenameRow(url: u))
            }
        }
        rows = keep
        lastUndo = []
        isApplying = false
        globalError = failures.isEmpty
            ? "Undid \(restored.count) rename\(restored.count == 1 ? "" : "s")."
            : "Undo finished with \(failures.count) failure(s): " + failures.joined(separator: " · ")
        recomputePreview()
    }

    // ----- send to stage -------------------------------------------------

    func sendAppliedToStage(_ stage: Stage) {
        // Send the *current* file urls (post-apply they are the new paths).
        for r in rows { stage.addFile(r.url) }
        stage.flash("Sent \(rows.count) renamed file\(rows.count == 1 ? "" : "s") to Stage")
    }
}

// ===========================================================================
// MARK: - Pane view
// ===========================================================================

public struct RenameView: View {
    @StateObject private var vm = RenameViewModel()
    @EnvironmentObject var stage: Stage
    @State private var dropTargeted = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modeCard
                settingsCard
                if vm.rows.isEmpty {
                    dropCard
                } else {
                    previewCard
                    actionsCard
                }
                if let g = vm.globalError {
                    RenameBanner(text: g)
                }
            }
            .padding(24)
        }
        .navigationTitle("Rename")
        .navigationSubtitle("\(vm.rows.count) file\(vm.rows.count == 1 ? "" : "s") · mode: \(vm.settings.mode.rawValue)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    vm.apply()
                } label: {
                    Label("Apply", systemImage: "checkmark.circle.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(vm.rows.isEmpty || vm.isApplying)
                .help("Rename all files atomically; rolls back on any failure")

                Button {
                    vm.undoLastBatch()
                } label: {
                    Label("Undo last batch", systemImage: "arrow.uturn.backward")
                }
                .disabled(vm.lastUndo.isEmpty || vm.isApplying)
                .help("Revert the most recent successful batch")

                Button(role: .destructive) {
                    vm.clearAll()
                } label: {
                    Label("Clear list", systemImage: "trash")
                }
                .disabled(vm.rows.isEmpty || vm.isApplying)
                .help("Remove all rows (does not touch disk)")
            }
        }
    }

    // ----- mode picker ----------------------------------------------------

    private var modeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.abc.dottedunderline")
                        .foregroundStyle(.tint)
                    Text("Rename mode").font(.headline)
                }
                Picker("", selection: $vm.settings.mode) {
                    ForEach(RenameMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(vm.isApplying)
            }
        }
    }

    // ----- per-mode settings ---------------------------------------------

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                    Text(vm.settings.mode.rawValue).font(.headline)
                }
                switch vm.settings.mode {
                case .findReplace: findReplaceControls
                case .regex:       regexControls
                case .sequence:    sequenceControls
                case .dateCreated: dateControls
                case .exifDate:    exifControls
                case .caseChange:  caseControls
                }
            }
            .disabled(vm.isApplying)
        }
    }

    @ViewBuilder private var findReplaceControls: some View {
        TextField("Find", text: $vm.settings.findText)
            .textFieldStyle(.roundedBorder)
        TextField("Replace with", text: $vm.settings.replaceText)
            .textFieldStyle(.roundedBorder)
        Toggle("Match case", isOn: $vm.settings.matchCase)
        Text("Operates on the filename stem; extension is preserved.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var regexControls: some View {
        TextField("Pattern (NSRegularExpression)", text: $vm.settings.findText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        TextField("Replacement (supports $1, $2…)", text: $vm.settings.replaceText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        Toggle("Match case", isOn: $vm.settings.matchCase)
        Text("Named captures (?<name>…) compile fine; reference them as $N in the template.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var sequenceControls: some View {
        TextField("Prefix template", text: $vm.settings.sequencePrefix)
            .textFieldStyle(.roundedBorder)
        HStack(spacing: 12) {
            Stepper(value: $vm.settings.sequenceStart, in: 1...9999) {
                Text("Start: \(vm.settings.sequenceStart)")
            }
            Stepper(value: $vm.settings.sequencePadding, in: 1...8) {
                Text("Padding: \(vm.settings.sequencePadding) digits")
            }
        }
        Text("Caps at 9999 — files past the cap show a row error.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var dateControls: some View {
        TextField("Date format (DateFormatter syntax)", text: $vm.settings.dateFormat)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        TextField("Separator", text: $vm.settings.dateSeparator)
            .textFieldStyle(.roundedBorder)
        Text("Uses each file's `creationDate` from disk.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var exifControls: some View {
        TextField("Date format (DateFormatter syntax)", text: $vm.settings.dateFormat)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        TextField("Separator", text: $vm.settings.dateSeparator)
            .textFieldStyle(.roundedBorder)
        Text("Reads EXIF DateTimeOriginal; falls back to file creation date if absent or corrupt.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var caseControls: some View {
        Picker("Case", selection: $vm.settings.caseStyle) {
            ForEach(RenameCaseStyle.allCases) { c in
                Text(c.rawValue).tag(c)
            }
        }
        .pickerStyle(.segmented)
    }

    // ----- drop zone ------------------------------------------------------

    private var dropCard: some View {
        Card {
            ZStack {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(dropTargeted ? AnyShapeStyle(Color.accentColor)
                                                     : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    Text("No files added yet").font(.headline)
                    Text("Drop files here, or pick them from Finder. Mass rename with find/replace, regex, sequence, date, EXIF, or case — applied atomically and fully undoable.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: 440)
                        .multilineTextAlignment(.center)
                    Button { pickFiles() } label: {
                        Label("Pick from Finder…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)

                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .background(Color.accentColor.opacity(0.06).cornerRadius(10))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // red-team: drop-target fade ignored Reduce Motion.
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil : .easeOut(duration: 0.12),
                       value: dropTargeted)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // ----- preview list ---------------------------------------------------

    private var previewCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                    Text("Preview").font(.headline)
                    Spacer()
                    Button { pickFiles() } label: {
                        Label("Add more…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isApplying)
                }
                Divider()
                ForEach(vm.rows) { row in
                    RenamePreviewRow(row: row, vm: vm)
                    if row.id != vm.rows.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // ----- actions row ----------------------------------------------------

    private var actionsCard: some View {
        Card {
            HStack(spacing: 10) {
                Button {
                    vm.sendAppliedToStage(stage)
                } label: {
                    Label("Send list to Stage", systemImage: "tray.and.arrow.up")
                }
                .help("Add every file in this list (post-rename if applied) to the Stage")
                .disabled(vm.rows.isEmpty || vm.isApplying)

                Spacer()

                if vm.isApplying {
                    ProgressView()
                        .controlSize(.small)
                    Text("Renaming…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ----- handlers -------------------------------------------------------

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false  // red-team: no folders
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
// MARK: - Row + banner subviews
// ===========================================================================

private struct RenamePreviewRow: View {
    @ObservedObject var row: RenameRow
    @ObservedObject var vm: RenameViewModel

    /// red-team: differentiate soft warnings (apply still works) from hard
    /// errors (apply refuses) by inspecting the `warning:` prefix the
    /// planner / collision detector uses.
    private var isWarning: Bool {
        row.rowError?.lowercased().hasPrefix("warning:") == true
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.originalName)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(row.newName.isEmpty ? "—" : row.newName)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(row.rowError == nil
                                 ? Color.primary
                                 : (isWarning ? Color.orange : Color.red))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let e = row.rowError {
                Text(e)
                    .font(.caption2)
                    .foregroundStyle(isWarning ? Color.orange : Color.red)
                    .lineLimit(1)
            }
            Button {
                vm.remove(row)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(vm.isApplying)
            .help("Remove from list")
        }
        .padding(.vertical, 3)
    }
}

private struct RenameBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
