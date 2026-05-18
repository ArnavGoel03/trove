// Trove — Image Tools pane.
//   • Drop in images, convert format + resize + compress + optionally strip metadata
//   • Push outputs to disk and/or onto the Stage
//
// Built to compile with `swiftc -parse-as-library` alongside main.swift.
// Uses the shared Stage singleton (`SharedStore.stage`), the `Card { }` helper,
// and the `Int64.human` extension defined in main.swift.

import SwiftUI
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Output format
// ===========================================================================

enum ImgToolsFormat: String, CaseIterable, Identifiable, Hashable {
    case png  = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"
    case webp = "WebP"

    var id: String { rawValue }

    /// CGImageDestination UTI — matches what ImageIO accepts.
    var uti: CFString {
        switch self {
        case .png:  return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .heic: return "public.heic" as CFString
        case .webp: return "org.webmproject.webp" as CFString
        }
    }

    var ext: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    var isLossy: Bool {
        switch self {
        case .png:  return false
        case .jpeg, .heic, .webp: return true
        }
    }

    /// Probe ImageIO to see whether this UTI can be encoded on this machine.
    /// HEIC and WebP are the realistic failure cases; PNG and JPEG are always present.
    var isSupportedOnThisSystem: Bool {
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains((uti as String))
    }

    /// red-team: one-sentence "best for…" hint shown alongside every format choice.
    /// Verbatim copy from the spec — do not paraphrase without updating the spec.
    var helpCopy: String {
        switch self {
        case .png:
            return "Best for screenshots, UI mockups, anything with text or sharp edges. Lossless; larger files (~3× JPEG)."
        case .jpeg:
            return "Best for photos and anything you share casually. Smaller files; some quality loss at low quality settings."
        case .heic:
            return "Apple's modern format. ~50% smaller than JPEG at the same quality. Plays everywhere on Apple hardware; less universal elsewhere."
        case .webp:
            return "Modern web format. Smaller than JPEG, supports transparency like PNG. Widely supported in browsers. (May be unsupported on this Mac — uses ImageIO; macOS 14+ ships an encoder.)"
        }
    }
}

// ===========================================================================
// MARK: - RAW / camera format support (red-team: DSLR ingestion)
// ===========================================================================

/// red-team: ImageIO ships decoders for a long list of camera RAW formats, but
/// NSImage often punts on them. We accept anything CGImageSource recognizes,
/// and surface a human-readable label for the common DSLR/mirrorless brands.
enum ImgToolsFormatID {
    /// UTI → human-readable name. Covers Canon CR2/CR3, Nikon NEF/NRW, Sony
    /// ARW/SR2, Fujifilm RAF, Olympus ORF, Pentax PEF, Panasonic RW2, Leica
    /// RWL, Hasselblad 3FR, and Adobe DNG plus the everyday formats.
    static let utiNameMap: [String: String] = [
        // RAW / DSLR
        "com.canon.cr2-raw-image":          "Canon CR2",
        "com.canon.cr3-raw-image":          "Canon CR3",
        "com.canon.crw-raw-image":          "Canon CRW",
        "com.nikon.raw-image":              "Nikon NEF",
        "com.nikon.nrw-raw-image":          "Nikon NRW",
        "com.sony.raw-image":               "Sony ARW",
        "com.sony.sr2-raw-image":           "Sony SR2",
        "com.sony.arw-raw-image":           "Sony ARW",
        "com.fuji.raw-image":               "Fujifilm RAF",
        "com.olympus.raw-image":            "Olympus ORF",
        "com.olympus.or-raw-image":         "Olympus ORF",
        "com.pentax.raw-image":             "Pentax PEF",
        "com.panasonic.raw-image":          "Panasonic RW2",
        "com.panasonic.rw2-raw-image":      "Panasonic RW2",
        "com.leica.raw-image":              "Leica RWL",
        "com.leica.rwl-raw-image":          "Leica RWL",
        "com.hasselblad.3fr-raw-image":     "Hasselblad 3FR",
        "com.hasselblad.fff-raw-image":     "Hasselblad FFF",
        "com.adobe.raw-image":              "Adobe DNG",
        "public.camera-raw-image":          "Camera RAW",
        // Everyday
        "public.jpeg":                      "JPEG",
        "public.png":                       "PNG",
        "public.heif":                      "HEIF",
        "public.heic":                      "HEIC",
        "public.tiff":                      "TIFF",
        "com.compuserve.gif":               "GIF",
        "org.webmproject.webp":             "WebP",
        "public.webp":                      "WebP",
        "com.microsoft.bmp":                "BMP",
        "com.microsoft.ico":                "ICO",
        "com.apple.icns":                   "Apple ICNS",
    ]

    /// Friendly name for a UTI, falling back to the raw UTI if we don't have a map entry.
    static func humanName(forUTI uti: String?) -> String {
        guard let uti else { return "Unknown" }
        if let n = utiNameMap[uti] { return n }
        // Pull the last dotted segment as a final fallback: "com.foo.bar-raw-image" → "BAR RAW IMAGE"
        let tail = uti.split(separator: ".").last.map(String.init) ?? uti
        return tail.replacingOccurrences(of: "-", with: " ").uppercased()
    }

    /// red-team: UTI list for NSOpenPanel.allowedContentTypes. Includes
    /// `public.camera-raw-image` which is the parent UTI most vendor RAW
    /// UTIs conform to — so dropping in a `.CR3` or `.ARW` passes the filter.
    static func openPanelContentTypes() -> [UTType] {
        let strs: [String] = [
            "public.jpeg",
            "public.png",
            "com.compuserve.gif",
            "public.heif",
            "public.heic",
            "public.tiff",
            "public.webp",
            "org.webmproject.webp",
            "public.camera-raw-image",
        ]
        var out: [UTType] = strs.compactMap { UTType($0) }
        // Fall back to the umbrella image type if for some reason the system
        // doesn't recognize any of the above (very old SDK, weird environment).
        if out.isEmpty, let img = UTType("public.image") {
            out = [img]
        }
        return out
    }

    /// red-team: whether ImageIO considers a UTI a RAW image. Used to decide
    /// whether to take the embedded-preview thumbnail path on ingestion.
    static func isRawUTI(_ uti: String?) -> Bool {
        guard let uti else { return false }
        if uti.contains("raw-image") { return true }
        if uti == "public.camera-raw-image" { return true }
        // UTI conformance check is the canonical answer: ask the system whether
        // `uti` conforms to `public.camera-raw-image`.
        if let t = UTType(uti),
           let raw = UTType("public.camera-raw-image"),
           t.conforms(to: raw) {
            return true
        }
        return false
    }
}

