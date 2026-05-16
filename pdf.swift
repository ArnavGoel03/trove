// Trove — PDF Tools pane.
//   • iLovePDF-class operations, 100% local. PDFKit + Vision + ImageIO only.
//   • Batch by default. Atomic writes. Send-to-Stage on every output.
//
// Compiled with `swiftc -parse-as-library` alongside main.swift and siblings.
// Uses SharedStore.stage, the Card { } helper, and Int64.human from main.swift.
//
// Type prefix: PDFOps* (PDFKit owns PDF*).

import SwiftUI
import AppKit
import PDFKit
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// ===========================================================================
// MARK: - Operation catalogue
// ===========================================================================

enum PDFOpKind: String, CaseIterable, Identifiable, Hashable {
    case merge, split, compress, rotate, organize
    case pageNumbers, watermark, crop
    case protect, unlock
    case toJPG, toPNG, imagesToPDF
    case repair, ocr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge:        return "Merge"
        case .split:        return "Split"
        case .compress:     return "Compress"
        case .rotate:       return "Rotate"
        case .organize:     return "Organize pages"
        case .pageNumbers:  return "Page numbers"
        case .watermark:    return "Watermark"
        case .crop:         return "Crop"
        case .protect:      return "Protect"
        case .unlock:       return "Unlock"
        case .toJPG:        return "PDF → JPG"
        case .toPNG:        return "PDF → PNG"
        case .imagesToPDF:  return "JPG / PNG → PDF"
        case .repair:       return "Repair"
        case .ocr:          return "OCR"
        }
    }

    var blurb: String {
        switch self {
        case .merge:        return "Combine several PDFs into one. Drag to reorder."
        case .split:        return "Split into pages or custom ranges like 1-3, 5, 7-9."
        case .compress:     return "Re-encode embedded images to shrink file size."
        case .rotate:       return "Rotate pages 90° CW, 90° CCW, or 180°."
        case .organize:     return "Drag-reorder or delete pages with thumbnails."
        case .pageNumbers:  return "Add page numbers, anywhere on the page."
        case .watermark:    return "Stamp text or an image onto every page."
        case .crop:         return "Trim margins in points, all pages or a range."
        case .protect:      return "Encrypt with a password."
        case .unlock:       return "Strip the password from a PDF you can already open."
        case .toJPG:        return "Render every page to a JPEG image."
        case .toPNG:        return "Render every page to a PNG image."
        case .imagesToPDF:  return "Combine JPEG and PNG images into a single PDF."
        case .repair:       return "Re-save through PDFKit to fix malformed files."
        case .ocr:          return "Make scanned PDFs searchable with Vision."
        }
    }

    var icon: String {
        switch self {
        case .merge:        return "arrow.triangle.merge"
        case .split:        return "scissors"
        case .compress:     return "arrow.down.right.and.arrow.up.left"
        case .rotate:       return "rotate.right"
        case .organize:     return "square.grid.3x3"
        case .pageNumbers:  return "number"
        case .watermark:    return "drop.halffull"
        case .crop:         return "crop"
        case .protect:      return "lock"
        case .unlock:       return "lock.open"
        case .toJPG:        return "photo"
        case .toPNG:        return "photo.fill"
        case .imagesToPDF:  return "photo.stack"
        case .repair:       return "bandage"
        case .ocr:          return "doc.text.viewfinder"
        }
    }

    /// Whether this op consumes images, PDFs, or both.
    var acceptsImages: Bool { self == .imagesToPDF }
    var acceptsPDFs: Bool   { self != .imagesToPDF }

    /// Single-input ops disable multi-file drop in the detail UI but still
    /// process whatever the user gives (we just warn).
    var singleInput: Bool {
        switch self {
        case .split, .organize, .pageNumbers, .watermark, .crop, .toJPG, .toPNG, .ocr:
            return true
        default:
            return false
        }
    }
}

// ===========================================================================
// MARK: - Source file model
// ===========================================================================

struct PDFOpsSource: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var bytes: Int64
    /// Required password if the PDF is encrypted and we couldn't open it with "".
    var password: String = ""
    /// True if the file failed validation (not a PDF, etc).
    var invalid: Bool = false
    /// Reason if invalid or locked.
    var note: String = ""
    /// True between the moment the row appears in the UI and the moment the
    /// background validator has finished parsing the file. Keeps the row
    /// visible (so drops feel instant) while disabling Run until parse is in.
    var validating: Bool = false

    static func == (a: PDFOpsSource, b: PDFOpsSource) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PDFOpsOutput: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let bytes: Int64
    let sourceLabel: String
    let opKind: PDFOpKind
    let createdAt = Date()
    /// Optional human note ("page already searchable — skipped").
    var note: String = ""

    static func == (a: PDFOpsOutput, b: PDFOpsOutput) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PDFOpsFailure: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let message: String
}

// ===========================================================================
// MARK: - Filesystem helpers (atomic write, collision-safe names, output dir)
// ===========================================================================

enum PDFOpsFS {
    /// Returns ~/Downloads/Trove/<op>/, creating it if needed.
    static func outputDir(for op: PDFOpKind) throws -> URL {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let dir = downloads
            .appendingPathComponent("Trove", isDirectory: true)
            .appendingPathComponent(op.title, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Writability probe.
        guard fm.isWritableFile(atPath: dir.path) else {
            throw NSError(domain: "PDFOps", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Output folder is not writable: \(dir.path)"
            ])
        }
        return dir
    }

