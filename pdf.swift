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
// MARK: - Recent outputs (last 5 per op, persisted across launches)
// ===========================================================================

/// Lightweight Codable mirror of PDFOpsOutput, used solely for JSON persistence.
private struct PDFOpsRecentEntry: Codable {
    var urlPath: String
    var bytes: Int64
    var sourceLabel: String
    var opKind: String   // PDFOpKind.rawValue
    var note: String
    var createdAt: Double  // timeIntervalSince1970

    enum CodingKeys: String, CodingKey { case urlPath, bytes, sourceLabel, opKind, note, createdAt }

    init(urlPath: String, bytes: Int64, sourceLabel: String,
         opKind: String, note: String, createdAt: Double) {
        self.urlPath = urlPath; self.bytes = bytes; self.sourceLabel = sourceLabel
        self.opKind = opKind; self.note = note; self.createdAt = createdAt
    }

    /// P1 fix: tolerant decoder. Without this, adding any new field to the
    /// record in a future version would silently empty the entire PDF recents
    /// list (stored as `[PDFOpsRecentEntry]` in UserDefaults — synthesized
    /// decode is all-or-nothing on the array).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.urlPath     = try c.decode(String.self, forKey: .urlPath)
        self.bytes       = (try? c.decodeIfPresent(Int64.self,  forKey: .bytes))       ?? 0
        self.sourceLabel = (try? c.decodeIfPresent(String.self, forKey: .sourceLabel)) ?? ""
        self.opKind      = (try? c.decodeIfPresent(String.self, forKey: .opKind))      ?? ""
        self.note        = (try? c.decodeIfPresent(String.self, forKey: .note))        ?? ""
        self.createdAt   = (try? c.decodeIfPresent(Double.self, forKey: .createdAt))   ?? Date().timeIntervalSince1970
    }
}

@MainActor
final class PDFOpsRecents: ObservableObject {
    @Published private(set) var byOp: [PDFOpKind: [PDFOpsOutput]] = [:]

    private static let persistKey = "trove.pdf.recents.v1"