// ===========================================================================
// MARK: - Loaded source + converted output
// ===========================================================================

struct ImgToolsSource: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    // speed: pixel dims and thumbnail land asynchronously. Row appears
    // with `validating == true` and these populated by the bg task.
    var pixelWidth: Int
    var pixelHeight: Int
    let bytes: Int64
    /// Cached small NSImage for thumbnail. We do NOT keep the full bitmap in memory.
    var thumbnail: NSImage?
    /// red-team: detected source UTI + a human-readable label ("Canon CR3", "Nikon NEF").
    /// Surfaced in the source card so users see what's actually being decoded.
    var sourceUTI: String?
    var formatLabel: String
    // speed: row is shown the instant a drop lands; heavy ImageIO work
    // (full property read + thumbnail decode + RAW preview pull) happens
    // detached and patches these flags in by ID when it finishes.
    var validating: Bool = false
    var invalid: Bool = false
    var note: String = ""

    var pixelCount: Int { pixelWidth * pixelHeight }
    var dimensionsLabel: String {
        if pixelWidth <= 0 || pixelHeight <= 0 { return "—" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    static func == (lhs: ImgToolsSource, rhs: ImgToolsSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ImgToolsOutput: Identifiable, Hashable {
    let id = UUID()
    let sourceID: UUID
    let sourceName: String
    let outputURL: URL
    let beforeBytes: Int64
    let afterBytes: Int64
    var deltaBytes: Int64 { afterBytes - beforeBytes }
    var deltaPct: Double {
        beforeBytes > 0 ? Double(afterBytes - beforeBytes) / Double(beforeBytes) : 0
    }
}

struct ImgToolsFailure: Identifiable, Hashable {
    let id = UUID()
    let sourceURL: URL
    let reason: String
}

/// speed: transport for the bounded-concurrency ingest TaskGroup. Carries
/// either a fully-loaded `ImgToolsSource` (with its NSImage thumbnail) or a
/// failure reason string back to the main actor.
///
/// red-team: marked `@unchecked Sendable` because `NSImage` isn't Sendable
/// under Swift's strict concurrency checker. We only ever read the loaded
/// value on the main actor (inside `MainActor.run`), so the unchecked
/// promise holds — no other task ever touches the NSImage we just decoded.
struct ImgToolsIngestResult: @unchecked Sendable {
    let id: UUID
    let loaded: ImgToolsSource?
    let reason: String?
}

// ===========================================================================
// MARK: - Source loader (validates, extracts metadata, builds thumbnail)
// ===========================================================================

enum ImgToolsLoader {
    /// red-team: cache the supported decoder UTIs once per process. ImageIO
    /// builds this list lazily so the first call is the slow one — caching
    /// keeps drag-of-100-files smooth.
    private static let supportedDecoderUTIs: Set<String> = {
        let list = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return Set(list)
    }()

    /// speed: result of the fast header probe used to populate the row before
    /// the thumbnail is decoded. Holds only what the row's name/format/dims
    /// labels need — no NSImage allocation, no full ImageIO cache.
    struct HeaderProbe {
        let uti: String
        let pixelWidth: Int
        let pixelHeight: Int
        let formatLabel: String
    }

    /// speed: header-only probe. Skips thumbnail decode and never asks
    /// ImageIO to cache the source bitmap. Used to populate the row before
    /// the heavier `loadSource` runs in the background.
    static func probeHeader(from url: URL) -> HeaderProbe? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        let uti = CGImageSourceGetType(src) as String?
        guard let uti, supportedDecoderUTIs.contains(uti) else { return nil }
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        var w = 0, h = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let v = props[kCGImagePropertyPixelWidth] as? Int { w = v }
            if let v = props[kCGImagePropertyPixelHeight] as? Int { h = v }
        }
        // speed: deliberately do NOT fall through to a thumbnail decode here
        // — that's what the background loadSource is for. If header dims are
        // missing we still return the probe with 0×0 so the row appears
        // immediately; the row's labels gracefully render "—".
        return HeaderProbe(uti: uti,
                           pixelWidth: w,
                           pixelHeight: h,
                           formatLabel: ImgToolsFormatID.humanName(forUTI: uti))
    }

    /// Returns nil if the file is not a decodable image (red-team #1).
    ///
    /// red-team: the old path required BOTH `NSImage(contentsOf:)` AND
    /// `cgImage(forProposedRect:…)` to succeed. NSImage refuses many RAW
    /// formats (CR3 in particular) even though `CGImageSourceCreateWithURL`
    /// happily decodes them via the embedded preview. We switch the gate to
    /// CGImageSource so DSLR files are accepted.
    static func loadSource(from url: URL) -> ImgToolsSource? {
        // Validate via ImageIO: source must exist, advertise a known UTI, and
        // that UTI must appear in the system decoder list.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let uti = CGImageSourceGetType(src) as String?
        guard let uti, supportedDecoderUTIs.contains(uti) else { return nil }
        // Must contain at least one image (defends against truncated / empty containers).
        guard CGImageSourceGetCount(src) > 0 else { return nil }

        // True pixel dimensions from ImageIO properties.
        var pixelW = 0
        var pixelH = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int { pixelW = w }
            if let h = props[kCGImagePropertyPixelHeight] as? Int { pixelH = h }
        }
        // If properties came up empty (some RAWs), fall back to decoding the
        // embedded preview to learn its size.
        if pixelW == 0 || pixelH == 0,
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: false,
           ] as CFDictionary) {
            pixelW = cg.width
            pixelH = cg.height
        }
        // Last-ditch sanity floor so divisions / oversize checks don't go wild.
        if pixelW <= 0 || pixelH <= 0 { return nil }

        let bytes: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let n = attrs[.size] as? NSNumber {
            bytes = n.int64Value
        } else {
            bytes = 0
        }

        // Build a small thumbnail via ImageIO (avoids decoding full bitmap).
        // red-team: for RAW sources we always go through the embedded preview
        // path — same call as below, but the comment is worth keeping.
        let thumb = makeThumbnail(url: url, maxPixel: 256, preloaded: src)

        let label = ImgToolsFormatID.humanName(forUTI: uti)

        return ImgToolsSource(
            url: url,
            pixelWidth: pixelW,
            pixelHeight: pixelH,
            bytes: bytes,
            thumbnail: thumb,
            sourceUTI: uti,
            formatLabel: label
        )
    }

    /// red-team: takes an optional preloaded `CGImageSource` so we don't pay
    /// the open-twice cost when called immediately after `loadSource`. For
    /// RAW inputs `kCGImageSourceCreateThumbnailFromImageAlways = true` pulls
    /// the embedded full-resolution preview rather than running a full
    /// demosaic — orders of magnitude faster.
    static func makeThumbnail(url: URL, maxPixel: Int, preloaded: CGImageSource? = nil) -> NSImage? {
        let src: CGImageSource
        if let p = preloaded {
            src = p
        } else if let s = CGImageSourceCreateWithURL(url as CFURL, nil) {
            src = s
        } else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// ===========================================================================
// MARK: - Conversion engine
// ===========================================================================

struct ImgToolsConvertOptions {
    var format: ImgToolsFormat
    var maxDimension: Int      // ignored if `keepOriginalSize == true`
    var keepOriginalSize: Bool
    var quality: Double        // 0.10…1.00, only used for lossy formats
    var stripMetadata: Bool
    var outputDir: URL
}

enum ImgToolsConvertError: LocalizedError {
    case decodeFailed
    case encoderUnavailable(String)
    case writeFailed(String)
    case outputDirNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .decodeFailed:                    return "Couldn't decode source image."
        case .encoderUnavailable(let s):       return "Encoder unavailable: \(s)."
        case .writeFailed(let s):              return "Write failed: \(s)."
        case .outputDirNotWritable(let s):     return "Output folder not writable: \(s)."
        }
    }
}