    /// Resolve a collision-safe URL: foo.pdf → foo (2).pdf → foo (3).pdf …
    /// red-team: hard-cap at 9999. If we still collide, fall back to a UUID
    /// suffix so we never *return a URL that exists* (which would silently
    /// trigger an overwrite path via replaceItemAt).
    static func uniqueURL(in dir: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(baseName).appendingPathExtension(ext)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        var i = 2
        while i <= 9999 {
            candidate = dir
                .appendingPathComponent("\(baseName) (\(i))")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
        // Last resort: UUID. Guaranteed-unique, ugly, but won't clobber.
        let uniq = "\(baseName) (\(UUID().uuidString.prefix(8)))"
        return dir.appendingPathComponent(uniq).appendingPathExtension(ext)
    }

    /// Atomic write of a PDFDocument: write to .tmp, then replace/move into place.
    /// Returns the final URL written to.
    ///
    /// red-team: if `target` happens to be the same file as the document's
    /// originating URL, `replaceItemAt` will swap the inode out from under any
    /// other reader. PDFDocument holds an in-memory snapshot at this point, so
    /// the write itself is safe, but downstream consumers reading `target`
    /// before replace lands could see torn state. We resolve symlinks +
    /// canonicalize and avoid clobbering by adding a UUID suffix in the rare
    /// in-place case.
    @discardableResult
    static func writePDFAtomically(_ doc: PDFDocument, to requestedTarget: URL) throws -> URL {
        let fm = FileManager.default
        var target = requestedTarget
        if let src = doc.documentURL {
            let aPath = (src.resolvingSymlinksInPath().standardizedFileURL).path
            let bPath = (target.resolvingSymlinksInPath().standardizedFileURL).path
            if aPath == bPath {
                let base = target.deletingPathExtension().lastPathComponent
                let ext  = target.pathExtension
                target = target.deletingLastPathComponent()
                    .appendingPathComponent("\(base) (\(UUID().uuidString.prefix(6)))")
                    .appendingPathExtension(ext)
            }
        }
        let parent = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let tmp = parent.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp"
        )
        // Make sure no stale .tmp exists.
        try? fm.removeItem(at: tmp)

        let ok = doc.write(to: tmp)
        if !ok {
            try? fm.removeItem(at: tmp)
            throw NSError(domain: "PDFOps", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "PDFKit failed to write the file."
            ])
        }
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return target
    }

    /// Atomic write for arbitrary Data (used by PDF → image folders).
    static func writeDataAtomically(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let tmp = parent.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp"
        )
        try? fm.removeItem(at: tmp)
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// File size in bytes, 0 on error.
    static func size(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// ===========================================================================
// MARK: - Page-range parser
// ===========================================================================

enum PDFOpsRange {
    /// Parse "1-3, 5, 7-9" → [0,1,2,4,6,7,8] (zero-indexed). `pageCount` is
    /// the 1-based total. Throws if out of range or malformed.
    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(0..<pageCount)
        }
        var out: [Int] = []
        var seen = Set<Int>()
        let parts = trimmed.split(separator: ",")
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if let dash = p.firstIndex(of: "-") {
                let lhs = p[..<dash].trimmingCharacters(in: .whitespaces)
                let rhs = p[p.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                // red-team: "1-" / "-3" → one side parses, other is empty.
                // Both produce nil from Int() so the guard below catches them,
                // but make the message clearer.
                if lhs.isEmpty || rhs.isEmpty {
                    throw err("Range '\(p)' is missing a side; use e.g. '1-3'")
                }
                guard let a = Int(lhs), let b = Int(rhs) else {
                    throw err("Can't parse range '\(p)'")
                }
                // red-team: reversed range "7-3" silently swaps. That's fine
                // for ascending output, but page indexes are already
                // de-duplicated below, so the swap is harmless. Keep the
                // forgiving behavior.
                let lo = min(a, b), hi = max(a, b)
                guard lo >= 1 else { throw err("Pages start at 1, got '\(p)'") }
                guard hi <= pageCount else {
                    throw err("Page \(hi) out of range (document has \(pageCount))")
                }
                for n in lo...hi {
                    let z = n - 1
                    if !seen.contains(z) { seen.insert(z); out.append(z) }
                }
            } else {
                guard let n = Int(p) else { throw err("Can't parse '\(p)'") }
                guard n >= 1 else { throw err("Pages start at 1, got '\(p)'") }
                guard n <= pageCount else {
                    throw err("Page \(n) out of range (document has \(pageCount))")
                }
                let z = n - 1
                if !seen.contains(z) { seen.insert(z); out.append(z) }
            }
        }
        if out.isEmpty { throw err("No pages selected") }
        return out
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "PDFOps.Range", code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// ===========================================================================
// MARK: - PDF loading + validation
// ===========================================================================

enum PDFOpsLoader {
    /// Try to open a PDF. Returns the document if successful; nil + reason
    /// otherwise. Tries the supplied password if encrypted.
    ///
    /// red-team-sec: PDFKit has a history of CVEs in its PDF parser (font
    /// embedding, malformed cross-ref tables, image stream decode). We can't
    /// avoid PDFKit — it's the only system framework for these ops — but we
    /// (a) run everything in-process, (b) never auto-render thumbnails for
    /// untrusted files until the user opens the detail view, and (c)
    /// surround per-page work in autoreleasepool so a malformed page
    /// allocation pattern doesn't snowball. Users are warned by macOS's own
    /// Gatekeeper / Quarantine flags for downloaded PDFs.
    ///
    /// red-team: PDFDocument(url:) returns nil for many causes — corrupt
    /// header, broken xref, unsupported encryption (AES-256-R6 was added
    /// in PDF 2.0 and older OSes refuse it). We can't distinguish those
    /// from "not a PDF at all", so the error string is intentionally
    /// generic. The Repair op (which re-saves through PDFKit) gives the
    /// user a path to recover some of those cases.
    static func load(_ url: URL, password: String = "") -> (doc: PDFDocument?, reason: String) {
        guard let doc = PDFDocument(url: url) else {
            return (nil, "Not a valid PDF (corrupt header, unsupported encryption, or not a PDF)")
        }
        if doc.isEncrypted {
            // Already-unlocked PDFs (some are locked but openable) get caught
            // by isLocked, not isEncrypted. We try unlock("") then the user pw.
            if doc.isLocked {
                // red-team: PDFKit's unlock(withPassword:) tries the password
                // as BOTH the user and owner password internally. We don't
                // need a separate owner-pw field.
                if doc.unlock(withPassword: password) {
                    return (doc, "")
                }
                if password.isEmpty {
                    return (nil, "Encrypted — password required")
                }
                return (nil, "Wrong password")
            }
        }
        return (doc, "")
    }
}

// ===========================================================================
// MARK: - Recent outputs (last 5 per op)
// ===========================================================================

@MainActor
final class PDFOpsRecents: ObservableObject {
    @Published private(set) var byOp: [PDFOpKind: [PDFOpsOutput]] = [:]

    func add(_ out: PDFOpsOutput) {
        var list = byOp[out.opKind] ?? []
        list.insert(out, at: 0)
        if list.count > 5 { list.removeLast(list.count - 5) }
        byOp[out.opKind] = list
    }

    func recents(for op: PDFOpKind) -> [PDFOpsOutput] {
        byOp[op] ?? []
    }
}

// ===========================================================================
// MARK: - Operation model (per-op state lives in PDFOpsModel)
// ===========================================================================

@MainActor
final class PDFOpsModel: ObservableObject {
    // Inputs
    @Published var sources: [PDFOpsSource] = []
    // Outputs from the most recent run.
    @Published var outputs: [PDFOpsOutput] = []
    // Per-source failures from the most recent run.
    @Published var failures: [PDFOpsFailure] = []

    // Progress / cancellation
    @Published var working: Bool = false
    @Published var progressLabel: String = ""
    @Published var progress: Double = 0
    private var runTask: Task<Void, Never>?
    private var cancelled: Bool = false

    // Op-specific parameters (one model for all ops — keeps the View simple).
    // Split
    @Published var splitMode: SplitMode = .everyPage
    @Published var splitRanges: String = "1-3, 5"

    enum SplitMode: String, CaseIterable, Identifiable {
        case everyPage = "Every page = one file"
        case ranges = "Custom ranges"
        var id: String { rawValue }
    }

    // Compress
    @Published var compressQuality: Double = 0.6  // 0.3 – 0.9

    // Rotate
    @Published var rotateDegrees: Int = 90  // 90, -90, 180
    @Published var rotateAllPages: Bool = true
    @Published var rotateRange: String = "1-1"

    // Page numbers
    @Published var pnPosition: PNPosition = .bottomCenter
    @Published var pnFontSize: Double = 12
    @Published var pnFormat: PNFormat = .pageN
    @Published var pnCustomPrefix: String = "Page"

    enum PNPosition: String, CaseIterable, Identifiable {
        case topLeft = "Top Left", topCenter = "Top Center", topRight = "Top Right"
        case bottomLeft = "Bottom Left", bottomCenter = "Bottom Center", bottomRight = "Bottom Right"
        var id: String { rawValue }
    }
    enum PNFormat: String, CaseIterable, Identifiable {
        case pageN = "Page N"
        case nOfTotal = "N / total"
        case justN = "N"
        case custom = "Custom prefix + N"
        var id: String { rawValue }
    }

    // Watermark
    @Published var wmKind: WMKind = .text
    @Published var wmText: String = "CONFIDENTIAL"
    @Published var wmOpacity: Double = 0.18
    @Published var wmFontSize: Double = 60
    @Published var wmRotation: Double = -30
    @Published var wmColor: Color = .red
    @Published var wmImageURL: URL? = nil

    enum WMKind: String, CaseIterable, Identifiable {
        case text = "Text", image = "Image"
        var id: String { rawValue }
    }

    // Crop
    @Published var cropTop: Double = 36
    @Published var cropRight: Double = 36
    @Published var cropBottom: Double = 36
    @Published var cropLeft: Double = 36
    @Published var cropAllPages: Bool = true
    @Published var cropRange: String = "1-1"

    // Protect / Unlock
    @Published var passwordInput: String = ""

    // Render-to-image
    @Published var renderDPI: Int = 144  // 72, 144, 300

    // Images → PDF
    @Published var imgSources: [PDFOpsSource] = []  // image files
    @Published var imgPageSize: ImgPageSize = .a4Fit

    enum ImgPageSize: String, CaseIterable, Identifiable {
        case a4Fit     = "A4 fit"
        case letterFit = "Letter fit"
        case native    = "Image native"
        var id: String { rawValue }
        /// Page rect in points (72 = 1 inch). nil = native (per-image).
        var pointsRect: CGRect? {
            switch self {
            case .a4Fit:     return CGRect(x: 0, y: 0, width: 595.0, height: 842.0)
            case .letterFit: return CGRect(x: 0, y: 0, width: 612.0, height: 792.0)
            case .native:    return nil
            }
        }
    }

    // -----------------------------------------------------------------
    // Source ingestion
    // -----------------------------------------------------------------

    /// Add files for a PDF-input op. Rows appear instantly with the file
    /// name; validation runs in the background, in parallel, with a magic-
    /// bytes short-circuit for non-PDFs so big drops finish fast.
    func addPDFFiles(_ urls: [URL]) {
        // red-team: real-world batch UX expects dropping a folder of PDFs to
        // expand to its children, not get silently rejected by the non-regular
        // guard below. Cap at 1000 to keep a stray `~/` drop bounded.
        let urls = troveExpandFolders(urls, allowedExtensions: ["pdf"], cap: 1000)
        var toValidate: [(id: UUID, url: URL)] = []
        let fm = FileManager.default
        for raw in urls {
            // red-team-sec: resolve symlinks and reject non-regular files
            // before any reader touches them. PDFKit's parser has had
            // memory-safety CVEs; never let it run against /dev/* or a
            // FIFO. One attributesOfItem call gets us both .type and .size
            // — two filesystem hits become one.
            let url = raw.resolvingSymlinksInPath()
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if let ft = attrs[.type] as? FileAttributeType, ft != .typeRegular { continue }
            if sources.contains(where: { $0.url == url }) { continue }
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            var src = PDFOpsSource(url: url, bytes: bytes)
            src.validating = true
            src.note = "Validating…"
            sources.append(src)
            toValidate.append((src.id, url))
        }
        guard !toValidate.isEmpty else { return }
        // Bounded-concurrency TaskGroup: parse up to 4 PDFs at once. PDFKit
        // is CPU+I/O bound; 4 lines up with most users' P-core count and
        // avoids the page-cache thrash that fully-unbounded fan-out causes
        // on a 200-file drop.
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (UUID, Bool, String).self) { group in
                let cap = min(4, toValidate.count)
                var i = 0
                while i < cap {
                    let item = toValidate[i]
                    group.addTask { Self.validatePDF(id: item.id, url: item.url) }
                    i += 1
                }
                while let result = await group.next() {
                    let (id, invalid, note) = result
                    await MainActor.run {
                        guard let self else { return }
                        if let idx = self.sources.firstIndex(where: { $0.id == id }) {
                            self.sources[idx].validating = false
                            self.sources[idx].invalid = invalid
                            self.sources[idx].note = note
                        }
                    }
                    if i < toValidate.count {
                        let item = toValidate[i]
                        group.addTask { Self.validatePDF(id: item.id, url: item.url) }
                        i += 1
                    }
                }
            }
        }
    }

    /// Two-stage validator: cheap magic-bytes signature check (rejects
    /// non-PDFs in microseconds) then CGPDFDocument for the encryption
    /// probe. CGPDFDocument is meaningfully lighter than `PDFDocument`
    /// because it doesn't eagerly walk the page tree.
    nonisolated private static func validatePDF(id: UUID, url: URL) -> (UUID, Bool, String) {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return (id, true, "Could not read file")
        }
        let head = (try? fh.read(upToCount: 1024)) ?? Data()
        try? fh.close()
        // red-team: ISO 32000 says PDFs start with `%PDF-`, but real-world
        // files sometimes carry leading whitespace, a UTF-8 BOM, or even
        // wrapper junk (mail-client ZIP framing, Word export prelude) before
        // the header. Adobe Reader accepts these; PDFKit/CGPDFDocument
        // generally does too. Scan the first 1024 bytes for `%PDF-` as a
        // substring instead of insisting it be at byte 0.
        if head.range(of: Data("%PDF-".utf8)) == nil {
            return (id, true, "Not a valid PDF")
        }
        guard let cg = CGPDFDocument(url as CFURL) else {
            return (id, true, "Not a valid PDF")
        }
        if cg.isEncrypted && !cg.isUnlocked {
            return (id, false, "Encrypted — password required")
        }
        return (id, false, "")
    }

    /// Add image files for the images-to-PDF op. Same pattern: row appears
    /// instantly, ImageIO header read runs in parallel in the background.
    func addImageFiles(_ urls: [URL]) {
        // red-team: expand dropped folders to their image children so a drop
        // of a "Photos to bundle" folder doesn't silently swallow everything.
        let urls = troveExpandFolders(
            urls,
            allowedExtensions: ["png","jpg","jpeg","heic","tiff","tif","gif","bmp","webp"],
            cap: 1000
        )
        var toValidate: [(id: UUID, url: URL)] = []
        let fm = FileManager.default
        for raw in urls {
            // red-team-sec: same symlink + non-regular guard as PDF input.
            let url = raw.resolvingSymlinksInPath()
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if let ft = attrs[.type] as? FileAttributeType, ft != .typeRegular { continue }
            if imgSources.contains(where: { $0.url == url }) { continue }
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            var src = PDFOpsSource(url: url, bytes: bytes)
            src.validating = true
            src.note = "Validating…"
            imgSources.append(src)
            toValidate.append((src.id, url))
        }
        guard !toValidate.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (UUID, Bool).self) { group in
                let cap = min(4, toValidate.count)
                var i = 0
                while i < cap {
                    let item = toValidate[i]
                    group.addTask {
                        (item.id, CGImageSourceCreateWithURL(item.url as CFURL, nil) == nil)
                    }
                    i += 1
                }
                while let (id, invalid) = await group.next() {
                    await MainActor.run {
                        guard let self else { return }
                        if let idx = self.imgSources.firstIndex(where: { $0.id == id }) {
                            self.imgSources[idx].validating = false
                            self.imgSources[idx].invalid = invalid
                            self.imgSources[idx].note = invalid ? "Not a valid image" : ""
                        }
                    }
                    if i < toValidate.count {
                        let item = toValidate[i]
                        group.addTask {
                            (item.id, CGImageSourceCreateWithURL(item.url as CFURL, nil) == nil)
                        }
                        i += 1
                    }
                }
            }
        }
    }

    func removeSource(_ s: PDFOpsSource) {
        sources.removeAll { $0.id == s.id }
    }
    func removeImage(_ s: PDFOpsSource) {
        imgSources.removeAll { $0.id == s.id }
    }
    func moveSources(from a: IndexSet, to b: Int) {
        sources.move(fromOffsets: a, toOffset: b)
    }
    func moveImages(from a: IndexSet, to b: Int) {
        imgSources.move(fromOffsets: a, toOffset: b)
    }

    func clear() {
        sources.removeAll()
        imgSources.removeAll()
        outputs.removeAll()
        failures.removeAll()
    }

    // -----------------------------------------------------------------
    // Cancellation
    // -----------------------------------------------------------------

    func cancel() {
        cancelled = true
        runTask?.cancel()
    }

    // red-team: nonisolated so runners (now also nonisolated) can call this
    // without an actor hop. `Task.isCancelled` already covers cancellation
    // because `runTask?.cancel()` propagates into the child Task. The
    // `cancelled` flag remains as a belt-and-braces flag readable from the
    // main actor (we read it via a quick MainActor hop only at loop tops).
    nonisolated private func checkCancel() async throws {
        if Task.isCancelled { throw CancellationError() }
        let userCancelled = await MainActor.run { self.cancelled }
        if userCancelled { throw CancellationError() }
    }

    /// Synchronous, sync-context cancel probe for use inside autoreleasepool
    /// closures (which are non-async). Only consults Task.isCancelled.
    nonisolated private func checkCancelSync() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    // -----------------------------------------------------------------
    // Run dispatcher
    // -----------------------------------------------------------------

    func run(_ op: PDFOpKind, sendToStage: Bool, recents: PDFOpsRecents) {
        guard !working else { return }
        cancelled = false
        outputs.removeAll()
        failures.removeAll()
        working = true
        progress = 0
        progressLabel = "Preparing…"

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.dispatch(op: op, sendToStage: sendToStage, recents: recents)
            } catch is CancellationError {
                await MainActor.run {
                    self.progressLabel = "Cancelled"
                    let n = self.outputs.count
                    SharedStore.stage.flash(
                        "Cancelled · \(n) output\(n == 1 ? "" : "s") written",
                        kind: .warning
                    )
                }
            } catch {
                await MainActor.run {
                    self.failures.append(PDFOpsFailure(label: "—",
                                                      message: error.localizedDescription))
                }
            }
            await MainActor.run {
                self.working = false
                self.progress = 0
                self.progressLabel = ""
            }
        }
        runTask = Task { await task.value }
    }

    // red-team: dispatch is `nonisolated` so each runner can do its heavy
    // PDFKit / Vision / ImageIO work OFF the main thread. The previous
    // version inherited @MainActor from the class, which trampolined every
    // op back to main — UI freeze + nominally-detached work running on the
    // main thread. Runners explicitly hop to MainActor when reading/writing
    // @Published state via `await MainActor.run`.
    nonisolated private func dispatch(op: PDFOpKind, sendToStage: Bool, recents: PDFOpsRecents) async throws {
        switch op {
        case .merge:        try await runMerge(sendToStage: sendToStage, recents: recents)
        case .split:        try await runSplit(sendToStage: sendToStage, recents: recents)
        case .compress:     try await runCompress(sendToStage: sendToStage, recents: recents)
        case .rotate:       try await runRotate(sendToStage: sendToStage, recents: recents)
        case .organize:     try await runOrganize(sendToStage: sendToStage, recents: recents)
        case .pageNumbers:  try await runPageNumbers(sendToStage: sendToStage, recents: recents)
        case .watermark:    try await runWatermark(sendToStage: sendToStage, recents: recents)
        case .crop:         try await runCrop(sendToStage: sendToStage, recents: recents)
        case .protect:      try await runProtect(sendToStage: sendToStage, recents: recents)
        case .unlock:       try await runUnlock(sendToStage: sendToStage, recents: recents)
        case .toJPG:        try await runRender(format: .jpeg, sendToStage: sendToStage, recents: recents)
        case .toPNG:        try await runRender(format: .png, sendToStage: sendToStage, recents: recents)
        case .imagesToPDF:  try await runImagesToPDF(sendToStage: sendToStage, recents: recents)
        case .repair:       try await runRepair(sendToStage: sendToStage, recents: recents)
        case .ocr:          try await runOCR(sendToStage: sendToStage, recents: recents)
        }
    }

    // -----------------------------------------------------------------
    // Helpers shared by the per-op runners
    // -----------------------------------------------------------------

    @MainActor private func setProgress(_ p: Double, _ label: String) {
        progress = p
        progressLabel = label
    }
    @MainActor private func appendOutput(_ o: PDFOpsOutput, recents: PDFOpsRecents, toStage: Bool) {
        outputs.append(o)
        recents.add(o)
        if toStage { SharedStore.stage.addFile(o.url) }
    }
    @MainActor private func appendFailure(_ f: PDFOpsFailure) { failures.append(f) }

    /// Load a source's PDFDocument (with the user-supplied password if any).
    /// Records a per-source failure and returns nil if it can't be opened.
    ///
    /// red-team: PDFDocument is NOT thread-safe. The caller runs on a detached
    /// worker; we must NOT construct/touch the doc on @MainActor and then hand
    /// it to a different thread. So we hop to MainActor only to read the
    /// password+invalid flag, then construct PDFDocument on the worker thread
    /// where it will actually be used. All mutation/iteration stays on that
    /// same worker thread.
    nonisolated private func loadOrFail(_ s: PDFOpsSource) async -> PDFDocument? {
        // Capture the bits we need from the main actor without dragging the doc
        // across actor boundaries.
        let (invalid, note, pw) = await MainActor.run {
            (s.invalid, s.note, s.password)
        }
        if invalid {
            await MainActor.run {
                self.appendFailure(.init(label: s.url.lastPathComponent, message: note))
            }
            return nil
        }
        let (doc, reason) = PDFOpsLoader.load(s.url, password: pw)
        if let doc { return doc }
        await MainActor.run {
            self.appendFailure(.init(label: s.url.lastPathComponent,
                                     message: reason.isEmpty ? "Couldn't open" : reason))
        }
        return nil
    }

    // -----------------------------------------------------------------
    // Op: Merge
    // -----------------------------------------------------------------
    nonisolated private func runMerge(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snapshot = await MainActor.run { self.sources }
        guard snapshot.count >= 1 else {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "Add at least one PDF.")) }
            return
        }
        let dir = try PDFOpsFS.outputDir(for: .merge)
        let out = PDFDocument()
        var pageIdx = 0
        let totalDocs = snapshot.count
        for (di, src) in snapshot.enumerated() {
            try await checkCancel()
            await setProgress(Double(di) / Double(max(totalDocs, 1)),
                              "Merging \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            // red-team: large multi-GB merges accumulated PDFKit's per-page
            // copy buffers in the surrounding autorelease pool, which only
            // drained when the runner Task suspended. Drain per-page so a
            // 5-doc × 1000-page merge doesn't pin gigabytes mid-run.
            for i in 0..<doc.pageCount {
                try await checkCancel()
                autoreleasepool {
                    if let p = doc.page(at: i)?.copy() as? PDFPage {
                        out.insert(p, at: pageIdx)
                        pageIdx += 1
                    }
                }
            }
        }
        guard out.pageCount > 0 else {
            await MainActor.run {
                self.appendFailure(.init(label: "—", message: "Nothing to merge."))
            }
            return
        }
        let base = snapshot.first.map { $0.url.deletingPathExtension().lastPathComponent }
            ?? "merged"
        // red-team: don't say "+ 0 more" when there's only one input.
        let baseName: String
        if snapshot.count == 1 {
            baseName = "\(base) (merged)"
        } else {
            baseName = "\(base) + \(snapshot.count - 1) more (merged)"
        }
        let target = PDFOpsFS.uniqueURL(in: dir, baseName: baseName, ext: "pdf")
        try PDFOpsFS.writePDFAtomically(out, to: target)
        await MainActor.run {
            self.appendOutput(.init(url: target,
                                    bytes: PDFOpsFS.size(of: target),
                                    sourceLabel: "\(snapshot.count) inputs",
                                    opKind: .merge),
                              recents: recents,
                              toStage: sendToStage)
        }
    }

    // -----------------------------------------------------------------
    // Op: Split
    // -----------------------------------------------------------------
    nonisolated private func runSplit(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snapshot = await MainActor.run {
            (sources: self.sources, mode: self.splitMode, ranges: self.splitRanges)
        }
        guard !snapshot.sources.isEmpty else {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "Add a PDF to split.")) }
            return
        }
        let dir = try PDFOpsFS.outputDir(for: .split)
        for (si, src) in snapshot.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snapshot.sources.count),
                              "Splitting \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            let pageCount = doc.pageCount
            let groups: [[Int]]
            switch snapshot.mode {
            case .everyPage:
                groups = (0..<pageCount).map { [$0] }
            case .ranges:
                do {
                    let pages = try PDFOpsRange.parse(snapshot.ranges, pageCount: pageCount)
                    groups = [pages]
                } catch {
                    await MainActor.run {
                        self.appendFailure(.init(label: src.url.lastPathComponent,
                                                 message: error.localizedDescription))
                    }
                    continue
                }
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            for (gi, group) in groups.enumerated() {
                try await checkCancel()
                autoreleasepool {
                    let part = PDFDocument()
                    for (k, pIdx) in group.enumerated() {
                        if let p = doc.page(at: pIdx)?.copy() as? PDFPage {
                            part.insert(p, at: k)
                        }
                    }
                    if part.pageCount == 0 { return }
                    let label: String
                    switch snapshot.mode {
                    case .everyPage:
                        label = "\(base) - p\(String(format: "%03d", group[0] + 1))"
                    case .ranges:
                        label = "\(base) - pages"
                    }
                    let target = PDFOpsFS.uniqueURL(in: dir, baseName: label, ext: "pdf")
                    do {
                        try PDFOpsFS.writePDFAtomically(part, to: target)
                        let out = PDFOpsOutput(url: target,
                                               bytes: PDFOpsFS.size(of: target),
                                               sourceLabel: src.url.lastPathComponent,
                                               opKind: .split)
                        Task { @MainActor in
                            self.appendOutput(out, recents: recents, toStage: sendToStage)
                        }
                    } catch {
                        Task { @MainActor in
                            self.appendFailure(.init(label: target.lastPathComponent,
                                                     message: error.localizedDescription))
                        }
                    }
                    _ = gi
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Compress — re-encode images via PDFKit raster fallback.
    // -----------------------------------------------------------------
    nonisolated private func runCompress(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snapshot = await MainActor.run {
            (sources: self.sources, q: self.compressQuality)
        }
        guard !snapshot.sources.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .compress)
        for (si, src) in snapshot.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snapshot.sources.count),
                              "Compressing \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            let outDoc = PDFDocument()
            let q = CGFloat(snapshot.q)
            for i in 0..<doc.pageCount {
                try await checkCancel()
                autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let bounds = page.bounds(for: .mediaBox)
                    // Render the page to a bitmap at a sensible DPI (150).
                    let scale: CGFloat = 150.0 / 72.0
                    let pxW = max(1, Int(bounds.width * scale))
                    let pxH = max(1, Int(bounds.height * scale))
                    let cs = CGColorSpaceCreateDeviceRGB()
                    guard let ctx = CGContext(data: nil,
                                              width: pxW, height: pxH,
                                              bitsPerComponent: 8,
                                              bytesPerRow: 0,
                                              space: cs,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return }
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                    ctx.saveGState()
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                    guard let cg = ctx.makeImage() else { return }
                    // Wrap as a JPEG-encoded NSImage and ask PDFKit to make a page from it.
                    let bmp = NSBitmapImageRep(cgImage: cg)
                    guard let jpegData = bmp.representation(using: .jpeg,
                                                            properties: [.compressionFactor: q])
                    else { return }
                    guard let nsimg = NSImage(data: jpegData) else { return }
                    if let newPage = PDFPage(image: nsimg) {
                        // Match original page size in points.
                        newPage.setBounds(bounds, for: .mediaBox)
                        outDoc.insert(newPage, at: outDoc.pageCount)
                    }
                }
            }
            guard outDoc.pageCount > 0 else {
                await MainActor.run {
                    self.appendFailure(.init(label: src.url.lastPathComponent,
                                             message: "Couldn't re-encode pages."))
                }
                continue
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (compressed)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(outDoc, to: target)
            let newSize = PDFOpsFS.size(of: target)
            let origSize = src.bytes
            if newSize >= origSize && origSize > 0 {
                // Already optimal — discard our output, surface a note.
                try? FileManager.default.removeItem(at: target)
                await MainActor.run {
                    self.appendFailure(.init(
                        label: src.url.lastPathComponent,
                        message: "Already compressed (\(origSize.human) → \(newSize.human) would be larger). Kept original."))
                }
            } else {
                await MainActor.run {
                    var note = ""
                    if origSize > 0 {
                        // red-team: broken up — Swift type checker timed out on the
                        // single-line nested-mixed-numeric expression.
                        let origD = Double(origSize)
                        let newD = Double(newSize)
                        let ratio: Double = 1.0 - (newD / origD)
                        let pct = Int((ratio * 100).rounded())
                        note = "\(origSize.human) → \(newSize.human) (\(pct)% smaller)"
                    }
                    var o = PDFOpsOutput(url: target,
                                         bytes: newSize,
                                         sourceLabel: src.url.lastPathComponent,
                                         opKind: .compress)
                    o.note = note
                    self.appendOutput(o, recents: recents, toStage: sendToStage)
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Rotate
    // -----------------------------------------------------------------
    nonisolated private func runRotate(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (sources: self.sources, deg: self.rotateDegrees,
             all: self.rotateAllPages, range: self.rotateRange)
        }
        guard !snap.sources.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .rotate)
        for (si, src) in snap.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snap.sources.count),
                              "Rotating \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            let pageIndexes: [Int]
            if snap.all {
                pageIndexes = Array(0..<doc.pageCount)
            } else {
                do {
                    pageIndexes = try PDFOpsRange.parse(snap.range, pageCount: doc.pageCount)
                } catch {
                    await MainActor.run {
                        self.appendFailure(.init(label: src.url.lastPathComponent,
                                                 message: error.localizedDescription))
                    }
                    continue
                }
            }
            // PDFPage.rotation is in 0/90/180/270.
            for idx in pageIndexes {
                if let p = doc.page(at: idx) {
                    // CW = +90 (PDFKit), CCW = -90 → +270, 180 stays.
                    let delta = ((snap.deg % 360) + 360) % 360
                    p.rotation = ((p.rotation + delta) % 360 + 360) % 360
                }
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (rotated)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                self.appendOutput(.init(url: target,
                                        bytes: PDFOpsFS.size(of: target),
                                        sourceLabel: src.url.lastPathComponent,
                                        opKind: .rotate),
                                  recents: recents, toStage: sendToStage)
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Organize — reorder + delete pages.
    // -----------------------------------------------------------------
    /// Order is owned by the view (an array of source-page-indexes); the model
    /// just executes it.
    @Published var organizeOrder: [Int] = []   // ordered source page indexes (zero-based)

    nonisolated private func runOrganize(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (sources: self.sources, order: self.organizeOrder)
        }
        guard let src = snap.sources.first else {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "Add one PDF.")) }
            return
        }
        guard !snap.order.isEmpty else {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "No pages selected.")) }
            return
        }
        let dir = try PDFOpsFS.outputDir(for: .organize)
        guard let doc = await loadOrFail(src) else { return }
        let out = PDFDocument()
        for (i, srcIdx) in snap.order.enumerated() {
            try await checkCancel()
            guard srcIdx >= 0, srcIdx < doc.pageCount else { continue }
            if let p = doc.page(at: srcIdx)?.copy() as? PDFPage {
                out.insert(p, at: i)
            }
        }
        guard out.pageCount > 0 else { return }
        let base = src.url.deletingPathExtension().lastPathComponent
        let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (organized)", ext: "pdf")
        try PDFOpsFS.writePDFAtomically(out, to: target)
        await MainActor.run {
            self.appendOutput(.init(url: target,
                                    bytes: PDFOpsFS.size(of: target),
                                    sourceLabel: src.url.lastPathComponent,
                                    opKind: .organize),
                              recents: recents, toStage: sendToStage)
        }
    }

    // -----------------------------------------------------------------
    // Op: Page numbers
    // -----------------------------------------------------------------
    nonisolated private func runPageNumbers(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (sources: self.sources, pos: self.pnPosition, size: self.pnFontSize,
             format: self.pnFormat, prefix: self.pnCustomPrefix)
        }
        guard !snap.sources.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .pageNumbers)
        for (si, src) in snap.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snap.sources.count),
                              "Numbering \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            let total = doc.pageCount
            for i in 0..<total {
                try await checkCancel()
                guard let page = doc.page(at: i) else { continue }
                let txt: String
                switch snap.format {
                case .pageN:    txt = "Page \(i + 1)"
                case .nOfTotal: txt = "\(i + 1) / \(total)"
                case .justN:    txt = "\(i + 1)"
                case .custom:   txt = "\(snap.prefix) \(i + 1)"
                }
                let bounds = page.bounds(for: .mediaBox)
                let pad: CGFloat = 24
                // Approximate width — annotations don't auto-size, we estimate.
                let w: CGFloat = CGFloat(txt.count) * CGFloat(snap.size) * 0.62 + 8
                let h: CGFloat = CGFloat(snap.size) + 6
                let x: CGFloat
                switch snap.pos {
                case .topLeft, .bottomLeft:        x = pad
                case .topCenter, .bottomCenter:    x = (bounds.width - w) / 2
                case .topRight, .bottomRight:      x = bounds.width - w - pad
                }
                let y: CGFloat
                switch snap.pos {
                case .topLeft, .topCenter, .topRight:           y = bounds.height - h - pad
                case .bottomLeft, .bottomCenter, .bottomRight:  y = pad
                }
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                ann.font = NSFont.systemFont(ofSize: CGFloat(snap.size))
                ann.color = .clear
                ann.fontColor = .labelColor
                ann.contents = txt
                page.addAnnotation(ann)
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (numbered)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                self.appendOutput(.init(url: target,
                                        bytes: PDFOpsFS.size(of: target),
                                        sourceLabel: src.url.lastPathComponent,
                                        opKind: .pageNumbers),
                                  recents: recents, toStage: sendToStage)
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Watermark
    // -----------------------------------------------------------------
    nonisolated private func runWatermark(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (sources: self.sources, kind: self.wmKind, text: self.wmText,
             opacity: self.wmOpacity, fontSize: self.wmFontSize,
             rot: self.wmRotation, color: NSColor(self.wmColor),
             imgURL: self.wmImageURL)
        }
        guard !snap.sources.isEmpty else { return }
        if snap.kind == .image, snap.imgURL == nil {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "Drop a watermark image first.")) }
            return
        }
        let dir = try PDFOpsFS.outputDir(for: .watermark)
        // Pre-load watermark image once.
        // red-team: corrupt PNG → NSImage(contentsOf:) returns nil. The
        // per-page branch silently no-ops. Detect and fail loudly up front
        // so the user knows nothing will be stamped.
        var stampImage: NSImage? = nil
        if snap.kind == .image, let u = snap.imgURL {
            stampImage = Self.loadImageHonoringEXIF(u)
            if stampImage == nil {
                await MainActor.run {
                    self.appendFailure(.init(label: u.lastPathComponent,
                                             message: "Couldn't read watermark image."))
                }
                return
            }
        }

        for (si, src) in snap.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snap.sources.count),
                              "Watermarking \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            for i in 0..<doc.pageCount {
                try await checkCancel()
                guard let page = doc.page(at: i) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                if snap.kind == .text {
                    // red-team: the previous code built a baked stamp image
                    // and attached it via STAMP_IMAGE key, but PDFKit doesn't
                    // honor that — the stamp was leaked and never rendered.
                    // Drop the dead allocation; only the freeText annotation
                    // actually paints.
                    let textAnn = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                    textAnn.font = NSFont.boldSystemFont(ofSize: CGFloat(snap.fontSize))
                    textAnn.fontColor = snap.color.withAlphaComponent(CGFloat(snap.opacity))
                    textAnn.color = .clear
                    textAnn.contents = snap.text
                    textAnn.alignment = .center
                    page.addAnnotation(textAnn)
                } else if let stamp = stampImage {
                    // Image watermark: center, fit to ~60% page width.
                    let pageW = bounds.width
                    let target = pageW * 0.6
                    let scale = target / max(stamp.size.width, 1)
                    let w = stamp.size.width * scale
                    let h = stamp.size.height * scale
                    let r = CGRect(x: (bounds.width - w) / 2,
                                   y: (bounds.height - h) / 2, width: w, height: h)
                    let ann = PDFAnnotation(bounds: r, forType: .stamp, withProperties: nil)
                    // Render the image with the requested opacity into a fresh NSImage.
                    let img = NSImage(size: r.size, flipped: false) { rect in
                        stamp.draw(in: rect, from: .zero, operation: .sourceOver,
                                   fraction: CGFloat(snap.opacity))
                        return true
                    }
                    ann.setValue(img, forAnnotationKey: .init(rawValue: "STAMP_IMAGE"))
                    page.addAnnotation(ann)
                }
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (watermarked)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                self.appendOutput(.init(url: target,
                                        bytes: PDFOpsFS.size(of: target),
                                        sourceLabel: src.url.lastPathComponent,
                                        opKind: .watermark),
                                  recents: recents, toStage: sendToStage)
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Crop
    // -----------------------------------------------------------------
    nonisolated private func runCrop(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (sources: self.sources, t: self.cropTop, r: self.cropRight,
             b: self.cropBottom, l: self.cropLeft,
             all: self.cropAllPages, range: self.cropRange)
        }
        guard !snap.sources.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .crop)
        for (si, src) in snap.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snap.sources.count),
                              "Cropping \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            let pageIndexes: [Int]
            if snap.all {
                pageIndexes = Array(0..<doc.pageCount)
            } else {
                do {
                    pageIndexes = try PDFOpsRange.parse(snap.range, pageCount: doc.pageCount)
                } catch {
                    await MainActor.run {
                        self.appendFailure(.init(label: src.url.lastPathComponent,
                                                 message: error.localizedDescription))
                    }
                    continue
                }
            }
            for idx in pageIndexes {
                guard let page = doc.page(at: idx) else { continue }
                var mb = page.bounds(for: .mediaBox)
                mb.origin.x += CGFloat(snap.l)
                mb.origin.y += CGFloat(snap.b)
                mb.size.width  = max(1, mb.size.width  - CGFloat(snap.l + snap.r))
                mb.size.height = max(1, mb.size.height - CGFloat(snap.t + snap.b))
                page.setBounds(mb, for: .cropBox)
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (cropped)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                self.appendOutput(.init(url: target,
                                        bytes: PDFOpsFS.size(of: target),
                                        sourceLabel: src.url.lastPathComponent,
                                        opKind: .crop),
                                  recents: recents, toStage: sendToStage)
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Protect (encrypt)
    // -----------------------------------------------------------------
    nonisolated private func runProtect(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (sources: self.sources, pw: self.passwordInput)
        }
        guard !snap.sources.isEmpty else { return }
        guard !snap.pw.isEmpty else {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "Enter a password.")) }
            return
        }
        // red-team: PDF 1.7 password encryption truncates to 127 bytes; some
        // older viewers (Acrobat ≤ 9) truncate to 32. We accept any length
        // (the user knows their target) but warn for very short passwords
        // since "encrypted with `abc`" is functionally encryption theatre.
        // We DO NOT block — surface a one-line note instead and let the
        // op proceed. Surfacing-then-proceeding matches the file_hash pane's
        // warning convention.
        if snap.pw.count < 6 {
            await MainActor.run {
                self.appendFailure(.init(
                    label: "—",
                    message: "Note: password is very short (<6 chars). Protection will still apply, but anyone can crack it offline in seconds."
                ))
            }
        }
        let dir = try PDFOpsFS.outputDir(for: .protect)
        for src in snap.sources {
            try await checkCancel()
            guard let doc = await loadOrFail(src) else { continue }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (locked)", ext: "pdf")
            let parent = target.deletingLastPathComponent()
            let tmp = parent.appendingPathComponent(
                ".\(target.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp")
            try? FileManager.default.removeItem(at: tmp)
            let opts: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: snap.pw,
                .ownerPasswordOption: snap.pw,
            ]
            let ok = doc.write(to: tmp, withOptions: opts)
            if !ok {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    self.appendFailure(.init(label: src.url.lastPathComponent,
                                             message: "Encryption failed"))
                }
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: target)
                }
                await MainActor.run {
                    self.appendOutput(.init(url: target,
                                            bytes: PDFOpsFS.size(of: target),
                                            sourceLabel: src.url.lastPathComponent,
                                            opKind: .protect),
                                      recents: recents, toStage: sendToStage)
                }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    self.appendFailure(.init(label: src.url.lastPathComponent,
                                             message: error.localizedDescription))
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: Unlock — writes a decrypted copy.
    // -----------------------------------------------------------------
    // red-team: a PDF can be "user-password-protected" (can't open without
    // pw) OR "owner-password-protected" (can open but copy/print/etc are
    // restricted). loadOrFail handles the first. For the second, PDFKit's
    // doc.write(to:) without options writes WITHOUT encryption — owner
    // restrictions are dropped automatically. We document that here so the
    // op covers BOTH common "unlock" intents (open-protected and
    // restriction-protected).
    nonisolated private func runUnlock(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snapshot = await MainActor.run { self.sources }
        guard !snapshot.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .unlock)
        for src in snapshot {
            try await checkCancel()
            guard let doc = await loadOrFail(src) else { continue }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (unlocked)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                self.appendOutput(.init(url: target,
                                        bytes: PDFOpsFS.size(of: target),
                                        sourceLabel: src.url.lastPathComponent,
                                        opKind: .unlock),
                                  recents: recents, toStage: sendToStage)
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: PDF → Image (JPG/PNG)
    // -----------------------------------------------------------------
    enum RenderFormat { case jpeg, png
        var ext: String { self == .jpeg ? "jpg" : "png" }
        var uti: CFString { (self == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString }
    }

    nonisolated private func runRender(format: RenderFormat, sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run { (sources: self.sources, dpi: self.renderDPI) }
        guard !snap.sources.isEmpty else { return }
        let opKind: PDFOpKind = (format == .jpeg) ? .toJPG : .toPNG
        let dir = try PDFOpsFS.outputDir(for: opKind)
        let scale: CGFloat = CGFloat(snap.dpi) / 72.0
        for (si, src) in snap.sources.enumerated() {
            try await checkCancel()
            await setProgress(Double(si) / Double(snap.sources.count),
                              "Rendering \(src.url.lastPathComponent)…")
            guard let doc = await loadOrFail(src) else { continue }
            // Per-source folder.
            let base = src.url.deletingPathExtension().lastPathComponent
            var folder = dir.appendingPathComponent(base, isDirectory: true)
            // Avoid overwriting an existing folder.
            var n = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = dir.appendingPathComponent("\(base) (\(n))", isDirectory: true)
                n += 1
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let total = doc.pageCount
            for i in 0..<total {
                try await checkCancel()
                // Render to an image-data + URL pair inside an autoreleasepool,
                // then write outside it so we can throw.
                struct PageRender { let data: Data; let url: URL }
                let render: PageRender? = autoreleasepool {
                    guard let page = doc.page(at: i) else { return nil }
                    let bounds = page.bounds(for: .mediaBox)
                    let pxW = max(1, Int(bounds.width * scale))
                    let pxH = max(1, Int(bounds.height * scale))
                    let cs = CGColorSpaceCreateDeviceRGB()
                    guard let ctx = CGContext(data: nil,
                                              width: pxW, height: pxH,
                                              bitsPerComponent: 8,
                                              bytesPerRow: 0,
                                              space: cs,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return nil }
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                    ctx.saveGState()
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                    guard let cg = ctx.makeImage() else { return nil }
                    let outURL = folder
                        .appendingPathComponent("\(base)-p\(String(format: "%03d", i + 1))")
                        .appendingPathExtension(format.ext)
                    let nsdata = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(nsdata, format.uti, 1, nil) else { return nil }
                    var props: [CFString: Any] = [:]
                    if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.85 }
                    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else { return nil }
                    return PageRender(data: nsdata as Data, url: outURL)
                }
                if let r = render {
                    try PDFOpsFS.writeDataAtomically(r.data, to: r.url)
                }
            }
            // The "output" for this op is the folder.
            let folderSize = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]))?
                .reduce(Int64(0)) { sum, u in
                    sum + (((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0)
                } ?? 0
            await MainActor.run {
                var o = PDFOpsOutput(url: folder, bytes: folderSize,
                                     sourceLabel: src.url.lastPathComponent,
                                     opKind: opKind)
                o.note = "\(total) image\(total == 1 ? "" : "s") at \(snap.dpi) DPI"
                self.appendOutput(o, recents: recents, toStage: sendToStage)
            }
        }
    }

    // red-team: ImageIO load that bakes EXIF orientation into pixel data so
    // downstream code that asks for .size or draws the NSImage gets the
    // correctly-rotated image. Returns nil on any failure.
    nonisolated private static func loadImageHonoringEXIF(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Large enough to keep full resolution.
            kCGImageSourceThumbnailMaxPixelSize: 16384,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            // Fallback: try plain NSImage.
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    // -----------------------------------------------------------------
    // Op: Images → PDF
    // -----------------------------------------------------------------
    nonisolated private func runImagesToPDF(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snap = await MainActor.run {
            (imgs: self.imgSources, size: self.imgPageSize)
        }
        guard !snap.imgs.isEmpty else {
            await MainActor.run { self.appendFailure(.init(label: "—", message: "Add at least one image.")) }
            return
        }
        let dir = try PDFOpsFS.outputDir(for: .imagesToPDF)
        let doc = PDFDocument()
        for (i, src) in snap.imgs.enumerated() {
            try await checkCancel()
            if src.invalid {
                await MainActor.run {
                    self.appendFailure(.init(label: src.url.lastPathComponent, message: src.note))
                }
                continue
            }
            // red-team: NSImage(contentsOf:) doesn't always honor EXIF
            // orientation (and uses representation pixel dims for .size, which
            // is the unrotated camera sensor frame). For photos taken in
            // portrait, the aspect-ratio compare below would then think the
            // page should be landscape. Load via ImageIO and bake EXIF.
            guard let img = Self.loadImageHonoringEXIF(src.url) else {
                await MainActor.run {
                    self.appendFailure(.init(label: src.url.lastPathComponent, message: "Couldn't read image"))
                }
                continue
            }
            // Orientation auto-detect: rotate the page to match aspect.
            let aspect = img.size.width / max(img.size.height, 1)
            var page: PDFPage?
            if let pr = snap.size.pointsRect {
                // Fit-to-page modes: auto-rotate page to match image landscape/portrait.
                var rect = pr
                let pageAspect = rect.width / rect.height
                if (aspect > 1 && pageAspect < 1) || (aspect < 1 && pageAspect > 1) {
                    rect = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
                }
                // Build an image scaled to fit the rect.
                let scale = min(rect.width / max(img.size.width, 1),
                                rect.height / max(img.size.height, 1))
                let fitW = img.size.width * scale
                let fitH = img.size.height * scale
                let canvas = NSImage(size: rect.size, flipped: false) { _ in
                    NSColor.white.setFill()
                    NSBezierPath(rect: NSRect(origin: .zero, size: rect.size)).fill()
                    img.draw(in: NSRect(x: (rect.width - fitW) / 2,
                                        y: (rect.height - fitH) / 2,
                                        width: fitW, height: fitH))
                    return true
                }
                page = PDFPage(image: canvas)
                page?.setBounds(rect, for: .mediaBox)
            } else {
                page = PDFPage(image: img)
            }
            if let p = page {
                doc.insert(p, at: i)
            }
        }
        guard doc.pageCount > 0 else { return }
        let target = PDFOpsFS.uniqueURL(in: dir, baseName: "Images to PDF", ext: "pdf")
        try PDFOpsFS.writePDFAtomically(doc, to: target)
        await MainActor.run {
            self.appendOutput(.init(url: target,
                                    bytes: PDFOpsFS.size(of: target),
                                    sourceLabel: "\(snap.imgs.count) images",
                                    opKind: .imagesToPDF),
                              recents: recents, toStage: sendToStage)
        }
    }

    // -----------------------------------------------------------------
    // Op: Repair
    // -----------------------------------------------------------------
    nonisolated private func runRepair(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snapshot = await MainActor.run { self.sources }
        guard !snapshot.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .repair)
        for src in snapshot {
            try await checkCancel()
            // Use PDFOpsLoader directly so we even attempt files we marked invalid
            // (Repair may recover those).
            let (doc, reason) = PDFOpsLoader.load(src.url, password: src.password)
            guard let doc else {
                await MainActor.run {
                    self.appendFailure(.init(label: src.url.lastPathComponent,
                                             message: reason.isEmpty ? "Couldn't open" : reason))
                }
                continue
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (repaired)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                self.appendOutput(.init(url: target,
                                        bytes: PDFOpsFS.size(of: target),
                                        sourceLabel: src.url.lastPathComponent,
                                        opKind: .repair),
                                  recents: recents, toStage: sendToStage)
            }
        }
    }

    // -----------------------------------------------------------------
    // Op: OCR — Vision text overlay (invisible).
    // -----------------------------------------------------------------
    nonisolated private func runOCR(sendToStage: Bool, recents: PDFOpsRecents) async throws {
        let snapshot = await MainActor.run { self.sources }
        guard !snapshot.isEmpty else { return }
        let dir = try PDFOpsFS.outputDir(for: .ocr)
        for (si, src) in snapshot.enumerated() {
            try await checkCancel()
            guard let doc = await loadOrFail(src) else { continue }
            let total = doc.pageCount
            var skipped = 0
            var ocrd = 0
            for i in 0..<total {
                try await checkCancel()
                await setProgress(Double(si) / Double(snapshot.count)
                                  + (1.0 / Double(snapshot.count)) * (Double(i) / Double(max(total, 1))),
                                  "OCR \(src.url.lastPathComponent) — p\(i + 1)/\(total)")
                guard let page = doc.page(at: i) else { continue }
                // If page already has selectable text, skip.
                let existing = page.attributedString?.string ?? ""
                if existing.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 {
                    skipped += 1
                    continue
                }
                autoreleasepool {
                    let bounds = page.bounds(for: .mediaBox)
                    // red-team: must account for page.rotation. We render in
                    // the page's *displayed* orientation (PDFKit's page.draw
                    // already applies the rotation when drawing), but the
                    // annotation rect must be in the page's UNROTATED media
                    // box coords. So we compute the displayed canvas size,
                    // OCR against that, then unrotate the bounding box back
                    // to media-box space before placing the annotation.
                    let rot = ((page.rotation % 360) + 360) % 360
                    let isQuarter = (rot == 90 || rot == 270)
                    let displayedW = isQuarter ? bounds.height : bounds.width
                    let displayedH = isQuarter ? bounds.width  : bounds.height
                    let scale: CGFloat = 200.0 / 72.0
                    let pxW = max(1, Int(displayedW * scale))
                    let pxH = max(1, Int(displayedH * scale))
                    let cs = CGColorSpaceCreateDeviceRGB()
                    guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: cs,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return }
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                    ctx.saveGState()
                    ctx.scaleBy(x: scale, y: scale)
                    // page.draw honors page.rotation and yields a canvas of
                    // size (displayedW × displayedH) with origin (0,0).
                    page.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                    guard let cg = ctx.makeImage() else { return }

                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    req.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                    do { try handler.perform([req]) } catch { return }
                    let observations: [VNRecognizedTextObservation] = req.results ?? []
                    for obs in observations {
                        guard let top = obs.topCandidates(1).first else { continue }
                        // Vision uses normalized (0..1) coords with origin
                        // bottom-left of the IMAGE we handed it. That image
                        // is the page in displayed (rotated) orientation.
                        // We unrotate to media-box space.
                        let bb = obs.boundingBox
                        // Bounds in displayed-coord space.
                        let dx = bb.minX * displayedW
                        let dy = bb.minY * displayedH
                        let dw = bb.width  * displayedW
                        let dh = bb.height * displayedH
                        let rect: CGRect
                        switch rot {
                        case 90:
                            // Displayed (x,y) → media (y, W - x - w)
                            rect = CGRect(x: bounds.minX + dy,
                                          y: bounds.minY + (bounds.height - dx - dw),
                                          width: dh, height: dw)
                        case 180:
                            rect = CGRect(x: bounds.minX + (bounds.width  - dx - dw),
                                          y: bounds.minY + (bounds.height - dy - dh),
                                          width: dw, height: dh)
                        case 270:
                            rect = CGRect(x: bounds.minX + (bounds.width - dy - dh),
                                          y: bounds.minY + dx,
                                          width: dh, height: dw)
                        default: // 0
                            rect = CGRect(x: bounds.minX + dx,
                                          y: bounds.minY + dy,
                                          width: dw, height: dh)
                        }
                        let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                        ann.font = NSFont.systemFont(ofSize: max(rect.height * 0.8, 6))
                        ann.color = .clear              // invisible background
                        ann.fontColor = .clear          // invisible text
                        ann.contents = top.string
                        page.addAnnotation(ann)
                    }
                    ocrd += 1
                }
            }
            let base = src.url.deletingPathExtension().lastPathComponent
            let target = PDFOpsFS.uniqueURL(in: dir, baseName: "\(base) (searchable)", ext: "pdf")
            try PDFOpsFS.writePDFAtomically(doc, to: target)
            await MainActor.run {
                var o = PDFOpsOutput(url: target,
                                     bytes: PDFOpsFS.size(of: target),
                                     sourceLabel: src.url.lastPathComponent,
                                     opKind: .ocr)
                let parts = [
                    ocrd > 0 ? "\(ocrd) page\(ocrd == 1 ? "" : "s") OCR'd" : nil,
                    skipped > 0 ? "\(skipped) skipped (already had text)" : nil
                ].compactMap { $0 }
                o.note = parts.joined(separator: " · ")
                self.appendOutput(o, recents: recents, toStage: sendToStage)
            }
        }
    }
}