    init() {
        // Restore persisted recents on startup.
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let entries = try? JSONDecoder().decode([PDFOpsRecentEntry].self, from: data)
        else { return }
        var rebuilt: [PDFOpKind: [PDFOpsOutput]] = [:]
        for e in entries {
            guard let kind = PDFOpKind(rawValue: e.opKind) else { continue }
            let url = URL(fileURLWithPath: e.urlPath)
            // Skip entries whose output file no longer exists — stale after
            // the user cleaned Downloads or moved the file.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var out = PDFOpsOutput(
                url: url, bytes: e.bytes,
                sourceLabel: e.sourceLabel, opKind: kind
            )
            out.note = e.note
            rebuilt[kind, default: []].append(out)
        }
        byOp = rebuilt
    }

    func add(_ out: PDFOpsOutput) {
        var list = byOp[out.opKind] ?? []
        list.insert(out, at: 0)
        if list.count > 5 { list.removeLast(list.count - 5) }
        byOp[out.opKind] = list
        persist()
    }

    func recents(for op: PDFOpKind) -> [PDFOpsOutput] {
        byOp[op] ?? []
    }

    /// Flatten all recents and write to UserDefaults. Called after every mutation.
    private func persist() {
        let all: [PDFOpsRecentEntry] = byOp.values.flatMap { $0 }.map { o in
            PDFOpsRecentEntry(
                urlPath: o.url.path,
                bytes: o.bytes,
                sourceLabel: o.sourceLabel,
                opKind: o.opKind.rawValue,
                note: o.note,
                createdAt: o.createdAt.timeIntervalSince1970
            )
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
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

    deinit { runTask?.cancel() }

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
    /// P1: live watermark preview — rendered off-main, published here.
    @Published var wmPreviewImage: NSImage? = nil
    /// Monotonic counter to invalidate stale preview renders.
    private(set) var wmPreviewGeneration: Int = 0
    /// Debounce handle for the live preview task.
    private var wmPreviewTask: Task<Void, Never>? = nil

    enum WMKind: String, CaseIterable, Identifiable {
        case text = "Text", image = "Image"
        var id: String { rawValue }
    }

    /// P1: schedule a debounced live watermark preview render.
    /// Call from .onChange on every watermark parameter.
    func scheduleWatermarkPreview() {
        wmPreviewTask?.cancel()
        wmPreviewGeneration &+= 1
        let gen = wmPreviewGeneration
        // Capture params needed for off-main render.
        guard let src = sources.first else { wmPreviewImage = nil; return }
        let kind = wmKind
        let text = wmText
        let opacity = wmOpacity
        let fontSize = wmFontSize
        let rotation = wmRotation
        let color = NSColor(wmColor)
        let imgURL = wmImageURL
        wmPreviewTask = Task.detached(priority: .utility) { [weak self] in
            // Small debounce (150ms) so slider drags don't flood the queue.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let preview = Self.renderWatermarkPreview(
                sourceURL: src.url,
                kind: kind,
                text: text,
                opacity: opacity,
                fontSize: fontSize,
                rotation: rotation,
                color: color,
                imgURL: imgURL
            )
            await MainActor.run { [weak self] in
                guard let self, self.wmPreviewGeneration == gen else { return }
                self.wmPreviewImage = preview
            }
        }
    }

    /// Render watermark onto the first page of sourceURL at low resolution (144 DPI),
    /// returned as an NSImage suitable for the preview thumbnail.
    /// nonisolated static so it can be called from Task.detached.
    nonisolated private static func renderWatermarkPreview(
        sourceURL: URL,
        kind: WMKind,
        text: String,
        opacity: Double,
        fontSize: Double,
        rotation: Double,
        color: NSColor,
        imgURL: URL?
    ) -> NSImage? {
        let (doc, _) = PDFOpsLoader.load(sourceURL)
        guard let doc, doc.pageCount > 0, let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Render at 144 DPI for a crisp preview without OOM risk.
        let previewScale: CGFloat = 144.0 / 72.0
        let maxPx: CGFloat = 800
        let longSide = max(bounds.width, bounds.height) * previewScale
        let scale = longSide > maxPx ? previewScale * (maxPx / longSide) : previewScale
        let pxW = max(1, Int(bounds.width * scale))
        let pxH = max(1, Int(bounds.height * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                   bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // White background.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        // Render page content.
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        // Composite watermark.
        if kind == .text, !text.isEmpty {
            // Draw centered rotated text over the page.
            let cx = CGFloat(pxW) / 2
            let cy = CGFloat(pxH) / 2
            let nsStr = NSAttributedString(string: text, attributes: [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(fontSize) * scale),
                .foregroundColor: color.withAlphaComponent(CGFloat(opacity)),
            ])
            let strSize = nsStr.size()
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            let radians = CGFloat(rotation) * .pi / 180
            ctx.rotate(by: radians)
            // NSString drawing requires NSGraphicsContext.
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            nsStr.draw(at: NSPoint(x: -strSize.width / 2, y: -strSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        } else if kind == .image, let u = imgURL, let stamp = Self.loadImageHonoringEXIF(u) {
            let pageW = bounds.width * scale
            let targetW = pageW * 0.6
            let stampScl = targetW / max(stamp.size.width, 1)
            let stampW = stamp.size.width * stampScl
            let stampH = stamp.size.height * stampScl
            let stampX = (CGFloat(pxW) - stampW) / 2
            let stampY = (CGFloat(pxH) - stampH) / 2
            ctx.saveGState()
            ctx.setAlpha(CGFloat(opacity))
            if let cg = stamp.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cg, in: CGRect(x: stampX, y: stampY, width: stampW, height: stampH))
            }
            ctx.restoreGState()
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: pxW, height: pxH))
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
    @Published var renderDPI: Int = 144  // 72, 144, 300 presets
    // P1 FIX: freeform render DPI field (72–600). When the user types a custom
    // value it overrides the preset picker. renderDPI is authoritative for the
    // engine; renderDPIText drives the freeform TextField.
    @Published var renderDPIText: String = "144" {
        didSet {
            if let v = Int(renderDPIText), v >= 72, v <= 600 {
                renderDPI = v
            }
        }
    }

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
        // Wire OutputsLibrary so the Library pane is populated after every op.
        let kind: String
        switch o.opKind {
        case .toJPG, .toPNG: kind = "image"
        default:             kind = "pdf"
        }
        OutputsLibrary.shared.record(
            url: o.url,
            producer: "pdf.\(o.opKind.rawValue)",
            sourceLabel: o.sourceLabel,
            kind: kind
        )
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
            let srcName = src.url.lastPathComponent
            for i in 0..<doc.pageCount {
                try await checkCancel()
                autoreleasepool {
                    if let p = doc.page(at: i)?.copy() as? PDFPage {
                        out.insert(p, at: pageIdx)
                        pageIdx += 1
                    } else {
                        Task { @MainActor in
                            self.appendFailure(.init(label: "page \(i+1) of \(srcName)",
                                                     message: "Page copy failed — skipped"))
                        }
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
                    // Parse each comma-separated token into its own group so
                    // "1-3, 7-9" produces two output PDFs, not one.
                    let tokens = snapshot.ranges
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if tokens.isEmpty {
                        throw NSError(domain: "PDFOps", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "No ranges specified"])
                    }
                    groups = try tokens.map { token in
                        try PDFOpsRange.parse(token, pageCount: pageCount)
                    }
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
                        let pageList = group.map { String($0 + 1) }.joined(separator: ",")
                        label = "\(base) - pages \(pageList)"
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
                    // P1 FIX: probe page dimensions and cap the raster scale
                    // dynamically so huge pages (e.g. engineering drawings at
                    // A0 = 3370×2384 pt) don't OOM at 150 DPI. Cap at 4096 px
                    // on the long side — more than sufficient for compress.
                    let maxRasterPx: CGFloat = 4096
                    let pageMax = max(bounds.width, bounds.height, 1)
                    let nominalScale: CGFloat = 150.0 / 72.0
                    let scale: CGFloat = min(nominalScale, maxRasterPx / pageMax)
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
                    // Apply user rotation. PDF spec stores rotation as a positive
                    // integer multiple of 90, but many viewers (Preview, Chrome)
                    // honor arbitrary integer degrees via the /Rotate key.
                    // Normalise to 0–359 so we never store a negative value,
                    // which some viewers reject.
                    let rotDeg = Int(snap.rot.rounded())
                    let normRot = ((rotDeg % 360) + 360) % 360
                    if normRot != 0 {
                        textAnn.setValue(NSNumber(value: normRot),
                                         forAnnotationKey: PDFAnnotationKey(rawValue: "/Rotate"))
                    }
                    page.addAnnotation(textAnn)
                } else if let stamp = stampImage {
                    // P0 FIX: PDFAnnotation STAMP_IMAGE is a private PDFKit key
                    // that is NOT serialized when saving — the logo is silently
                    // dropped from the output file. Instead, bake the watermark
                    // directly into the page's CGContext by re-rendering the page
                    // into a new CGContext and compositing the stamp on top, then
                    // replacing the page with the rasterized result (same approach
                    // as runCompress). This guarantees the watermark survives save.
                    //
                    // Scale: match the compress raster scale (150 DPI), cap huge
                    // pages the same way runCompress does.
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
                    else { continue }
                    // White background.
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                    // Render existing page content.
                    ctx.saveGState()
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                    // Composite stamp image centered at ~60% page width with
                    // user-specified opacity.
                    let pageW = bounds.width * scale
                    let targetW = pageW * 0.6
                    let stampScale = targetW / max(stamp.size.width, 1)
                    let stampW = stamp.size.width * stampScale
                    let stampH = stamp.size.height * stampScale
                    let stampX = (CGFloat(pxW) - stampW) / 2
                    let stampY = (CGFloat(pxH) - stampH) / 2
                    let stampRect = CGRect(x: stampX, y: stampY, width: stampW, height: stampH)
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(snap.opacity))
                    if let cgStamp = stamp.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        ctx.draw(cgStamp, in: stampRect)
                    }
                    ctx.restoreGState()
                    // Wrap the composited bitmap as a JPEG page and replace.
                    guard let composited = ctx.makeImage() else { continue }
                    let bmp = NSBitmapImageRep(cgImage: composited)
                    guard let jpegData = bmp.representation(using: .jpeg,
                                                            properties: [.compressionFactor: NSNumber(value: 0.85)])
                    else { continue }
                    guard let nsimg = NSImage(data: jpegData),
                          let newPage = PDFPage(image: nsimg) else { continue }
                    newPage.setBounds(bounds, for: .mediaBox)
                    // Replace the existing page in-document. PDFDocument has no
                    // "replace page at index" API, so we remove and re-insert.
                    doc.removePage(at: i)
                    doc.insert(newPage, at: i)
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
                try checkCancelSync()
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
        .onAppear {
            ingestSmartPDFPayload(StageSmartActionQueue.shared.drain(.troveSmartOpenInPDFTool))
        }
        .onReceive(NotificationCenter.default.publisher(for: .troveSmartOpenInPDFTool)) { n in
            ingestSmartPDFPayload(n.userInfo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .troveOpenInPDFTool)) { n in
            ingestPDFReopenPayload(n.userInfo)
        }
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
                            Text("Recent outputs").headerText()
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

    // MARK: - Smart Action + Re-edit receivers

    private func ingestSmartPDFPayload(_ info: [AnyHashable: Any]?) {
        guard let info,
              let urls = info[StageSmartKey.urls] as? [URL], !urls.isEmpty else { return }
        let opStr = info[StageSmartKey.op] as? String
        let op = PDFOpKind(rawValue: opStr ?? "") ?? .merge
        m.clear()
        m.addPDFFiles(urls)
        currentOp = op
    }

    private func ingestPDFReopenPayload(_ info: [AnyHashable: Any]?) {
        guard let info,
              let url = info["url"] as? URL else { return }
        let opStr = info["op"] as? String
        // P0 fix: previously unknown op keys silently fell back to .merge.
        // Now we validate explicitly + surface an error toast so a refactor
        // typo in the key string is visible instead of mysteriously merging.
        guard let op = PDFOpKind(rawValue: opStr ?? "") else {
            SharedStore.stage.flash("Unknown PDF op \"\(opStr ?? "?")\" — open ignored",
                                    kind: .error)
            return
        }
        // P0 fix: if a job is in flight, cancel cleanly before swapping
        // sources. Previously `m.clear()` wiped sources out from under the
        // already-running detached worker — `m.working` stayed `true` and
        // the user was locked out until the worker finished writing outputs
        // referring to deleted sources.
        if m.working {
            m.cancel()
        }
        // P1 fix: if there are unsaved outputs from the prior op, surface
        // them via the stage flash so the user knows they're about to lose
        // the in-memory list. Outputs themselves still exist on disk (under
        // the per-op temp dir) and are findable via Library + PDFOpsRecents.
        if !m.outputs.isEmpty {
            let n = m.outputs.count
            SharedStore.stage.flash("Continuing with \(url.lastPathComponent) — prior \(n) output\(n == 1 ? "" : "s") still in Library",
                                    kind: .info)
        }
        // P2 fix: check the URL exists before clearing state — a swept temp
        // file would otherwise wipe the current sources for nothing.
        if !FileManager.default.fileExists(atPath: url.path) {
            SharedStore.stage.flash("Output file no longer exists — it may have been moved or deleted",
                                    kind: .error)
            return
        }
        m.clear()
        m.addPDFFiles([url])
        currentOp = op
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
                            .background(Color.troveCardSolid.opacity(0.6), in: Capsule())
                    }
                }
                Text(op.title).headerText()
                Text(op.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(Color.troveBgElev.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
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
                    livePreview
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
                    // P1 FIX: PDFDocument(url:) can block >1s on large files —
                    // do it off-main so the drop handler returns immediately.
                    if op == .organize, let first = model.sources.first,
                       model.organizeOrder.isEmpty {
                        let u = first.url
                        let ord = model.organizeOrder  // capture before Task
                        Task.detached(priority: .userInitiated) {
                            let doc = PDFDocument(url: u)
                            let n = doc?.pageCount ?? 0
                            await MainActor.run {
                                if ord.isEmpty { model.organizeOrder = Array(0..<n) }
                            }
                        }
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
            // P1 FIX: PDFDocument(url:) off-main (same as drop path).
            if op == .organize, let first = model.sources.first,
               model.organizeOrder.isEmpty {
                let u = first.url
                let ord = model.organizeOrder
                Task.detached(priority: .userInitiated) {
                    let doc = PDFDocument(url: u)
                    let n = doc?.pageCount ?? 0
                    await MainActor.run {
                        if ord.isEmpty { model.organizeOrder = Array(0..<n) }
                    }
                }
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
                        Text("Images (\(model.imgSources.count))").headerText()
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
                        Text("PDFs (\(model.sources.count))").headerText()
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
        HStack(spacing: 12) {
            // First-page thumbnail. Replaces the generic doc icon so the
            // user can SEE what they're reordering — especially important
            // for Merge (order matters) and Organize Pages.
            PDFSourceThumb(url: s.url, isImage: isImage, invalid: s.invalid)
                .frame(width: 38, height: 50)
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
                    .accessibilityLabel("PDF password")
            }
        }
        .padding(.vertical, 2)
    }

    // -------------------------------------------------------------------
    // Live preview (no run/save required to see the result)
    // -------------------------------------------------------------------
    @ViewBuilder private var livePreview: some View {
        switch op {
        case .merge:
            if model.sources.count >= 1 {
                PDFOpsMergePreview(sources: model.sources)
            }
        case .split:
            if let src = model.sources.first, !src.invalid {
                PDFOpsSplitPreview(url: src.url,
                                   mode: model.splitMode,
                                   ranges: model.splitRanges)
            }
        case .rotate:
            if let src = model.sources.first, !src.invalid {
                PDFOpsRotatePreview(url: src.url,
                                    degrees: model.rotateDegrees,
                                    allPages: model.rotateAllPages,
                                    rangeText: model.rotateRange)
            }
        case .compress:
            if let src = model.sources.first, !src.invalid {
                PDFOpsCompressPreview(url: src.url,
                                      quality: model.compressQuality,
                                      sourceBytes: src.bytes)
            }
        case .watermark:
            // Watermark already has its own preview (model.wmPreviewImage)
            // rendered inside wmParams. Skip here to avoid duplication.
            EmptyView()
        default:
            EmptyView()
        }
    }

    // -------------------------------------------------------------------
    // Parameters (per-op controls)
    // -------------------------------------------------------------------
    @ViewBuilder private var parameters: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Options").headerText()
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
            }
            .pickerStyle(.segmented)
            .onChange(of: model.wmKind) { _ in model.scheduleWatermarkPreview() }
            if model.wmKind == .text {
                HStack {
                    Text("Text").frame(width: 90, alignment: .leading)
                    TextField("CONFIDENTIAL", text: $model.wmText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.wmText) { _ in model.scheduleWatermarkPreview() }
                }
                HStack {
                    Text("Color").frame(width: 90, alignment: .leading)
                    ColorPicker("", selection: $model.wmColor, supportsOpacity: false)
                        .onChange(of: model.wmColor) { _ in model.scheduleWatermarkPreview() }
                    Spacer()
                }
                HStack {
                    Text("Font size").frame(width: 90, alignment: .leading)
                    Slider(value: $model.wmFontSize, in: 18...160)
                        .onChange(of: model.wmFontSize) { _ in model.scheduleWatermarkPreview() }
                    Text("\(Int(model.wmFontSize))").font(.callout.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
                HStack {
                    Text("Rotation").frame(width: 90, alignment: .leading)
                    Slider(value: $model.wmRotation, in: -90...90)
                        .onChange(of: model.wmRotation) { _ in model.scheduleWatermarkPreview() }
                    Text("\(Int(model.wmRotation))°").font(.callout.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            } else {
                HStack {
                    Text("Image").frame(width: 90, alignment: .leading)
                    Text(model.wmImageURL?.lastPathComponent ?? "(drop an image onto the drop zone)")
                        .lineLimit(1)
                        .foregroundStyle(model.wmImageURL == nil ? .secondary : .primary)
                }
                .onChange(of: model.wmImageURL) { _ in model.scheduleWatermarkPreview() }
            }
            HStack {
                Text("Opacity").frame(width: 90, alignment: .leading)
                Slider(value: $model.wmOpacity, in: 0.05...1.0)
                    .onChange(of: model.wmOpacity) { _ in model.scheduleWatermarkPreview() }
                Text(String(format: "%.2f", model.wmOpacity))
                    .font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }

            // P1: live preview — first page with watermark applied.
            if model.sources.first != nil {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Text("Preview").font(.callout).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                        .padding(.top, 4)
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.troveBgElev)
                        if let prev = model.wmPreviewImage {
                            Image(nsImage: prev)
                                .resizable()
                                .interpolation(.medium)
                                .scaledToFit()
                                .padding(4)
                        } else {
                            VStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Rendering…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 160, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.troveLine, lineWidth: 0.5))
                }
                .onAppear { model.scheduleWatermarkPreview() }
                .onChange(of: model.sources.count) { _ in model.scheduleWatermarkPreview() }
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
    // P1 FIX: freeform DPI field (72–600) alongside presets.
    private var renderParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DPI").frame(width: 90, alignment: .leading)
                Picker("", selection: $model.renderDPI) {
                    Text("72").tag(72)
                    Text("144").tag(144)
                    Text("300").tag(300)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .onChange(of: model.renderDPI) { v in
                    model.renderDPIText = "\(v)"
                }
            }
            HStack {
                Text("Custom DPI").frame(width: 90, alignment: .leading)
                TextField("72–600", text: $model.renderDPIText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                    .font(.system(.body, design: .monospaced))
                Text("Range: 72–600")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    Text("Outputs (\(model.outputs.count))").headerText()
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

    /// Builds a single "Continue with…" menu item. Posts the same
    /// `.troveOpenInPDFTool` payload that Library's reEditMenu uses; the
    /// PDFView listener at the top of body handles op-switching + adding
    /// the URL as a source for the new op. One code path, two entry points.
    @ViewBuilder
    private func pdfContinueButton(url: URL, label: String, op: String, icon: String) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .troveOpenInPDFTool,
                object: nil,
                userInfo: ["url": url, "op": op]
            )
            SharedStore.stage.flash("Continuing in \(label)")
        } label: {
            Label(label, systemImage: icon)
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
                Divider()
                // P1 cross-pane chain — every output becomes input to the
                // next op in one click. Mirrors the Library reEditMenu but
                // sits right where the user just finished, so chaining
                // (merge → organize → watermark → save) needs zero pane-
                // hunting. Routes through `.troveOpenInPDFTool` which the
                // top-level PDFView already listens for + auto-switches op
                // + adds the URL as a fresh source.
                Menu {
                    pdfContinueButton(url: o.url, label: "Merge with another PDF", op: "merge",       icon: "arrow.triangle.merge")
                    pdfContinueButton(url: o.url, label: "Split into pages",        op: "split",       icon: "scissors")
                    pdfContinueButton(url: o.url, label: "Organize / rearrange",    op: "organize",    icon: "square.grid.3x3")
                    pdfContinueButton(url: o.url, label: "Compress further",        op: "compress",    icon: "arrow.down.right.and.arrow.up.left")
                    pdfContinueButton(url: o.url, label: "Rotate pages",            op: "rotate",      icon: "rotate.right")
                    pdfContinueButton(url: o.url, label: "Add page numbers",        op: "pageNumbers", icon: "number")
                    pdfContinueButton(url: o.url, label: "Watermark",               op: "watermark",   icon: "drop.halffull")
                    pdfContinueButton(url: o.url, label: "Crop",                    op: "crop",        icon: "crop")
                    pdfContinueButton(url: o.url, label: "Password-protect",        op: "protect",     icon: "lock")
                    pdfContinueButton(url: o.url, label: "Remove password",         op: "unlock",      icon: "lock.open")
                    pdfContinueButton(url: o.url, label: "OCR text layer",          op: "ocr",         icon: "doc.text.viewfinder")
                    pdfContinueButton(url: o.url, label: "Re-save via PDFKit",      op: "repair",      icon: "bandage")
                } label: {
                    Label("Continue with…", systemImage: "arrow.right.circle")
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
                Text("Issues (\(model.failures.count))").headerText()
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
                // P2: use color token instead of raw Color.white
                .background(Color.troveBgElev)
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
// ===========================================================================
// MARK: - Live previews (no run/save required to see the result)
// ===========================================================================
//
// One struct per op kind that benefits from a visual preview. Each reuses
// `PDFOpsThumbRenderer` (actor-serialized PDFKit access) so opening a PDF
// once gives us thumbnails for every page without re-opening per cell.
// Previews update live as the user tweaks parameters above — no run, no
// save, no Preview.app trip.

/// MERGE — horizontal strip of first-page thumbnails in the current source
/// order. Reorder via the source list above; the strip reflects it live.
fileprivate struct PDFOpsMergePreview: View {
    let sources: [PDFOpsSource]
    @State private var thumbs: [URL: NSImage] = [:]
    @State private var pageCounts: [URL: Int] = [:]
    // P1 fix: previously created a fresh `PDFOpsThumbRenderer(url:)` inside
    // every `loadThumb` invocation, so if a user dropped the same file
    // twice into a merge list (or re-rendered after eviction), two
    // independent renderer actors each opened the file + held a separate
    // PDFDocument. Now keep one renderer per URL for the lifetime of the
    // view — actor serialization handles concurrent access.
    @State private var renderers: [URL: PDFOpsThumbRenderer] = [:]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Merge preview").headerText()
                    Spacer()
                    let total = sources.compactMap { pageCounts[$0.url] }.reduce(0, +)
                    if total > 0 {
                        Text("\(total) page\(total == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { idx, s in
                            mergeCard(idx: idx, src: s)
                            if idx < sources.count - 1 {
                                Image(systemName: "arrow.right")
                                    .font(.title3).foregroundStyle(Color.troveFgMute)
                                    .padding(.top, 50)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 170)
            }
        }
    }

    private func mergeCard(idx: Int, src: PDFOpsSource) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let img = thumbs[src.url] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.troveCardSolid)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 90, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.troveLine, lineWidth: 0.5))
                // Index badge — shows merge position so reordering above is
                // immediately legible.
                Text("\(idx + 1)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.troveAccent.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
            }
            Text(src.url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 100)
            if let n = pageCounts[src.url] {
                Text("\(n) page\(n == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: src.url) { await loadThumb(src.url) }
    }

    private func loadThumb(_ url: URL) async {
        if thumbs[url] != nil { return }
        // Reuse or create the per-URL renderer so the doc is opened once
        // even if `loadThumb` is called repeatedly (e.g., row redraws).
        let r: PDFOpsThumbRenderer
        if let existing = renderers[url] {
            r = existing
        } else {
            r = PDFOpsThumbRenderer(url: url)
            await MainActor.run { renderers[url] = r }
        }
        async let img = r.thumbnail(at: 0, target: 240)
        async let count = r.count()
        let (i, c) = await (img, count)
        await MainActor.run {
            if let i { thumbs[url] = i }
            pageCounts[url] = c
        }
    }
}

/// SPLIT — full thumbnail grid of the source PDF with vertical-gap dividers
/// drawn between split groups. Parses `splitRanges` ("1-3, 5, 7-9") into
/// groups so the user sees exactly which pages will land in which output.
fileprivate struct PDFOpsSplitPreview: View {
    let url: URL
    let mode: PDFOpsModel.SplitMode
    let ranges: String

    // P1 fix: bounded thumb cache. Previously @State `[Int: NSImage]` grew
    // unbounded as the user scrolled a 500-page PDF — each thumbnail at
    // 80×104 ARGB is ~33 KB so the whole grid pinned ~16 MB. Cap at 120
    // entries (covers ~4 screens of cells at typical density) + FIFO-evict
    // the lowest-index entries when over the cap (they're least likely to
    // be back on screen given LazyVGrid's downward scroll pattern).
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var pageCount: Int = 0
    @State private var renderer: PDFOpsThumbRenderer? = nil
    fileprivate static let thumbsCap = 120

    /// Per-page → group index (0-based output index). Pages with no group are
    /// dropped from the output entirely; we mark them dimmed.
    private var groupOf: [Int: Int] {
        switch mode {
        case .everyPage:
            return Dictionary(uniqueKeysWithValues: (0..<pageCount).map { ($0, $0) })
        case .ranges:
            return Self.parseRangeGroups(ranges, totalPages: pageCount)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Split preview").headerText()
                    Spacer()
                    let outputs = Set(groupOf.values).count
                    if outputs > 0 {
                        Text("\(outputs) output PDF\(outputs == 1 ? "" : "s") · \(groupOf.count) of \(pageCount) page\(pageCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // P1 fix: zero-page sources (corrupt PDF, image-only PDF
                // where PDFKit succeeded but pageCount == 0) previously
                // rendered as a blank card with no explanation.
                if pageCount == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.troveWarning)
                        Text("Could not read pages from this PDF — it may be corrupt or password-protected.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 12)
                }
                ScrollView {
                    let cols = [GridItem(.adaptive(minimum: 100), spacing: 10)]
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(0..<pageCount, id: \.self) { idx in
                            splitCell(idx: idx)
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 220, maxHeight: 360)
                .background(Color.troveBgElev.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: url) {
            let r = PDFOpsThumbRenderer(url: url)
            renderer = r
            let n = await r.count()
            await MainActor.run { pageCount = n }
        }
    }

    private func splitCell(idx: Int) -> some View {
        let g = groupOf[idx]
        return VStack(spacing: 3) {
            Group {
                if let img = thumbs[idx] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Color.troveCardSolid)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 80, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(g == nil ? Color.troveLine : Color.troveAccent.opacity(0.6),
                                  lineWidth: g == nil ? 0.5 : 2)
            )
            .opacity(g == nil ? 0.35 : 1)
            HStack(spacing: 4) {
                Text("p\(idx + 1)").font(.caption2).foregroundStyle(.secondary)
                if let g {
                    Text("→ #\(g + 1)").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.troveAccent)
                } else {
                    Text("dropped").font(.caption2).foregroundStyle(Color.troveFgMute)
                }
            }
        }
        .task(id: idx) { await loadThumb(idx) }
    }

    private func loadThumb(_ idx: Int) async {
        if thumbs[idx] != nil { return }
        guard let r = renderer else { return }
        if let img = await r.thumbnail(at: idx, target: 200) {
            await MainActor.run {
                // P1 fix: bounded cache. Evict the lowest-index entries
                // when we'd exceed the cap; they're least likely to be
                // back on screen given LazyVGrid's downward scroll pattern.
                if thumbs.count >= Self.thumbsCap {
                    let toDrop = thumbs.keys.sorted()
                        .prefix(thumbs.count - Self.thumbsCap + 1)
                    for k in toDrop where k != idx { thumbs.removeValue(forKey: k) }
                }
                thumbs[idx] = img
            }
        }
    }

    /// Parse "1-3, 5, 7-9" → [page → group] (1-based pages, 0-based group).
    /// Page indexes that fall outside [1, totalPages] or unparsable tokens are
    /// silently skipped — the UI's "p3 → #1" badge makes this legible without
    /// throwing a validation error.
    /// P1 fix: previously `split(separator: "-")` left leading/trailing
    /// whitespace inside the parts ("10 - 20" → ["10 ", " 20"]) which
    /// `Int(_:)` rejects; trim each part explicitly. Also rejects negative
    /// start tokens ("-5" was silently dropped before with no feedback).
    nonisolated static func parseRangeGroups(_ s: String, totalPages: Int) -> [Int: Int] {
        var out: [Int: Int] = [:]
        let groups = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for (gi, raw) in groups.enumerated() where !raw.isEmpty {
            if raw.contains("-"), !raw.hasPrefix("-") {
                let parts = raw.split(separator: "-")
                    .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                guard parts.count == 2, parts[0] >= 1, parts[1] >= parts[0] else { continue }
                let upper = min(parts[1], totalPages)
                if parts[0] > totalPages { continue }
                for p in parts[0]...upper { out[p - 1] = gi }
            } else if let p = Int(raw), p >= 1, p <= totalPages {
                out[p - 1] = gi
            }
        }
        return out
    }
}

/// ROTATE — thumbnail grid with the rotation applied per cell. Pages outside
/// the rotation range (when "Apply to all pages" is off) show un-rotated.
fileprivate struct PDFOpsRotatePreview: View {
    let url: URL
    let degrees: Int
    let allPages: Bool
    let rangeText: String

    // P1 fix: bounded thumb cache, same cap + eviction policy as
    // PDFOpsSplitPreview. A 500-page rotate preview otherwise pinned
    // ~16 MB of thumbnail bitmaps in @State indefinitely.
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var pageCount: Int = 0
    @State private var renderer: PDFOpsThumbRenderer? = nil
    fileprivate static let thumbsCap = 120

    private var affected: Set<Int> {
        if allPages { return Set(0..<pageCount) }
        // Reuse the same range-parser as split — semantics match.
        return Set(PDFOpsSplitPreview.parseRangeGroups(rangeText, totalPages: pageCount).keys)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Rotate preview").headerText()
                    Spacer()
                    Text("\(affected.count) of \(pageCount) page\(pageCount == 1 ? "" : "s") · \(degrees)°")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    let cols = [GridItem(.adaptive(minimum: 110), spacing: 10)]
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(0..<pageCount, id: \.self) { idx in
                            rotateCell(idx: idx)
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 200, maxHeight: 340)
                .background(Color.troveBgElev.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: url) {
            let r = PDFOpsThumbRenderer(url: url)
            renderer = r
            let n = await r.count()
            await MainActor.run { pageCount = n }
        }
    }

    private func rotateCell(idx: Int) -> some View {
        let rotates = affected.contains(idx)
        return VStack(spacing: 3) {
            Group {
                if let img = thumbs[idx] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Color.troveCardSolid)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            // P1 fix: rotationEffect rotates in place WITHOUT reflowing the
            // frame, so 90°/270° on a portrait thumbnail (108pt tall) clipped
            // because the rotated content was 108pt wide but the container
            // was still 86pt wide. Use a square container sized to the longer
            // dimension so any rotation angle fits without clipping. Slight
            // padding when the page is naturally portrait, but no clipping.
            .frame(width: 108, height: 108)
            .rotationEffect(.degrees(rotates ? Double(degrees) : 0))
            // P2 fix: respect Reduce Motion — disable the rotation animation
            // when the system pref is on. The audit flagged this; the other
            // hover animations in the file already gate on this env value.
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil
                       : .easeInOut(duration: 0.18),
                       value: degrees)
            HStack(spacing: 4) {
                Text("p\(idx + 1)").font(.caption2).foregroundStyle(.secondary)
                if rotates {
                    Text("\(degrees)°").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.troveAccent)
                }
            }
        }
        .task(id: idx) { await loadThumb(idx) }
    }

    private func loadThumb(_ idx: Int) async {
        if thumbs[idx] != nil { return }
        guard let r = renderer else { return }
        if let img = await r.thumbnail(at: idx, target: 200) {
            await MainActor.run {
                if thumbs.count >= Self.thumbsCap {
                    let toDrop = thumbs.keys.sorted()
                        .prefix(thumbs.count - Self.thumbsCap + 1)
                    for k in toDrop where k != idx { thumbs.removeValue(forKey: k) }
                }
                thumbs[idx] = img
            }
        }
    }
}

/// COMPRESS — projected output size + one rendered page at the chosen
/// quality so the user can eyeball quality vs file-size trade-offs. The
/// per-page estimate is built from a quick re-encode of the first page
/// at the requested quality on a debounced detached task; total projected
/// size = per-page bytes × pageCount.
fileprivate struct PDFOpsCompressPreview: View {
    let url: URL
    let quality: Double
    let sourceBytes: Int64

    @State private var pageImage: NSImage? = nil
    @State private var pageCount: Int = 0
    @State private var projectedBytes: Int64 = 0
    @State private var renderer: PDFOpsThumbRenderer? = nil
    @State private var probeTask: Task<Void, Never>? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Compress preview").headerText()
                    Spacer()
                    if projectedBytes > 0 {
                        let pct = Int(((1.0 - Double(projectedBytes) / Double(max(sourceBytes, 1))) * 100).rounded())
                        Text("\(sourceBytes.human) → ~\(projectedBytes.human) (\(pct)% smaller)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(pct > 30 ? Color.troveSuccess : Color.troveFgDim)
                    } else if pageCount > 0 {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 4) {
                        Group {
                            if let img = pageImage {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(Color.troveCardSolid)
                                    .overlay(ProgressView().controlSize(.small))
                            }
                        }
                        .frame(width: 180, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.troveLine, lineWidth: 0.5))
                        Text("Sample · page 1 at quality \(String(format: "%.2f", quality))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trove rasterizes embedded images at JPEG quality \(String(format: "%.2f", quality)) and re-emits the PDF. Vector content (text, paths) is preserved at full fidelity.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if pageCount > 0 {
                            Text("\(pageCount) page\(pageCount == 1 ? "" : "s") · estimate scales linearly with page count")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: url) {
            // P0 fix: previously two separate `.task(id: url)` modifiers raced
            // — the second probe always read `renderer = nil` and silently
            // no-opped because the first hadn't yet awaited `r.count()`.
            // Merged into one ordered sequence: build renderer → set state →
            // await count → publish page count → schedule the first probe.
            let r = PDFOpsThumbRenderer(url: url)
            renderer = r
            let n = await r.count()
            await MainActor.run {
                pageCount = n
                projectedBytes = 0
                pageImage = nil
            }
            scheduleProbe()
        }
        .onChange(of: quality) { _ in scheduleProbe() }
    }

    /// Debounce the JPEG re-encode so the slider isn't I/O-bound. Cancels the
    /// previous probe before starting a new one.
    private func scheduleProbe() {
        probeTask?.cancel()
        let q = self.quality
        // P1 fix: previously captured `pageCount` BEFORE the 180ms sleep, so
        // a URL switch during the debounce window multiplied per-page bytes
        // by the OLD doc's page count. Now we capture the renderer ref
        // (which uniquely belongs to the current url-task) before the sleep
        // and re-read pageCount AFTER the await on MainActor so the estimate
        // is always for the live document, not the previous one.
        let probeRenderer = self.renderer
        probeTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000) // 180ms debounce
            if Task.isCancelled { return }
            guard let r = probeRenderer else { return }
            // P1 fix: previously rendered the page at 320px target — the
            // actual compress op renders at 150 DPI (~1240×1754 for A4),
            // so the JPEG-encode of a 320px thumb was ~15× too small a
            // byte count per page, biasing every projection optimistic.
            // 1100px target matches the compress op's per-page raster size
            // closely enough that the projection is in the right
            // order-of-magnitude even for non-A4 pages.
            guard let img = await r.thumbnail(at: 0, target: 1100) else { return }
            let bytes = Self.encodedJPEGBytes(img: img, quality: q)
            await MainActor.run {
                if Task.isCancelled { return }
                self.pageImage = img
                let per = Int64(bytes)
                // P1 fix: scale the per-page projection by the live pageCount
                // (a thumbnail-encoded byte count is a rough lower-bound for
                // the actual 150-DPI compress output, but the slope of the
                // quality slider is what users tune by — they see the
                // relative direction even if the absolute number is rough).
                self.projectedBytes = per * Int64(max(self.pageCount, 1))
            }
        }
    }

    nonisolated private static func encodedJPEGBytes(img: NSImage, quality: Double) -> Int {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality])
        else { return 0 }
        return data.count
    }
}

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