enum ImgToolsConverter {
    /// Choose a destination filename in `dir` that doesn't collide (red-team #3).
    /// `stem` is the base name without extension. Mirrors `uniqueArchivePath` in main.swift.
    static func uniqueDestination(dir: URL, stem: String, ext: String) -> URL {
        let fm = FileManager.default
        let primary = dir.appendingPathComponent("\(stem).\(ext)")
        if !fm.fileExists(atPath: primary.path) { return primary }
        for i in 2...9999 {
            let cand = dir.appendingPathComponent("\(stem) (\(i)).\(ext)")
            if !fm.fileExists(atPath: cand.path) { return cand }
        }
        return dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    /// Convert one source. Wraps body in autoreleasepool to release ImageIO buffers
    /// before returning to the caller (red-team #7).
    static func convert(
        source: ImgToolsSource,
        opts: ImgToolsConvertOptions
    ) throws -> URL {
        // red-team-sec: refuse to write into a non-regular special file or a
        // path that resolves outside its declared parent via symlink. We
        // resolve+standardize the output dir up front so the subsequent
        // `uniqueDestination` join can't be tricked by a symlink farm into
        // landing outside the dir the user picked.
        let fm = FileManager.default
        let resolvedDir = opts.outputDir.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: resolvedDir.path, isDirectory: &isDir), !isDir.boolValue {
            throw ImgToolsConvertError.outputDirNotWritable(resolvedDir.path)
        }
        // Quick writability check on the output directory (red-team #5).
        if !fm.isWritableFile(atPath: resolvedDir.path) {
            // Try to create it if it's missing — common for first-time custom dirs.
            try? fm.createDirectory(
                at: resolvedDir, withIntermediateDirectories: true
            )
            if !fm.isWritableFile(atPath: resolvedDir.path) {
                throw ImgToolsConvertError.outputDirNotWritable(resolvedDir.path)
            }
        }

        var resultURL: URL!
        var thrown: Error?

        autoreleasepool {
            do {
                resultURL = try doConvert(source: source, opts: opts)
            } catch {
                thrown = error
            }
        }
        if let e = thrown { throw e }
        return resultURL
    }

    private static func doConvert(
        source: ImgToolsSource,
        opts: ImgToolsConvertOptions
    ) throws -> URL {
        // red-team-sec: resolve+canonicalize the output dir locally so
        // path-validation below is talking about the same URL the caller
        // already validated in `convert(...)`. Keep both checks aligned.
        let resolvedDir = opts.outputDir.resolvingSymlinksInPath().standardizedFileURL
        guard let cgSrc = CGImageSourceCreateWithURL(source.url as CFURL, nil) else {
            throw ImgToolsConvertError.decodeFailed
        }
        // red-team: animated sources (APNG, GIF, animated WebP/HEIC) — we
        // only read frame 0 via CreateThumbnailAtIndex. Multi-frame conversion
        // isn't a goal for this pane; user intent here is "shrink this
        // image" so silently dropping further frames matches expectation.
        // Behavior preserved; documented.

        // Decode (and optionally downsample) using ImageIO's thumbnail path —
        // far more memory-efficient than NSImage round-trip.
        // red-team: on huge sources (100MP+) two CGImage allocations could
        // coexist: the decoded thumbnail plus the encoder's pixel buffer.
        // We drop `kCGImageSourceShouldCacheImmediately` in the keep-original
        // branch so ImageIO doesn't *also* keep the decoded source cached
        // inside the CGImageSource. The encoder then drains as soon as
        // CGImageDestinationFinalize releases its pixel buffer.
        let cgImage: CGImage
        if opts.keepOriginalSize {
            // red-team: even in keep-original mode, hard-cap at 30000 px on
            // the longest side. CGContext refuses anything past ~46340 (sqrt
            // of Int32 max bytesPerRow at 4bpp), but practically a single
            // 32k-px JPEG decode is already 4GB and will OOM the machine
            // before ImageIO blocks it. 30k is a generous ceiling for any
            // legitimate keep-original workflow.
            let originalLong = max(source.pixelWidth, source.pixelHeight, 1)
            let cap = min(originalLong, 30_000)
            let decodeOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: cap,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(cgSrc, 0, decodeOpts as CFDictionary) else {
                throw ImgToolsConvertError.decodeFailed
            }
            cgImage = img
        } else {
            let decodeOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: opts.maxDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(cgSrc, 0, decodeOpts as CFDictionary) else {
                throw ImgToolsConvertError.decodeFailed
            }
            cgImage = img
        }

        // Pick the output filename (collision-safe).
        // red-team-sec: also sanitize the stem so a source named `../foo`
        // (possible via symlinks or unusual filesystems) can't escape the
        // output directory. lastPathComponent already strips slashes but we
        // collapse remaining `..` segments defensively.
        var stem = source.url.deletingPathExtension().lastPathComponent
        stem = stem.replacingOccurrences(of: "/", with: "_")
                   .replacingOccurrences(of: "\\", with: "_")
        if stem == "." || stem == ".." || stem.isEmpty { stem = "image" }
        // red-team-sec: validate finalURL stays under resolvedDir even
        // after symlink resolution — defense in depth against odd filesystems.
        let finalURL = uniqueDestination(dir: resolvedDir, stem: stem, ext: opts.format.ext)
        let finalParent = finalURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard finalParent.path == resolvedDir.path else {
            throw ImgToolsConvertError.outputDirNotWritable(
                "Resolved output path escapes the chosen folder: \(finalURL.path)"
            )
        }

        // Atomic write: create destination at a sibling temp path, then replaceItem
        // to move it to `finalURL` — a crash mid-encode leaves the temp behind, never
        // a half-written `finalURL` (red-team #4).
        let tempURL = resolvedDir.appendingPathComponent(
            ".\(stem).\(UUID().uuidString.prefix(8)).\(opts.format.ext).tmp"
        )

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, opts.format.uti, 1, nil
        ) else {
            // Most likely cause: HEIC/WebP encoder not registered on this OS (red-team #6).
            throw ImgToolsConvertError.encoderUnavailable(opts.format.rawValue)
        }