// ===========================================================================
// MARK: - Drop helpers
// ===========================================================================

enum PDFOpsDrop {
    /// Pull URLs out of an NSItemProvider list, calling back on the main actor.
    static func collectURLs(_ providers: [NSItemProvider],
                            completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { obj, _ in
                    if let u = obj {
                        lock.lock(); urls.append(u); lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

// ===========================================================================
// MARK: - Root view
// ===========================================================================

public struct PDFToolsView: View {
    @StateObject private var m = PDFOpsModel()
    @StateObject private var recents = PDFOpsRecents()
    @State private var currentOp: PDFOpKind? = nil
    @State private var dropTargeted = false

    public init() {}

    public var body: some View {
        Group {
            if let op = currentOp {
                PDFOpsDetailView(op: op,
                                 model: m,
                                 recents: recents,
                                 back: { currentOp = nil; m.clear() })
            } else {
                landing
            }
        }
        .navigationTitle("PDF Tools")
        .navigationSubtitle(currentOp?.title ?? "100% local — PDFKit + Vision, no uploads")
        .toolbar {
            if m.working {
                ToolbarItemGroup(placement: .primaryAction) {
                    ProgressView(value: m.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                    Button(role: .destructive) { m.cancel() } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Cancel after current page (Esc or ⌘.)")
                    Button("") { m.cancel() }
                        .keyboardShortcut(".", modifiers: [.command])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Landing grid
    // -------------------------------------------------------------------

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Every PDF tool. Nothing leaves your Mac.")
                            .font(.title2.weight(.semibold))
                        Text("Drop one or many PDFs into any operation — batch is the default. Outputs land in ~/Downloads/Trove/<operation>/ and can be sent straight to the Stage.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(PDFOpKind.allCases) { op in
                        PDFOpsCardButton(op: op,
                                         recentCount: recents.recents(for: op).count) {
                            currentOp = op
                            m.clear()
                            m.organizeOrder.removeAll()
                        }
                    }
                }

                if !allRecents.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent outputs").font(.headline)
                            ForEach(allRecents.prefix(5), id: \.id) { o in
                                HStack(spacing: 10) {
                                    Image(systemName: o.opKind.icon)
                                        .frame(width: 18)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(o.url.lastPathComponent)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Text("\(o.opKind.title) · \(o.bytes.human) · \(o.sourceLabel)")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([o.url])
                                    } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless)
                                    .help("Reveal in Finder")
                                    Button {
                                        SharedStore.stage.addFile(o.url)
                                        SharedStore.stage.flash("Sent \(o.url.lastPathComponent) to Stage")
                                    } label: { Image(systemName: "tray.and.arrow.down") }
                                    .buttonStyle(.borderless)
                                    .help("Send to Stage")
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var allRecents: [PDFOpsOutput] {
        recents.byOp.values.flatMap { $0 }.sorted { $0.createdAt > $1.createdAt }
    }
}

// ===========================================================================
// MARK: - Op landing card
// ===========================================================================

struct PDFOpsCardButton: View {
    let op: PDFOpKind
    let recentCount: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: op.icon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                    Spacer()
                    if recentCount > 0 {
                        Text("\(recentCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.background.tertiary, in: Capsule())
                    }
                }
                Text(op.title).font(.headline)
                Text(op.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hover ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                                        : AnyShapeStyle(HierarchicalShapeStyle.quaternary),
                                  lineWidth: hover ? 1.2 : 0.5)
            )
            // red-team: hover scale + fade ignored Reduce Motion. Under the
            // setting we drop the scale entirely and skip the animation so
            // the card stays put.
            .scaleEffect(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                         ? 1
                         : (hover ? 1.012 : 1))
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil : .easeOut(duration: 0.12),
                       value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// ===========================================================================
// MARK: - Detail view (per-op)
// ===========================================================================

struct PDFOpsDetailView: View {
    let op: PDFOpKind
    @ObservedObject var model: PDFOpsModel
    @ObservedObject var recents: PDFOpsRecents
    let back: () -> Void
    @State private var dropTargeted = false
    /// Output the user is currently previewing. Sheet renders the file via
    /// PDFKit / NSImage so the user can inspect the result BEFORE committing
    /// to a save. Outputs already live in a temp location; this is the
    /// preview-before-commit gate the user asked for.
    @State private var previewingOutput: PDFOpsOutput? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                dropZone
                if op == .imagesToPDF ? !model.imgSources.isEmpty : !model.sources.isEmpty {
                    sourcesList
                    parameters
                    runRow
                }
                if !model.outputs.isEmpty { outputsCard }
                if !model.failures.isEmpty { failuresCard }
            }
            .padding(24)
        }
        // Preview-before-save sheet. PDFOpsOutput conforms to Identifiable
        // (id: UUID) so `sheet(item:)` correctly drives presentation off the
        // optional binding.
        .sheet(item: $previewingOutput) { o in
            PDFOutputPreviewSheet(
                output: o,
                onSave:            { saveOutput(o); previewingOutput = nil },
                onSaveToDownloads: { quickSaveToDownloads(o); previewingOutput = nil },
                onRevealInFinder:  { NSWorkspace.shared.activateFileViewerSelecting([o.url]) },
                onClose:           { previewingOutput = nil }
            )
        }
    }

    // -------------------------------------------------------------------
    // Header
    // -------------------------------------------------------------------
    private var headerRow: some View {
        HStack(spacing: 14) {
            Image(systemName: op.icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(op.title).font(.title2.weight(.semibold))
                Text(op.blurb).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: back) {
                Label("Back to PDF Tools", systemImage: "chevron.left")
            }
            .controlSize(.regular)
        }
    }

    // -------------------------------------------------------------------
    // Drop zone
    // -------------------------------------------------------------------
    private var dropZone: some View {
        let allowedTypes: [UTType] = op.acceptsImages ? [.image, .fileURL] : [.pdf, .fileURL]
        return Card {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                Text(emptyDropMessage)
                    .font(.title3.weight(.medium))
                Text(op.singleInput
                     ? "Single-file op — only the first PDF you drop will be processed."
                     : "Multi-file op — drop as many as you like; they all run in one batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    pickFiles(allowedTypes)
                } label: { Label("Choose files…", systemImage: "folder") }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(dropTargeted ? Color.accentColor.opacity(0.10) : .clear)
                    .padding(-2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Color.accentColor : .clear,
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(-2)
            )
            // red-team: drop-target fade ignored Reduce Motion.
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil : .easeInOut(duration: 0.15),
                       value: dropTargeted)
        }
        .onDrop(of: allowedTypes, isTargeted: $dropTargeted) { providers in
            PDFOpsDrop.collectURLs(providers) { urls in
                // red-team-sec: resolve symlinks and reject non-regular files
                // before any model ingestion, matching the addPDFFiles /
                // addImageFiles guard. This handles the watermark-stamp drop
                // path which bypasses those entrypoints.
                let resolved: [URL] = urls.compactMap { u in
                    let r = u.resolvingSymlinksInPath()
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: r.path),
                       let ft = attrs[.type] as? FileAttributeType, ft != .typeRegular {
                        return nil
                    }
                    return r
                }
                if op == .watermark, model.wmKind == .image,
                   let img = resolved.first(where: { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil }) {
                    // Special case: image watermark uses the dropped image as the stamp.
                    model.wmImageURL = img
                }
                if op.acceptsImages {
                    model.addImageFiles(resolved)
                } else {
                    model.addPDFFiles(resolved)
                    // If user dropped a single PDF for an organize op, prime the order.
                    if op == .organize, let first = model.sources.first,
                       model.organizeOrder.isEmpty,
                       let doc = PDFDocument(url: first.url) {
                        model.organizeOrder = Array(0..<doc.pageCount)
                    }
                }
            }
            return true
        }
    }

    private var emptyDropMessage: String {
        if op.acceptsImages {
            return model.imgSources.isEmpty ? "Drop images here" : "Drop more images"
        } else {
            return model.sources.isEmpty ? "Drop PDFs here" : "Drop more PDFs"
        }
    }

    private func pickFiles(_ types: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = !op.singleInput
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        if op.acceptsImages {
            model.addImageFiles(panel.urls)
        } else {
            model.addPDFFiles(panel.urls)
            if op == .organize, let first = model.sources.first,
               model.organizeOrder.isEmpty,
               let doc = PDFDocument(url: first.url) {
                model.organizeOrder = Array(0..<doc.pageCount)
            }
        }
    }

    // -------------------------------------------------------------------
    // Source list
    // -------------------------------------------------------------------
    @ViewBuilder private var sourcesList: some View {
        if op.acceptsImages {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Images (\(model.imgSources.count))").font(.headline)
                        Spacer()
                        Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
                    }
                    List {
                        ForEach(model.imgSources) { s in
                            sourceRow(s, isImage: true)
                        }
                        .onMove { model.moveImages(from: $0, to: $1) }
                        .onDelete { idx in
                            for i in idx { model.removeImage(model.imgSources[i]) }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 160, maxHeight: 280)
                }
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("PDFs (\(model.sources.count))").font(.headline)
                        Spacer()
                        Text(op == .merge ? "Drag to reorder merge order" : "Drag to reorder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    List {
                        ForEach(model.sources) { s in
                            sourceRow(s, isImage: false)
                        }
                        .onMove { model.moveSources(from: $0, to: $1) }
                        .onDelete { idx in
                            for i in idx { model.removeSource(model.sources[i]) }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 160, maxHeight: 280)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ s: PDFOpsSource, isImage: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isImage ? "photo" : "doc.richtext")
                .foregroundStyle(s.invalid ? AnyShapeStyle(Color.red)
                                           : AnyShapeStyle(Color.accentColor))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.url.lastPathComponent).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(s.bytes.human)
                    if !s.note.isEmpty {
                        Text("·")
                        Text(s.note).foregroundStyle(s.invalid ? .red : .secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Per-row password for encrypted PDFs.
            if !isImage, s.note.lowercased().contains("password") || s.note.lowercased().contains("encrypted") {
                SecureField("Password", text: Binding(
                    get: { s.password },
                    set: { new in
                        if let i = model.sources.firstIndex(where: { $0.id == s.id }) {
                            model.sources[i].password = new
                            // Re-validate.
                            let (doc, reason) = PDFOpsLoader.load(model.sources[i].url, password: new)
                            if doc != nil {
                                model.sources[i].note = ""
                                model.sources[i].invalid = false
                            } else {
                                model.sources[i].note = reason
                            }
                        }
                    }))
                    .frame(width: 140)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 2)
    }

    // -------------------------------------------------------------------
    // Parameters (per-op controls)
    // -------------------------------------------------------------------
    @ViewBuilder private var parameters: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Options").font(.headline)
                switch op {
                case .merge:        Text("Order in the list above is the merge order.").font(.callout).foregroundStyle(.secondary)
                case .split:        splitParams
                case .compress:     compressParams
                case .rotate:       rotateParams
                case .organize:     organizeParams
                case .pageNumbers:  pnParams
                case .watermark:    wmParams
                case .crop:         cropParams
                case .protect:      protectParams
                case .unlock:       Text("Unlock removes the password from the output. Provide the current password per-file in the list above if required.").font(.callout).foregroundStyle(.secondary)
                case .toJPG, .toPNG: renderParams
                case .imagesToPDF:  imagesToPDFParams
                case .repair:       Text("Re-saves through PDFKit. Often recovers files that other viewers refuse to open.").font(.callout).foregroundStyle(.secondary)
                case .ocr:          Text("Renders each page, runs Apple Vision text recognition, and overlays an invisible text layer so the result is searchable in any reader. Pages that already contain selectable text are skipped.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // Split
    private var splitParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $model.splitMode) {
                ForEach(PDFOpsModel.SplitMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.splitMode == .ranges {
                HStack {
                    Text("Pages").frame(width: 90, alignment: .leading)
                    TextField("e.g. 1-3, 5, 7-9", text: $model.splitRanges)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // Compress
    private var compressParams: some View {
        HStack(spacing: 12) {
            Text("Quality").frame(width: 90, alignment: .leading)
            Slider(value: $model.compressQuality, in: 0.3...0.9)
            Text(String(format: "%.2f", model.compressQuality))
                .font(.callout.monospacedDigit()).frame(width: 50, alignment: .trailing)
        }
    }

    // Rotate
    private var rotateParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Rotation", selection: $model.rotateDegrees) {
                Text("90° CW").tag(90)
                Text("90° CCW").tag(-90)
                Text("180°").tag(180)
            }
            .pickerStyle(.segmented)
            Toggle("Apply to all pages", isOn: $model.rotateAllPages)
            if !model.rotateAllPages {
                HStack {
                    Text("Pages").frame(width: 90, alignment: .leading)
                    TextField("e.g. 1-3, 5", text: $model.rotateRange).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // Organize
    private var organizeParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let src = model.sources.first {
                Text("Drag thumbnails to reorder. ⌫ removes a page.").font(.callout).foregroundStyle(.secondary)
                PDFOpsThumbnailGrid(url: src.url, order: $model.organizeOrder)
                    .frame(minHeight: 260)
            }
        }
    }

    // Page numbers
    private var pnParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Position").frame(width: 90, alignment: .leading)
                Picker("", selection: $model.pnPosition) {
                    ForEach(PDFOpsModel.PNPosition.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 240).pickerStyle(.menu)
            }
            HStack {
                Text("Format").frame(width: 90, alignment: .leading)
                Picker("", selection: $model.pnFormat) {
                    ForEach(PDFOpsModel.PNFormat.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 240).pickerStyle(.menu)
            }
            if model.pnFormat == .custom {
                HStack {
                    Text("Prefix").frame(width: 90, alignment: .leading)
                    TextField("Page", text: $model.pnCustomPrefix).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Text("Font size").frame(width: 90, alignment: .leading)
                Slider(value: $model.pnFontSize, in: 8...32)
                Text("\(Int(model.pnFontSize))").font(.callout.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
        }
    }

    // Watermark
    private var wmParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: $model.wmKind) {
                ForEach(PDFOpsModel.WMKind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.wmKind == .text {
                HStack {
                    Text("Text").frame(width: 90, alignment: .leading)
                    TextField("CONFIDENTIAL", text: $model.wmText).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Color").frame(width: 90, alignment: .leading)
                    ColorPicker("", selection: $model.wmColor, supportsOpacity: false)
                    Spacer()
                }
                HStack {
                    Text("Font size").frame(width: 90, alignment: .leading)
                    Slider(value: $model.wmFontSize, in: 18...160)
                    Text("\(Int(model.wmFontSize))").font(.callout.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
                HStack {
                    Text("Rotation").frame(width: 90, alignment: .leading)
                    Slider(value: $model.wmRotation, in: -90...90)
                    Text("\(Int(model.wmRotation))°").font(.callout.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            } else {
                HStack {
                    Text("Image").frame(width: 90, alignment: .leading)
                    Text(model.wmImageURL?.lastPathComponent ?? "(drop an image onto the drop zone)")
                        .lineLimit(1)
                        .foregroundStyle(model.wmImageURL == nil ? .secondary : .primary)
                }
            }
            HStack {
                Text("Opacity").frame(width: 90, alignment: .leading)
                Slider(value: $model.wmOpacity, in: 0.05...1.0)
                Text(String(format: "%.2f", model.wmOpacity))
                    .font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
        }
    }

    // Crop
    private var cropParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Apply to all pages", isOn: $model.cropAllPages)
            if !model.cropAllPages {
                HStack {
                    Text("Pages").frame(width: 90, alignment: .leading)
                    TextField("e.g. 1-3, 5", text: $model.cropRange).textFieldStyle(.roundedBorder)
                }
            }
            Text("Margins in points (1 inch = 72 pt)").font(.caption).foregroundStyle(.secondary)
            HStack { Text("Top").frame(width: 70, alignment: .leading); Slider(value: $model.cropTop, in: 0...300); valueLabel(model.cropTop) }
            HStack { Text("Right").frame(width: 70, alignment: .leading); Slider(value: $model.cropRight, in: 0...300); valueLabel(model.cropRight) }
            HStack { Text("Bottom").frame(width: 70, alignment: .leading); Slider(value: $model.cropBottom, in: 0...300); valueLabel(model.cropBottom) }
            HStack { Text("Left").frame(width: 70, alignment: .leading); Slider(value: $model.cropLeft, in: 0...300); valueLabel(model.cropLeft) }
        }
    }
    private func valueLabel(_ v: Double) -> some View {
        Text("\(Int(v)) pt").font(.callout.monospacedDigit()).frame(width: 56, alignment: .trailing)
    }

    // Protect
    private var protectParams: some View {
        HStack {
            Text("Password").frame(width: 90, alignment: .leading)
            SecureField("Required", text: $model.passwordInput).textFieldStyle(.roundedBorder)
        }
    }

    // Render to image
    private var renderParams: some View {
        HStack {
            Text("DPI").frame(width: 90, alignment: .leading)
            Picker("", selection: $model.renderDPI) {
                Text("72").tag(72)
                Text("144").tag(144)
                Text("300").tag(300)
            }.pickerStyle(.segmented).frame(maxWidth: 260)
        }
    }

    // Images → PDF
    private var imagesToPDFParams: some View {
        HStack {
            Text("Page size").frame(width: 90, alignment: .leading)
            Picker("", selection: $model.imgPageSize) {
                ForEach(PDFOpsModel.ImgPageSize.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360)
        }
    }

    // -------------------------------------------------------------------
    // Run row
    // -------------------------------------------------------------------
    private var runRow: some View {
        HStack(spacing: 10) {
            Button {
                model.run(op, sendToStage: false, recents: recents)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.working || !canRun)

            Button {
                model.run(op, sendToStage: true, recents: recents)
            } label: {
                Label("Run + Send all to Stage", systemImage: "tray.and.arrow.down")
            }
            .disabled(model.working || !canRun)

            if model.working {
                ProgressView().controlSize(.small)
                Text(model.progressLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear", role: .destructive) { model.clear(); model.organizeOrder.removeAll() }
                .disabled(model.working)
        }
    }
    private var canRun: Bool {
        if op.acceptsImages {
            return !model.imgSources.isEmpty && !model.imgSources.contains(where: { $0.validating })
        }
        // Block Run while any file is still validating — the op would otherwise
        // race the parser and see an empty/stale invalid state.
        return !model.sources.isEmpty && !model.sources.contains(where: { $0.validating })
    }

    // -------------------------------------------------------------------
    // Outputs / failures
    // -------------------------------------------------------------------
    private var outputsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Outputs (\(model.outputs.count))").font(.headline)
                    Spacer()
                    if model.outputs.count > 1 {
                        Button { saveAllOutputs() } label: {
                            Label("Save All…", systemImage: "square.and.arrow.down.on.square")
                        }
                        .help("Pick a folder and save every output into it")
                    }
                }
                ForEach(model.outputs) { o in
                    // Only the first (most recent) row gets keyboard shortcuts.
                    // SwiftUI logs duplicate-shortcut warnings if every row binds
                    // ⌘S — and the active window's primary save is the latest one.
                    outputRow(o, isPrimary: o.id == model.outputs.first?.id)
                }
            }
        }
    }

    @ViewBuilder
    private func outputRow(_ o: PDFOpsOutput, isPrimary: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(o.bytes.human)
                    if !o.note.isEmpty {
                        Text("·"); Text(o.note)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { previewingOutput = o } label: {
                Label("Preview", systemImage: "eye")
            }
            .modifier(PDFPrimaryShortcut(isPrimary: isPrimary, key: "p"))
            .help(isPrimary ? "Preview (⌘P) — inspect before saving" : "Preview this output before saving.")
            .accessibilityLabel("Preview \(o.url.lastPathComponent) before saving")

            Button { saveOutput(o) } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .modifier(PDFPrimaryShortcut(isPrimary: isPrimary, key: "s"))
            .help(isPrimary ? "Save… (⌘S)" : "Choose where to save this file.")

            Menu {
                Button { quickSaveToDownloads(o) } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .modifier(PDFPrimaryShortcut(isPrimary: isPrimary, key: "d"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([o.url]) } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .modifier(PDFPrimaryShortcut(isPrimary: isPrimary, key: "r"))
                Button {
                    SharedStore.stage.addFile(o.url)
                    SharedStore.stage.flash("Sent \(o.url.lastPathComponent) to Stage")
                } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
                Divider()
                Button { copyOutputPath(o) } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        // The entire row is draggable — users can drag straight into Finder,
        // Mail, Slack, etc. NSItemProvider(contentsOf:) creates a file-URL
        // representation receivers accept as a real file drop.
        .onDrag {
            NSItemProvider(contentsOf: o.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button { previewingOutput = o } label: { Label("Preview", systemImage: "eye") }
            Divider()
            Button { saveOutput(o) } label: { Label("Save…", systemImage: "square.and.arrow.down") }
            Button { quickSaveToDownloads(o) } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([o.url]) } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
            Button {
                SharedStore.stage.addFile(o.url)
                SharedStore.stage.flash("Sent \(o.url.lastPathComponent) to Stage")
            } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
            Divider()
            Button { copyOutputPath(o) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    /// Save As… with NSSavePanel. Remembers the last-used directory so the
    /// user doesn't have to navigate from ~/ every time. Filename pre-filled
    /// from the output, so they just hit Return to keep it.
    private func saveOutput(_ o: PDFOpsOutput) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = o.url.lastPathComponent
        if let ut = UTType(filenameExtension: o.url.pathExtension) {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = Self.lastSaveDir() ?? Self.downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            Self.setLastSaveDir(dest.deletingLastPathComponent())
            do {
                // NSSavePanel itself prompts for overwrite consent; once we
                // get here, removing the existing file is what the user
                // asked for. copyItem refuses to overwrite, hence the gate.
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: o.url, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    private func quickSaveToDownloads(_ o: PDFOpsOutput) {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let dest = Self.collisionFreeURL(in: downloads, name: o.url.lastPathComponent)
        do {
            try fm.copyItem(at: o.url, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    private func copyOutputPath(_ o: PDFOpsOutput) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(o.url.path, forType: .string)
        SharedStore.stage.flash("Copied path")
    }

    /// Bulk save — pick a folder, dump every output there with collision-safe
    /// naming. Reveals the folder after so the user sees their files.
    private func saveAllOutputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Save All Here"
        panel.message = "Choose a destination folder for \(model.outputs.count) outputs."
        panel.directoryURL = Self.lastSaveDir() ?? Self.downloadsDir()
        let outputs = model.outputs
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            Self.setLastSaveDir(dir)
            let fm = FileManager.default
            var copied = 0
            for o in outputs {
                let dest = Self.collisionFreeURL(in: dir, name: o.url.lastPathComponent)
                if (try? fm.copyItem(at: o.url, to: dest)) != nil { copied += 1 }
            }
            if copied > 0 {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                SharedStore.stage.flash("Saved \(copied) of \(outputs.count) to \(dir.lastPathComponent)")
            } else {
                SharedStore.stage.flash("Save All failed — couldn't copy any files")
            }
        }
    }

    // ---- shared save helpers (statics so closures don't capture self) ----

    private static let kSaveDirKey = "pdf.outputs.saveDir.last"

    private static func lastSaveDir() -> URL? {
        guard let p = UserDefaults.standard.string(forKey: kSaveDirKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    private static func setLastSaveDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: kSaveDirKey)
    }

    private static func downloadsDir() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Append " (2)", " (3)"… before the extension until the destination
    /// doesn't exist. Cap at 99 — past that, just return the last candidate
    /// and let the copy fail with a sane error (don't loop forever).
    private static func collisionFreeURL(in dir: URL, name: String) -> URL {
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

    private var failuresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Issues (\(model.failures.count))").font(.headline)
                ForEach(model.failures) { f in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.label).font(.callout.weight(.medium))
                            Text(f.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Shared primary-row keyboard shortcut helper
// ===========================================================================

/// Apply a ⌘<key> shortcut only when this is the primary (most-recent) output
/// row. SwiftUI logs warnings about duplicate shortcuts within the same view
/// scope, so we attach the shortcut to a single row only and let context-menu
/// / right-click pick up the same actions on the rest.
struct PDFPrimaryShortcut: ViewModifier {
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

// ===========================================================================
// MARK: - Thumbnail grid (Organize op) — lazy + reorder + delete
// ===========================================================================

/// One thumbnail entry. `index` is the *source* page index in the original
/// document; the array order is what determines output order.
struct PDFOpsThumb: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let image: NSImage
}

/// red-team: PDFDocument is not thread-safe. We render thumbnails on a
/// dedicated serial actor so only ONE rendering task touches the doc at a
/// time. We also keep a single shared PDFDocument (per URL) instead of
/// reopening the entire file per cell.
actor PDFOpsThumbRenderer {
    private var doc: PDFDocument?
    private let url: URL
    init(url: URL) { self.url = url }

    func thumbnail(at idx: Int, target: CGFloat = 110) -> NSImage? {
        if doc == nil { doc = PDFDocument(url: url) }
        guard let doc, let page = doc.page(at: idx) else { return nil }
        return autoreleasepool { () -> NSImage in
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(target / max(bounds.width, 1),
                            target / max(bounds.height, 1))
            let size = CGSize(width: max(bounds.width * scale, 1),
                              height: max(bounds.height * scale, 1))
            return page.thumbnail(of: size, for: .mediaBox)
        }
    }

    func count() -> Int {
        if doc == nil { doc = PDFDocument(url: url) }
        return doc?.pageCount ?? 0
    }
}

struct PDFOpsThumbnailGrid: View {
    let url: URL
    @Binding var order: [Int]
    @State private var thumbs: [Int: NSImage] = [:]   // index → image, lazy
    @State private var pageCount: Int = 0
    @State private var selected: PDFOpsThumb.ID? = nil
    @State private var renderer: PDFOpsThumbRenderer? = nil
    private let cell: CGFloat = 120

    var body: some View {
        ScrollView {
            let cols = [GridItem(.adaptive(minimum: cell + 18), spacing: 10)]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(Array(order.enumerated()), id: \.offset) { pos, idx in
                    PDFOpsThumbCell(index: idx,
                                    position: pos + 1,
                                    image: thumbs[idx],
                                    onDelete: { delete(at: pos) })
                        .onAppear { loadThumb(idx) }
                        .onDrag {
                            // Drag payload: the position in `order`.
                            return NSItemProvider(object: NSString(string: "\(pos)"))
                        }
                        .onDrop(of: [UTType.plainText.identifier],
                                delegate: ReorderDropDelegate(targetPosition: pos, order: $order))
                }
            }
            .padding(8)
        }
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            // red-team: don't open the entire PDF on the main thread; do it
            // once on the renderer actor and only use it for the page count.
            let r = PDFOpsThumbRenderer(url: url)
            renderer = r
            Task {
                let n = await r.count()
                await MainActor.run {
                    pageCount = n
                    if order.isEmpty { order = Array(0..<n) }
                }
            }
        }
    }

    private func delete(at pos: Int) {
        guard pos >= 0, pos < order.count else { return }
        order.remove(at: pos)
    }

    private func loadThumb(_ idx: Int) {
        if thumbs[idx] != nil { return }
        // red-team: previous version opened a fresh PDFDocument per cell on
        // Task.detached. For a 1000-page book scrolled fast that's 1000 full
        // doc opens and 1000 independent in-memory PDFKit instances. Route
        // through the actor instead — single doc, serialized access.
        guard let r = renderer else { return }
        Task {
            let img = await r.thumbnail(at: idx)
            if let img {
                await MainActor.run { thumbs[idx] = img }
            }
        }
    }
}

struct PDFOpsThumbCell: View {
    let index: Int
    let position: Int
    let image: NSImage?
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 120, height: 150)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                if hover {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red, .white)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            Text("Page \(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .background(hover ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
        .onDeleteCommand(perform: onDelete)
    }
}

struct ReorderDropDelegate: DropDelegate {
    let targetPosition: Int
    @Binding var order: [Int]

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first
        else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let from = Int(s) else { return }
            DispatchQueue.main.async {
                guard from >= 0, from < order.count,
                      targetPosition >= 0, targetPosition < order.count,
                      from != targetPosition else { return }
                let item = order.remove(at: from)
                order.insert(item, at: targetPosition)
            }
        }
        return true
    }
}

// ===========================================================================
// MARK: - PDF output preview sheet
// ===========================================================================

/// Preview-before-save modal. Renders a PDF via `PDFView` (PDFKit) or an
/// image via `Image(nsImage:)` so the user can inspect the operation's
/// output BEFORE committing to a destination. Outputs already live in a
/// temp location at this point — the sheet's "Save…" / "Save to Downloads"
/// buttons forward to the existing handlers in `PDFOpsDetailView`.
///
/// Non-PDF non-image outputs (extremely unusual — Trove's PDF Tools always
/// produce one of these) fall through to a minimal "Open externally" hint.
struct PDFOutputPreviewSheet: View {
    let output: PDFOpsOutput
    let onSave: () -> Void
    let onSaveToDownloads: () -> Void
    let onRevealInFinder: () -> Void
    let onClose: () -> Void

    private var kind: PreviewKind {
        let ext = output.url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["png", "jpg", "jpeg", "tiff", "heic", "gif", "webp"].contains(ext) { return .image }
        return .other
    }

    enum PreviewKind { case pdf, image, other }

    var body: some View {
        VStack(spacing: 0) {
            // ---- Header ----
            HStack(spacing: 12) {
                Image(systemName: "eye.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.url.lastPathComponent)
                        .font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Preview · before save")
                        Text("·")
                        Text(output.bytes.human)
                        if !output.note.isEmpty { Text("·"); Text(output.note).lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Close preview")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            // ---- Body ----
            Group {
                switch kind {
                case .pdf:   PDFOutputPreviewPDFView(url: output.url)
                case .image: PDFOutputPreviewImageView(url: output.url)
                case .other: PDFOutputPreviewFallbackView(url: output.url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.troveBg)

            Divider()

            // ---- Action bar ----
            HStack(spacing: 10) {
                Button(role: .cancel) { onClose() } label: {
                    Text("Discard").frame(minWidth: 70)
                }
                .help("Close the preview without saving. The temp file stays in ~/Downloads/Trove until the next run.")

                Spacer()

                Button { onRevealInFinder() } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .help("Open the temp file's folder in Finder.")

                Button { onSaveToDownloads() } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("d", modifiers: .command)
                .help("Save into ~/Downloads with a collision-safe name (⌘D).")

                Button { onSave() } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Pick where to save (⌘S).")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 520, idealHeight: 720)
        .background(TroveAppBackground())
    }
}

/// PDFKit-backed preview. `PDFView` is an NSView, so wrap it via
/// `NSViewRepresentable`. Document loaded asynchronously on a background
/// thread to avoid blocking sheet presentation on a large file.
private struct PDFOutputPreviewPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = NSColor.clear
        // Load off-main; PDFDocument(url:) maps the file synchronously and
        // can take >1s for big files. Hop back on completion.
        let captured = url
        DispatchQueue.global(qos: .userInitiated).async {
            let doc = PDFDocument(url: captured)
            DispatchQueue.main.async { v.document = doc }
        }
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        // Document is loaded once via the async path in makeNSView; nothing
        // dynamic to update here.
    }
}

/// Image preview for PDF→JPG / PDF→PNG outputs (and any other image
/// extension we might add). Uses `CGImageSourceCreateThumbnailAtIndex` to
/// cap the decode at 2048 pixels — full-resolution decode of a multi-MP
/// image would briefly allocate hundreds of MB just to draw the preview.
private struct PDFOutputPreviewImageView: View {
    let url: URL
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(16)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            let u = url
            DispatchQueue.global(qos: .userInitiated).async {
                let img = Self.thumbnail(at: u, maxPixel: 2048)
                DispatchQueue.main.async { self.image = img }
            }
        }
    }

    private static func thumbnail(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Final fallback for non-PDF non-image outputs. Should be rare since the
/// PDF Tools pane only produces PDFs, JPGs, and PNGs.
private struct PDFOutputPreviewFallbackView: View {
    let url: URL
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent).font(.callout.weight(.medium))
            Text("This file type can't be previewed inline.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.open(url)
            } label: { Label("Open externally", systemImage: "arrow.up.right.square") }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