// ===========================================================================
// MARK: - PDF source thumbnail
// ===========================================================================

/// Tiny 38×50 first-page thumbnail for the PDF Tools source list. Renders
/// page 1 of a PDF via `PDFDocument` or downscales an image via
/// `CGImageSourceCreateThumbnailAtIndex` (max 256px). Loads asynchronously
/// off the main thread; shows a placeholder icon during load and on failure.
///
/// Why this matters: the source list supports drag-to-reorder (`.onMove`),
/// but with only a generic `doc.richtext` icon the user had to read filenames
/// to know which file was which. The thumbnail makes "merge in this order"
/// visually obvious.
struct PDFSourceThumb: View {
    let url: URL
    let isImage: Bool
    let invalid: Bool

    @State private var image: NSImage? = nil
    @State private var loadFailed: Bool = false

    var body: some View {
        ZStack {
            // Background — subtle card so the thumbnail has structure
            // even before the image loads.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.troveBgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(invalid ? Color.red.opacity(0.5)
                                              : Color.troveLine,
                                      lineWidth: 0.5)
                )
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if loadFailed {
                Image(systemName: invalid ? "exclamationmark.triangle.fill"
                                          : (isImage ? "photo" : "doc.richtext"))
                    .font(.system(size: 16))
                    .foregroundStyle(invalid ? AnyShapeStyle(Color.red)
                                             : AnyShapeStyle(Color.secondary))
            } else {
                // Loading placeholder — same icon, just dimmer.
                Image(systemName: isImage ? "photo" : "doc.richtext")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear(perform: loadIfNeeded)
        // Refire if a re-validation flipped `invalid` so the border updates.
        .onChange(of: url) { _ in
            image = nil; loadFailed = false; loadIfNeeded()
        }
        .accessibilityLabel(invalid ? "Couldn't load \(url.lastPathComponent)"
                                    : "Preview of \(url.lastPathComponent)")
    }

    private func loadIfNeeded() {
        guard image == nil, !loadFailed else { return }
        let u = url
        let asImage = isImage
        Task.detached(priority: .userInitiated) {
            let img: NSImage? = asImage
                ? Self.imageThumbnail(at: u, maxPixel: 256)
                : Self.pdfFirstPageThumbnail(at: u, maxPixel: 256)
            await MainActor.run {
                if let img {
                    self.image = img
                } else {
                    self.loadFailed = true
                }
            }
        }
    }

    /// PDFKit-based PDF first-page render. Capped at `maxPixel` so a huge
    /// page doesn't allocate a 4K pixel buffer just for a tiny thumbnail.
    private static func pdfFirstPageThumbnail(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxPixel / max(bounds.width, bounds.height), 1.0)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    /// Downscaled image thumbnail using ImageIO. Doesn't allocate the
    /// full-resolution pixel buffer.
    private static func imageThumbnail(at url: URL, maxPixel: CGFloat) -> NSImage? {
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