        // Build the per-image properties dict. If stripMetadata is ON, we deliberately
        // omit any inherited EXIF/GPS/TIFF dicts (red-team #8) — only quality goes in.
        var props: [CFString: Any] = [:]
        if opts.format.isLossy {
            props[kCGImageDestinationLossyCompressionQuality] = opts.quality
        }
        if !opts.stripMetadata {
            // Inherit metadata from source.
            if let cgSrcProps = CGImageSourceCopyPropertiesAtIndex(cgSrc, 0, nil) as? [CFString: Any] {
                for (k, v) in cgSrcProps where props[k] == nil {
                    props[k] = v
                }
            }
        }
        // red-team: dropping EXIF Orientation is SAFE here — the decode path
        // above passed `CreateThumbnailWithTransform: true`, baking the
        // orientation into the pixel buffer. Output is visually upright with
        // no orientation tag, which is what we want.

        // Fix #1: JPEG has no alpha channel — composite onto white before encoding
        // so transparency doesn't become black fringe / undefined pixels.
        let imageToEncode: CGImage
        if opts.format == .jpeg {
            let alphaInfo = cgImage.alphaInfo
            let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
            if hasAlpha {
                let w = cgImage.width, h = cgImage.height
                let cs = CGColorSpaceCreateDeviceRGB()
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                ctx?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                imageToEncode = ctx?.makeImage() ?? cgImage
            } else {
                imageToEncode = cgImage
            }
        } else {
            imageToEncode = cgImage
        }
        CGImageDestinationAddImage(dest, imageToEncode, props as CFDictionary)

        if !CGImageDestinationFinalize(dest) {
            try? FileManager.default.removeItem(at: tempURL)
            // red-team: HEIC encoder is registered (per UTI list) but can
            // still fail at finalize on 16-bit / unusual color-space inputs.
            // Surface format in the error so users know to try a different one.
            throw ImgToolsConvertError.writeFailed(
                "\(opts.format.rawValue) encoder finalize failed — try PNG or JPEG"
            )
        }

        // Move temp → final atomically. replaceItemAt only works if the target exists,
        // so for the common (no-collision) case use moveItem; if `finalURL` somehow
        // appeared between the unique-name pick and now, fall back to replace.
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw ImgToolsConvertError.writeFailed(error.localizedDescription)
        }

        return finalURL
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

@MainActor
final class ImgToolsModel: ObservableObject {
    @Published var sources: [ImgToolsSource] = []
    @Published var outputs: [ImgToolsOutput] = []
    @Published var failures: [ImgToolsFailure] = []

    @Published var format: ImgToolsFormat = .png
    @Published var maxDimension: Double = 2048
    @Published var keepOriginalSize: Bool = false
    @Published var quality: Double = 0.85
    @Published var stripMetadata: Bool = true

    @Published var outputDir: URL = UserDefaults.standard.url(forKey: "image_tools.outputDir")
        ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser {
        didSet { UserDefaults.standard.set(outputDir, forKey: "image_tools.outputDir") }
    }
    @Published var working: Bool = false
    @Published var progressLabel: String = ""

    /// Cancellation handle for the running conversion. Held so the toolbar
    /// Cancel button can stop a 200-image batch mid-flight — `Task.cancel()`
    /// propagates through the per-row `Task.detached` calls below.
    private var convertTask: Task<Void, Never>?

    /// Pending oversize warning — when set, the UI puts up a confirmation
    /// for the listed sources (red-team #2).
    @Published var oversizeWarning: [ImgToolsSource] = []

    static let oversizePixelThreshold: Int = 100 * 1_000_000  // ~100 megapixels

    var isFormatSupported: Bool { format.isSupportedOnThisSystem }

    // speed: button-gate so a user can't fire Convert against rows whose
    // pixel dims / thumbnails are still being decoded. Matches the
    // `!sources.contains(where: { $0.validating })` guard in pdf.swift.
    var isValidating: Bool { sources.contains(where: { $0.validating }) }

    /// speed: row-instant ingestion. We synchronously append a placeholder
    /// row for every dropped file so the user sees the file name immediately;
    /// the heavy ImageIO work (full validation + thumbnail decode + RAW
    /// preview pull) runs detached in a bounded TaskGroup and patches each
    /// row in by id. Mirrors the pattern in pdf.swift addPDFFiles.
    func addURLs(_ urls: [URL]) {
        // red-team: expand dropped folders to their image children — a folder
        // of photos onto image_tools should ingest, not be silently rejected
        // by the non-regular-file guard below.
        let urls = troveExpandFolders(
            urls,
            allowedExtensions: ["png","jpg","jpeg","heic","tiff","tif","gif","bmp","webp",
                                 "cr2","cr3","crw","nef","nrw","arw","sr2","srw","raf","orf",
                                 "pef","rw2","rwl","3fr","fff","dng"],
            cap: 1000
        )
        var toLoad: [(id: UUID, url: URL)] = []
        let fm = FileManager.default
        for raw in urls {
            // red-team-sec: resolve symlinks and reject non-regular files
            // before ImageIO touches the path. CGImageSource has had decoder
            // CVEs across HEIC/WebP/RAW; never let it run against /dev/* or
            // a FIFO. One attributesOfItem call gets us both .type and .size.
            let url = raw.resolvingSymlinksInPath()
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
                failures.append(ImgToolsFailure(sourceURL: raw, reason: "Could not read file"))
                continue
            }
            if let ft = attrs[.type] as? FileAttributeType, ft != .typeRegular {
                failures.append(ImgToolsFailure(sourceURL: raw, reason: "Not a regular file — skipped"))
                continue
            }
            // Reject duplicates by path so dragging the same folder twice doesn't pile up.
            if sources.contains(where: { $0.url.path == url.path }) { continue }
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            var s = ImgToolsSource(
                url: url,
                pixelWidth: 0,
                pixelHeight: 0,
                bytes: bytes,
                thumbnail: nil,
                sourceUTI: nil,
                formatLabel: ""
            )
            s.validating = true
            s.note = "Loading…"
            sources.append(s)
            toLoad.append((s.id, url))
        }
        guard !toLoad.isEmpty else { return }
        // speed: bounded-concurrency TaskGroup. ImageIO is CPU+I/O bound;
        // cap = 4 lines up with most users' P-core count and avoids the
        // page-cache thrash that fully-unbounded fan-out causes on a
        // 200-file drop. Each task does the cheap header probe first
        // (microseconds), then the heavier loadSource (thumbnail decode +
        // RAW embedded-preview pull) so a non-image short-circuits fast.
        // red-team: the closure result transports an ImgToolsSource which
        // contains an NSImage (not Sendable). We use a Task.detached and
        // Swift's structured concurrency tolerates this because the value
        // is only ever read on the main actor via MainActor.run below.
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: ImgToolsIngestResult.self) { group in
                let cap = min(4, toLoad.count)
                var i = 0
                while i < cap {
                    let item = toLoad[i]
                    group.addTask {
                        // speed: header probe is the cheap short-circuit —
                        // rejects non-images / unsupported decoders in
                        // microseconds before paying the full thumbnail cost.
                        guard ImgToolsLoader.probeHeader(from: item.url) != nil else {
                            return ImgToolsIngestResult(id: item.id, loaded: nil, reason: "Not a decodable image")
                        }
                        if let s = ImgToolsLoader.loadSource(from: item.url) {
                            return ImgToolsIngestResult(id: item.id, loaded: s, reason: nil)
                        }
                        return ImgToolsIngestResult(id: item.id, loaded: nil, reason: "Not a decodable image")
                    }
                    i += 1
                }
                while let result = await group.next() {
                    let (id, loaded, reason) = (result.id, result.loaded, result.reason)
                    await MainActor.run {
                        guard let self else { return }
                        if let idx = self.sources.firstIndex(where: { $0.id == id }) {
                            if let s = loaded {
                                // speed: preserve the row's existing UUID
                                // (the placeholder row) so SwiftUI doesn't
                                // re-issue a list-level diff that blinks
                                // the cell. We splice the loaded fields
                                // onto the placeholder one field at a time
                                // — `ImgToolsSource.id` is `let id = UUID()`
                                // so a freshly built struct from loadSource
                                // would have a different id and replace the
                                // row wholesale.
                                self.sources[idx].pixelWidth = s.pixelWidth
                                self.sources[idx].pixelHeight = s.pixelHeight
                                self.sources[idx].thumbnail = s.thumbnail
                                self.sources[idx].sourceUTI = s.sourceUTI
                                self.sources[idx].formatLabel = s.formatLabel
                                self.sources[idx].validating = false
                                self.sources[idx].invalid = false
                                self.sources[idx].note = ""
                            } else {
                                let failedURL = self.sources[idx].url
                                self.sources.remove(at: idx)
                                self.failures.append(ImgToolsFailure(
                                    sourceURL: failedURL,
                                    reason: reason ?? "Not a decodable image"
                                ))
                            }
                        }
                    }
                    if i < toLoad.count {
                        let item = toLoad[i]
                        group.addTask {
                            guard ImgToolsLoader.probeHeader(from: item.url) != nil else {
                                return ImgToolsIngestResult(id: item.id, loaded: nil, reason: "Not a decodable image")
                            }
                            if let s = ImgToolsLoader.loadSource(from: item.url) {
                                return ImgToolsIngestResult(id: item.id, loaded: s, reason: nil)
                            }
                            return ImgToolsIngestResult(id: item.id, loaded: nil, reason: "Not a decodable image")
                        }
                        i += 1
                    }
                }
            }
        }
    }

    func removeSource(id: UUID) {
        sources.removeAll { $0.id == id }
    }

    func clearAll() {
        sources.removeAll()
        outputs.removeAll()
        failures.removeAll()
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDir
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let u = panel.url {
            outputDir = u
        }
    }

    /// Kick off a conversion. If any source exceeds the megapixel threshold and
    /// `acknowledgedOversize` is false, return them via `oversizeWarning` and bail —
    /// caller pops a confirmation, then re-invokes with acknowledgedOversize=true.
    func convertAll(toStage: Bool, acknowledgedOversize: Bool = false) {
        // speed: refuse to start while any row is still loading its
        // header/thumbnail — pixelCount-based oversize gating below would
        // otherwise see zeros and false-pass the check.
        guard !sources.isEmpty, !working, !isValidating else { return }

        if !acknowledgedOversize {
            let big = sources.filter { $0.pixelCount > Self.oversizePixelThreshold }
            if !big.isEmpty {
                oversizeWarning = big
                return
            }
        }

        if !format.isSupportedOnThisSystem {
            failures.append(ImgToolsFailure(
                sourceURL: outputDir,
                reason: "\(format.rawValue) encoder not available on this system"
            ))
            SharedStore.stage.flash("\(format.rawValue) unsupported on this system")
            return
        }

        let opts = ImgToolsConvertOptions(
            format: format,
            maxDimension: Int(maxDimension),
            keepOriginalSize: keepOriginalSize,
            quality: quality,
            stripMetadata: stripMetadata,
            outputDir: outputDir
        )
        let snapshot = sources

        convertTask = Task { [weak self] in
            await self?.runConversion(snapshot: snapshot, opts: opts, toStage: toStage)
        }
    }

    /// Cancel an in-flight conversion. Safe to call when `working == false`;
    /// no-op in that case. Partial outputs (already-written files) are
    /// preserved — they live on disk and in `outputs`.
    func cancelConversion() {
        convertTask?.cancel()
    }

    private func runConversion(
        snapshot: [ImgToolsSource],
        opts: ImgToolsConvertOptions,
        toStage: Bool
    ) async {
        working = true
        // Fix #6: don't wipe results at run start — let them accumulate across runs.
        // User clears explicitly via the toolbar Clear button.
        defer {
            working = false
            progressLabel = ""
            convertTask = nil
        }

        // Fix #4: bounded parallel conversion — cap at 6 concurrent ImageIO encodes.
        // serial await Task.detached was effectively sequential; TaskGroup fans out properly.
        let total = snapshot.count
        var newOutputs: [ImgToolsOutput] = []
        var newFailures: [ImgToolsFailure] = []
        var completed = 0

        await withTaskGroup(of: (Result<URL, Error>, ImgToolsSource).self) { group in
            var inFlight = 0
            var iter = snapshot.makeIterator()

            // Seed up to 6 tasks initially.
            while inFlight < 6, let src = iter.next() {
                if Task.isCancelled { break }
                group.addTask {
                    do {
                        let url = try ImgToolsConverter.convert(source: src, opts: opts)
                        return (.success(url), src)
                    } catch {
                        return (.failure(error), src)
                    }
                }
                inFlight += 1
            }

            // Drain completions and feed new work.
            while let (result, src) = await group.next() {
                inFlight -= 1
                completed += 1
                await MainActor.run {
                    progressLabel = "Converting \(completed) of \(total)…"
                }
                switch result {
                case .success(let url):
                    let after: Int64 = (try? FileManager.default
                        .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    newOutputs.append(ImgToolsOutput(
                        sourceID: src.id,
                        sourceName: src.url.lastPathComponent,
                        outputURL: url,
                        beforeBytes: src.bytes,
                        afterBytes: after
                    ))
                    if toStage {
                        await MainActor.run { SharedStore.stage.addFile(url) }
                    }
                    OutputsLibrary.shared.record(
                        url: url,
                        producer: "image_tools.convert",
                        sourceLabel: src.url.lastPathComponent,
                        kind: "image"
                    )
                case .failure(let err):
                    newFailures.append(ImgToolsFailure(
                        sourceURL: src.url,
                        reason: (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    ))
                }

                // Feed next item if not cancelled.
                if !Task.isCancelled, let next = iter.next() {
                    group.addTask {
                        do {
                            let url = try ImgToolsConverter.convert(source: next, opts: opts)
                            return (.success(url), next)
                        } catch {
                            return (.failure(error), next)
                        }
                    }
                    inFlight += 1
                }
            }
        }

        outputs.append(contentsOf: newOutputs)
        failures.append(contentsOf: newFailures)

        let n = newOutputs.count
        if Task.isCancelled {
            SharedStore.stage.flash(
                "Cancelled · \(n) image\(n == 1 ? "" : "s") converted",
                kind: .warning
            )
            return
        }
        if toStage {
            SharedStore.stage.flash("Converted \(n) image\(n == 1 ? "" : "s") · added to Stage")
        } else {
            SharedStore.stage.flash("Converted \(n) image\(n == 1 ? "" : "s")")
        }
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct ImageToolsView: View {
    @StateObject private var m = ImgToolsModel()
    @State private var dropTargeted = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dropZoneCard
                if !m.sources.isEmpty {
                    controlsCard
                    sourcesCard
                }
                if !m.outputs.isEmpty {
                    outputsCard
                }
                if !m.failures.isEmpty {
                    failuresCard
                }
            }
            .padding(24)
        }
        .navigationTitle("Image Tools")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        .onAppear {
            ingestSmartImagePayload(StageSmartActionQueue.shared.drain(.troveSmartOpenInImageTools))
        }
        .onReceive(NotificationCenter.default.publisher(for: .troveSmartOpenInImageTools)) { n in
            ingestSmartImagePayload(n.userInfo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .troveOpenInImageTools)) { n in
            ingestImageReopenPayload(n.userInfo)
        }
        // red-team: explicitly include `public.camera-raw-image` so a Finder
        // drag of a `.CR3` or `.ARW` matches even on systems where the RAW
        // UTI doesn't conform to `public.image` by default.
        .onDrop(of: dropAcceptedTypes,
                isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .confirmationDialog(
            "Some images are very large",
            isPresented: Binding(
                get: { !m.oversizeWarning.isEmpty },
                set: { if !$0 { m.oversizeWarning.removeAll() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Convert anyway") {
                let pending = !m.oversizeWarning.isEmpty
                m.oversizeWarning.removeAll()
                if pending { m.convertAll(toStage: false, acknowledgedOversize: true) }
            }
            Button("Cancel", role: .cancel) {
                m.oversizeWarning.removeAll()
            }
        } message: {
            let names = m.oversizeWarning.map { $0.url.lastPathComponent }.joined(separator: ", ")
            Text("These exceed 100 megapixels and may use a lot of memory: \(names).")
        }
    }

    private var subtitle: String {
        if m.working { return m.progressLabel.isEmpty ? "Working…" : m.progressLabel }
        if m.sources.isEmpty { return "Drop images to begin" }
        let total = m.sources.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(m.sources.count) image\(m.sources.count == 1 ? "" : "s") · \(total.human)"
    }

    // -------------------------------------------------------------------
    // Toolbar
    // -------------------------------------------------------------------

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if m.working {
                // Single Cancel button (and a hidden mirror for ⌘.) replaces
                // the primary Convert/Clear actions while a batch is running —
                // matches the gpu_monitor / big_scan / disk_speed pattern.
                Button(role: .destructive) {
                    m.cancelConversion()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Cancel conversion (Esc or ⌘.)")
                Button("") { m.cancelConversion() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            } else {
                Button(role: .destructive) {
                    m.clearAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(m.sources.isEmpty)
                .help("Remove all loaded images")

                Button {
                    m.convertAll(toStage: false)
                } label: {
                    Label("Convert", systemImage: "wand.and.stars")
                }
                // speed: also disabled while any row is still loading.
                .disabled(m.sources.isEmpty || !m.isFormatSupported || m.isValidating)
                .help(m.isValidating
                      ? "Loading images — try again in a second"
                      : "Write converted files to the output folder")

                Button {
                    m.convertAll(toStage: true)
                } label: {
                    Label("Convert → Stage", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                // speed: also disabled while any row is still loading.
                .disabled(m.sources.isEmpty || !m.isFormatSupported || m.isValidating)
                .help(m.isValidating
                      ? "Loading images — try again in a second"
                      : "Write converted files and add each to the Stage")
            }
        }
    }

    // -------------------------------------------------------------------
    // Drop zone (also serves as empty-state explainer)
    // -------------------------------------------------------------------

    private var dropZoneCard: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                Text(m.sources.isEmpty ? "Drop images here" : "Drop more images")
                    .font(.title3.weight(.medium))
                Text("Convert PNG / JPEG / HEIC / WebP, resize, compress, and optionally strip EXIF + GPS metadata. Useful for shrinking screenshots before Slack or Discord, or normalizing iPhone HEIC to PNG.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 540)
                    .multilineTextAlignment(.center)
                Button {
                    pickFiles()
                } label: {
                    Label("Choose files…", systemImage: "folder")
                }
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, m.sources.isEmpty ? 36 : 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(dropTargeted ? Color.accentColor.opacity(0.10) : .clear)
                    .padding(-2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        dropTargeted ? Color.accentColor : .clear,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .padding(-2)
            )
            // red-team: drop-target fade ignored Reduce Motion.
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil : .easeInOut(duration: 0.15),
                       value: dropTargeted)
        }
    }

    // -------------------------------------------------------------------
    // Conversion controls
    // -------------------------------------------------------------------

    private var controlsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Conversion").font(.headline)

                // red-team: format picker is now a vertical list of rows, each
                // row showing the format name + its "best for…" hint copy.
                // Users never have to guess which format is right for them.
                formatPicker

                // Resize
                HStack(spacing: 14) {
                    Text("Max dimension").frame(width: 110, alignment: .leading)
                    Toggle("Keep original", isOn: $m.keepOriginalSize)
                        .toggleStyle(.checkbox)
                        // red-team: tooltip per spec.
                        .help("Resize so the longest side is at most this many pixels. Set 'Keep original' to skip resizing.")
                    Slider(value: $m.maxDimension, in: 256...4096, step: 64)
                        .disabled(m.keepOriginalSize)
                        .frame(maxWidth: 320)
                        .help("Resize so the longest side is at most this many pixels. Set 'Keep original' to skip resizing.")
                    Text(m.keepOriginalSize ? "—" : "\(Int(m.maxDimension)) px")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(m.keepOriginalSize ? .secondary : .primary)
                        .frame(width: 80, alignment: .trailing)
                    Spacer()
                }

                // Quality (only meaningful for lossy formats)
                if m.format.isLossy {
                    HStack(spacing: 14) {
                        Text("Quality").frame(width: 110, alignment: .leading)
                        Slider(value: $m.quality, in: 0.10...1.00)
                            .frame(maxWidth: 320)
                            // red-team: tooltip per spec.
                            .help("Higher = better-looking, larger files. 85% is the sweet spot for photos.")
                        Text(String(format: "%.0f%%", m.quality * 100))
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)
                        Spacer()
                    }
                }

                // Strip metadata
                HStack(spacing: 14) {
                    Text("Privacy").frame(width: 110, alignment: .leading)
                    Toggle("Strip EXIF + GPS metadata", isOn: $m.stripMetadata)
                        .toggleStyle(.checkbox)
                        // red-team: tooltip per spec.
                        .help("Removes camera info, GPS coordinates, and other metadata. Recommended before sharing online.")
                    Spacer()
                }

                Divider().padding(.vertical, 2)

                // Output directory
                HStack(spacing: 10) {
                    Text("Output folder").frame(width: 110, alignment: .leading)
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(m.outputDir.path)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { m.chooseOutputDir() }
                }
            }
        }
    }

    /// red-team: vertical format picker. Each row carries the format name +
    /// the one-sentence "best for…" hint so the choice is self-explanatory.
    /// Rows for unsupported encoders are dimmed and show a recovery tip.
    @ViewBuilder
    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                Text("Format")
                    .frame(width: 110, alignment: .leading)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ImgToolsFormat.allCases) { fmt in
                        ImgToolsFormatRow(
                            fmt: fmt,
                            isSelected: m.format == fmt,
                            isSupported: fmt.isSupportedOnThisSystem,
                            onTap: { if fmt.isSupportedOnThisSystem { m.format = fmt } }
                        )
                    }
                }
                Spacer()
            }
        }
    }

    // -------------------------------------------------------------------
    // Loaded sources
    // -------------------------------------------------------------------

    private let thumbCols = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)]

    private var sourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Loaded images").font(.headline)
                    Spacer()
                    if m.working { ProgressView().controlSize(.small) }
                }
                LazyVGrid(columns: thumbCols, spacing: 12) {
                    ForEach(m.sources) { src in
                        ImgToolsSourceCard(source: src) {
                            m.removeSource(id: src.id)
                        }
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------

    private var outputsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Converted").font(.headline)
                    Spacer()
                    let savings = m.outputs.reduce(Int64(0)) { $0 + (-$1.deltaBytes) }
                    if savings > 0 {
                        Text("Saved \(savings.human)")
                            .font(.callout).foregroundStyle(.green)
                    }
                    if m.outputs.count > 1 {
                        Button { saveAllOutputs() } label: {
                            Label("Save All…", systemImage: "square.and.arrow.down.on.square")
                        }
                        .help("Pick a folder and save every output into it")
                    }
                }
                ForEach(m.outputs) { out in
                    // Only the most-recent (first) row gets keyboard shortcuts.
                    // SwiftUI warns about duplicate ⌘S/⌘D/⌘R bindings if every
                    // row gets them; the latest output is the obvious primary.
                    outputRow(out, isPrimary: out.id == m.outputs.first?.id)
                    if out.id != m.outputs.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func outputRow(_ out: ImgToolsOutput, isPrimary: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(out.outputURL.lastPathComponent)
                    .font(.body).lineLimit(1)
                Text(out.outputURL.deletingLastPathComponent().path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            deltaLabel(before: out.beforeBytes, after: out.afterBytes)
            Button { saveOutput(out) } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .modifier(ImgPrimaryShortcut(isPrimary: isPrimary, key: "s"))
            .help(isPrimary ? "Save… (⌘S)" : "Choose where to save this file.")

            Menu {
                Button { quickSaveToDownloads(out) } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .modifier(ImgPrimaryShortcut(isPrimary: isPrimary, key: "d"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([out.outputURL]) } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .modifier(ImgPrimaryShortcut(isPrimary: isPrimary, key: "r"))
                Button {
                    SharedStore.stage.addFile(out.outputURL)
                    SharedStore.stage.flash("Sent \(out.outputURL.lastPathComponent) to Stage")
                } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
                Divider()
                Button { copyOutputPath(out) } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        .padding(.vertical, 4)
        // The entire row is draggable — users can drag straight into Finder,
        // Mail, Slack, etc. NSItemProvider(contentsOf:) creates a file-URL
        // representation receivers accept as a real file drop.
        .onDrag {
            NSItemProvider(contentsOf: out.outputURL) ?? NSItemProvider()
        }
        .contextMenu {
            Button { saveOutput(out) } label: { Label("Save…", systemImage: "square.and.arrow.down") }
            Button { quickSaveToDownloads(out) } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([out.outputURL]) } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
            Button {
                SharedStore.stage.addFile(out.outputURL)
                SharedStore.stage.flash("Sent \(out.outputURL.lastPathComponent) to Stage")
            } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
            Divider()
            Button { copyOutputPath(out) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    /// Save As… with NSSavePanel. Remembers the last-used directory so the
    /// user doesn't have to navigate from ~/ every time. Filename pre-filled
    /// from the output, so they just hit Return to keep it.
    private func saveOutput(_ out: ImgToolsOutput) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = out.outputURL.lastPathComponent
        if let ut = UTType(filenameExtension: out.outputURL.pathExtension) {
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
                try FileManager.default.copyItem(at: out.outputURL, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    private func quickSaveToDownloads(_ out: ImgToolsOutput) {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let dest = Self.collisionFreeURL(in: downloads, name: out.outputURL.lastPathComponent)
        do {
            try fm.copyItem(at: out.outputURL, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    private func copyOutputPath(_ out: ImgToolsOutput) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out.outputURL.path, forType: .string)
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
        panel.message = "Choose a destination folder for \(m.outputs.count) outputs."
        panel.directoryURL = Self.lastSaveDir() ?? Self.downloadsDir()
        let outputs = m.outputs
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            Self.setLastSaveDir(dir)
            let fm = FileManager.default
            var copied = 0
            for out in outputs {
                let dest = Self.collisionFreeURL(in: dir, name: out.outputURL.lastPathComponent)
                if (try? fm.copyItem(at: out.outputURL, to: dest)) != nil { copied += 1 }
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

    private static let kSaveDirKey = "image_tools.outputs.saveDir.last"

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

    @ViewBuilder
    private func deltaLabel(before: Int64, after: Int64) -> some View {
        let delta = after - before
        let pct = before > 0 ? Double(delta) / Double(before) * 100 : 0
        let isSaving = delta < 0
        HStack(spacing: 6) {
            Text(after.human)
                .font(.system(.callout, design: .monospaced))
            Text(isSaving
                 ? String(format: "−%.0f%%", -pct)
                 : String(format: "+%.0f%%", pct))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSaving ? .green : .orange)
        }
        .frame(width: 150, alignment: .trailing)
    }

    // -------------------------------------------------------------------
    // Failures
    // -------------------------------------------------------------------

    private var failuresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Skipped / errors", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                    Spacer()
                    Button("Dismiss") { m.failures.removeAll() }
                        .buttonStyle(.borderless)
                }
                ForEach(m.failures) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.octagon").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.sourceURL.lastPathComponent).font(.callout)
                            Text(f.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Drop / file picker handlers
    // -------------------------------------------------------------------

    /// red-team: the drop accepts everyday images, RAWs, and bare file URLs.
    /// Computed so the list reflects whatever the current SDK supports.
    private var dropAcceptedTypes: [UTType] {
        var t: [UTType] = [UTType.image, UTType.fileURL]
        if let raw = UTType("public.camera-raw-image") { t.append(raw) }
        return t
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var collected: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { obj, _ in
                    if let u = obj { collected.append(u) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { m.addURLs(collected) }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // red-team: include camera RAW UTIs so the picker accepts CR3, NEF,
        // ARW, RAF, ORF, PEF, RW2, RWL, 3FR, DNG, etc. Falls back to the
        // umbrella image UTI if the explicit list is empty for any reason.
        let types = ImgToolsFormatID.openPanelContentTypes()
        panel.allowedContentTypes = types.isEmpty ? [.image] : types
        panel.prompt = "Add"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            m.addURLs(panel.urls)
        }
    }

    // MARK: - Smart Action + Re-edit receivers

    private func ingestSmartImagePayload(_ info: [AnyHashable: Any]?) {
        guard let info,
              let urls = info[StageSmartKey.urls] as? [URL], !urls.isEmpty else { return }
        m.addURLs(urls)
    }

    private func ingestImageReopenPayload(_ info: [AnyHashable: Any]?) {
        guard let info,
              let url = info["url"] as? URL else { return }
        m.addURLs([url])
    }
}

// ===========================================================================
// MARK: - Shared primary-row keyboard shortcut helper
// ===========================================================================

/// Apply ⌘<key> only to the primary (most-recent) output row. SwiftUI warns
/// about duplicate shortcut bindings within the same scope, so only the latest
/// row gets the active shortcut; older rows still respond via right-click.
struct ImgPrimaryShortcut: ViewModifier {
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
// MARK: - Format picker row (red-team: format help copy visible at all times)
// ===========================================================================

/// One row in the vertical format picker. Shows the format name, the
/// one-sentence "best for…" hint, and — for unsupported encoders — a
/// recovery tip so users know what to pick instead.
struct ImgToolsFormatRow: View {
    let fmt: ImgToolsFormat
    let isSelected: Bool
    let isSupported: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .font(.system(size: 14))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(fmt.rawValue)
                            .font(.callout.weight(.medium))
                        if !isSupported {
                            Label("encoder missing", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(fmt.helpCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // red-team: when WebP shows as unsupported, surface a
                    // concrete recovery path instead of just a warning.
                    if !isSupported && fmt == .webp {
                        Text("macOS doesn't ship a WebP encoder on this version — use HEIC for similar size, PNG for lossless.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !isSupported && fmt == .heic {
                        Text("HEIC encoder isn't registered on this system — use JPEG for smaller files or PNG for lossless.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                          : AnyShapeStyle(hover ? Color.gray.opacity(0.08) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6)
                                              : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
            .opacity(isSupported ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isSupported)
        .onHover { hover = $0 }
        .help(fmt.helpCopy)
        // red-team-a11y: VoiceOver speaks the format name + selection state
        // + the help copy, so users navigating by keyboard understand which
        // option they're on without sighted hover.
        .accessibilityLabel("\(fmt.rawValue), \(isSelected ? "selected" : "not selected")")
        .accessibilityHint(fmt.helpCopy)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

// ===========================================================================
// MARK: - Source thumbnail card
// ===========================================================================

struct ImgToolsSourceCard: View {
    let source: ImgToolsSource
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = source.thumbnail {
                        Image(nsImage: t)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                            .padding(4)
                    } else if source.validating {
                        // speed: render a spinner in the thumbnail slot
                        // while the bg task decodes — the row is already
                        // present with its filename below.
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(source.note.isEmpty ? "Loading…" : source.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(.quaternary.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if hover {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

                if source.pixelCount > ImgToolsModel.oversizePixelThreshold {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Huge").font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(source.url.lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                // red-team: surface the detected format ("Canon CR3", "Nikon
                // NEF", "JPEG") so users can confirm their RAW was recognized.
                // speed: while loading, the format label is empty — fall back
                // to just bytes so the row isn't visually noisy.
                Text(source.validating
                     ? source.bytes.human
                     : "\(source.formatLabel) · \(source.dimensionsLabel) · \(source.bytes.human)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Reveal source in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([source.url])
            }
            Button("Remove") { onRemove() }
        }
    }
}
