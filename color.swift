// Trove — Color tool pane.
//   • Pick from screen via NSColorSampler (with permission-denial fallback)
//   • Drop/choose an image → median-cut palette extraction (≤6 dominant)
//   • WCAG contrast checker with AA/AAA badges for normal/large/UI
//   • In-memory history (60) with rename, tags, multi-format copy
//
// No network. No third-party deps. Standalone — declares ColorToolView for
// integration in main.swift's navigation switch. Reuses `Card`, `SharedStore.stage.flash`.

import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Model
// ===========================================================================

/// Lightweight color value type. We keep raw RGB (0…1) separately from NSColor
/// because NSColor's color-space conversions are lossy across sRGB/Display-P3
/// and we want stable hex round-tripping.
struct ColorToolValue: Hashable {
    var r: Double  // 0…1, sRGB
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
        self.a = min(1, max(0, a))
    }

    /// Build from an NSColor in any color space — convert to sRGB explicitly.
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(r: Double(c.redComponent),
                  g: Double(c.greenComponent),
                  b: Double(c.blueComponent),
                  a: Double(c.alphaComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
    var swiftUI: Color { Color(nsColor) }

    // -- format strings -----------------------------------------------------
    var hex: String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()),
               Int((g * 255).rounded()),
               Int((b * 255).rounded()))
    }
    var rgbString: String {
        String(format: "rgb(%d, %d, %d)",
               Int((r * 255).rounded()),
               Int((g * 255).rounded()),
               Int((b * 255).rounded()))
    }
    var hslString: String {
        let (h, s, l) = Self.rgbToHSL(r: r, g: g, b: b)
        return String(format: "hsl(%d, %d%%, %d%%)",
                      Int((h * 360).rounded()),
                      Int((s * 100).rounded()),
                      Int((l * 100).rounded()))
    }
    var oklchString: String {
        let (l, c, h) = Self.rgbToOKLCH(r: r, g: g, b: b)
        // red-team: pure white / pure black / pure grays produce chroma ≈ 0
        // but `atan2` of tiny floating-point residuals returns a meaningless
        // hue (anything from 0° to 360°). When chroma is effectively zero,
        // CSS oklch is invariant under hue, so emit hue=0 instead of noise.
        let chromaIsNoise = !c.isFinite || c < 1e-4
        let hueOut: Int = {
            guard !chromaIsNoise, h.isFinite else { return 0 }
            return Int((h * 180 / .pi + 360).truncatingRemainder(dividingBy: 360).rounded())
        }()
        let lightnessOut = max(0, min(1, l.isFinite ? l : 0)) * 100
        let chromaOut = chromaIsNoise ? 0 : c
        return String(format: "oklch(%.1f%% %.3f %d)", lightnessOut, chromaOut, hueOut)
    }
    var swiftUILiteral: String {
        String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)
    }

    /// Relative luminance per WCAG 2.x.
    var relativeLuminance: Double {
        func linearize(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Best-effort text color for legible labels on top of this swatch.
    var legibleForeground: Color {
        relativeLuminance > 0.5 ? .black : .white
    }

    // -- color-space conversion helpers ------------------------------------

    static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    /// sRGB → OKLab → OKLCh. Reference: Björn Ottosson's OKLab paper.
    static func rgbToOKLCH(r: Double, g: Double, b: Double) -> (l: Double, c: Double, h: Double) {
        // sRGB → linear
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let lr = lin(r), lg = lin(g), lb = lin(b)

        let l_ = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
        let m_ = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
        let s_ = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb

        let l = cbrt(l_), m = cbrt(m_), s = cbrt(s_)

        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s

        let chroma = sqrt(a * a + bb * bb)
        let hue = atan2(bb, a)  // radians
        return (L, chroma, hue)
    }

    /// WCAG contrast ratio between two colors. Always ≥ 1.0.
    static func contrastRatio(_ a: ColorToolValue, _ b: ColorToolValue) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        let lighter = max(la, lb), darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// One entry in the pick history. UUID identity so SwiftUI lists are stable
/// when the user renames them.
struct ColorToolHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    var value: ColorToolValue
    var name: String = ""
    var tags: [String] = []
    var capturedAt: Date = Date()
    var source: String = "Picker"  // "Picker", "Image", "Manual"
}

// ===========================================================================
// MARK: - Store
// ===========================================================================

@MainActor
final class ColorToolStore: ObservableObject {
    @Published var history: [ColorToolHistoryEntry] = []
    @Published var palette: [ColorToolValue] = []
    @Published var paletteSourceName: String? = nil
    @Published var paletteError: String? = nil
    @Published var paletteLoading: Bool = false

    /// Red-team #5: defaults so the contrast section never starts on NaN.
    @Published var contrastA: ColorToolValue = ColorToolValue(r: 1, g: 1, b: 1)
    @Published var contrastB: ColorToolValue = ColorToolValue(r: 0, g: 0, b: 0)

    @Published var pickerError: String? = nil

    static let maxHistory = 60

    func record(_ value: ColorToolValue, source: String = "Picker") {
        // Dedup against the most recent identical pick to avoid duplicate spam.
        if let first = history.first,
           first.value == value,
           first.source == source { return }
        history.insert(ColorToolHistoryEntry(value: value, source: source), at: 0)
        if history.count > Self.maxHistory {
            history.removeLast(history.count - Self.maxHistory)
        }
    }

    func remove(_ id: UUID) { history.removeAll { $0.id == id } }
    func clearHistory() { history.removeAll() }

    func rename(_ id: UUID, to newName: String) {
        if let i = history.firstIndex(where: { $0.id == id }) {
            history[i].name = newName
        }
    }

    func addTag(_ id: UUID, _ tag: String) {
        // red-team: users naturally type "red, vibrant" as a single field
        // entry. Split on commas (and trim each part) so the tag list stays
        // clean and doesn't end up with a multi-tag-with-comma blob that
        // breaks later filtering / CSV-style export.
        let parts = tag
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty,
              let i = history.firstIndex(where: { $0.id == id }) else { return }
        for t in parts where !history[i].tags.contains(t) {
            history[i].tags.append(t)
        }
    }
    func removeTag(_ id: UUID, _ tag: String) {
        if let i = history.firstIndex(where: { $0.id == id }) {
            history[i].tags.removeAll { $0 == tag }
        }
    }

    func setPalette(_ p: [ColorToolValue], from sourceName: String) {
        palette = p
        paletteSourceName = sourceName
        paletteError = nil
        for c in p { record(c, source: "Image") }
    }

    func paletteFailed(_ msg: String) {
        palette = []
        paletteSourceName = nil
        paletteError = msg
    }
}

// ===========================================================================
// MARK: - Screen picker
// ===========================================================================

enum ColorToolPicker {
    /// Wrap NSColorSampler. macOS 11+ requires Screen Recording permission
    /// for accurate pixel reads. If denied, the sampler completes with `nil`
    /// — surface that as a one-line notice rather than crashing.
    ///
    /// red-team: NSColorSampler.show's completion is documented as called
    /// on the main thread, but if the user is on a different Space when we
    /// call `.show`, the sampler appears on the *active* Space — the user
    /// then has to switch back manually or click anywhere on the active
    /// Space. We can't fix that from the API (no hook for which Space), but
    /// we activate the app first so the sampler at least targets the front
    /// Space the user is on rather than ours. We also explicitly hop onto
    /// the main queue before invoking the caller so caller code can mutate
    /// `@Published` properties without ceremony.
    static func pick(onResult: @escaping (ColorToolValue?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let sampler = NSColorSampler()
        sampler.show { nsColor in
            let value = nsColor.map { ColorToolValue(nsColor: $0) }
            if Thread.isMainThread {
                onResult(value)
            } else {
                DispatchQueue.main.async { onResult(value) }
            }
        }
    }
}

// ===========================================================================
// MARK: - Palette extraction (median-cut)
// ===========================================================================

enum ColorToolPalette {
    /// Downsample huge images so we don't allocate 240MB+ for a 60MP photo.
    /// We sample to ≤512 on longest side first, then take a 128×128 sample
    /// for the actual median-cut bucketing (plenty of data).
    ///
    /// speed: previously 1024. Median-cut bucketing eventually re-samples
    /// down to 128×128 anyway, so a 512-px ImageIO thumbnail is ~4× cheaper
    /// to decode (esp. on RAW where it pulls the embedded preview path) and
    /// produces an indistinguishable palette. Cap is *max*, not *strict
    /// less than*, so a 512×512 input stays 512×512.
    static let safeMaxDimension: CGFloat = 512
    static let bucketSampleSide: Int = 128

    enum PaletteError: Error {
        case notAnImage
        case decodeFailed
        case emptyPixels
    }

    /// Synchronous; call from a background Task.
    ///
    /// speed: was full-resolution `CGImageSourceCreateImageAtIndex` (decodes
    /// the entire frame into RAM — e.g. ~240MB for a 60MP image, and
    /// triggers a full RAW demosaic). Replaced with the thumbnail path at
    /// `safeMaxDimension`, which (a) pulls the embedded preview for RAW,
    /// (b) decodes 10-20× faster, and (c) is indistinguishable from the
    /// full decode after the 128×128 bucketing step.
    static func extract(from url: URL, count: Int = 6) throws -> [ColorToolValue] {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            throw PaletteError.decodeFailed
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(safeMaxDimension),
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw PaletteError.decodeFailed
        }
        return try extract(from: cg, count: count)
    }

    /// speed: in-memory companion that returns both the palette and an
    /// NSImage preview from a single ImageIO thumbnail decode. Avoids the
    /// disk-write/disk-read round-trip the previous code path forced for
    /// every drop.
    static func extractWithPreview(from url: URL, count: Int = 6,
                                   previewMaxPixel: Int = 256)
        throws -> (palette: [ColorToolValue], preview: NSImage?)
    {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            throw PaletteError.decodeFailed
        }
        let paletteOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(safeMaxDimension),
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let paletteCG = CGImageSourceCreateThumbnailAtIndex(src, 0, paletteOpts as CFDictionary) else {
            throw PaletteError.decodeFailed
        }
        let palette = try extract(from: paletteCG, count: count)
        // speed: derive the UI preview from a smaller thumbnail of the same
        // CGImageSource — second call is cheap, source is already mapped.
        let previewOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        var preview: NSImage? = nil
        if let p = CGImageSourceCreateThumbnailAtIndex(src, 0, previewOpts as CFDictionary) {
            preview = NSImage(cgImage: p, size: NSSize(width: p.width, height: p.height))
        }
        return (palette, preview)
    }

    static func extract(from nsImage: NSImage, count: Int = 6) throws -> [ColorToolValue] {
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw PaletteError.decodeFailed
        }
        return try extract(from: cg, count: count)
    }

    static func extract(from cgImage: CGImage, count: Int) throws -> [ColorToolValue] {
        // red-team: bytesPerRow must equal `width * 4` for our tightly-packed
        // RGBA8 buffer; CGContext is happy to accept this exact alignment
        // (CG aligns at 4-byte boundaries, which 128*4=512 satisfies).
        // Source CGImage may be in P3 / Gray / CMYK — we explicitly draw
        // into an sRGB context so all downstream channel reads are sRGB.
        // We read only into a 128×128 buffer — original CGImage is
        // referenced just long enough to draw the downsample, then released
        // by ARC when the caller's local var goes out of scope.
        let side = bucketSampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw PaletteError.decodeFailed }
        var raw = [UInt8](repeating: 0, count: side * side * 4)
        let bytesPerRow = side * 4
        guard let ctx = CGContext(data: &raw,
                                  width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PaletteError.decodeFailed
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Collect non-transparent pixels.
        var pixels: [(Int, Int, Int)] = []
        pixels.reserveCapacity(side * side)
        for i in stride(from: 0, to: raw.count, by: 4) {
            let a = raw[i + 3]
            if a < 128 { continue }
            pixels.append((Int(raw[i]), Int(raw[i + 1]), Int(raw[i + 2])))
        }
        if pixels.isEmpty { throw PaletteError.emptyPixels }
        return medianCut(pixels: pixels, targetBuckets: max(1, count))
    }

    /// Classic median-cut: recursively split the channel with the largest
    /// range until we have `targetBuckets` buckets, then average each.
    ///
    /// red-team: degenerate inputs — a 1×1 image (or one with a single
    /// non-transparent pixel after thresholding), or an entirely-monochrome
    /// image, both fall through the `bestRange == 0` early-exit and yield a
    /// single-color result. We additionally short-circuit when the caller
    /// already has fewer pixels than buckets requested.
    private static func medianCut(pixels: [(Int, Int, Int)], targetBuckets: Int) -> [ColorToolValue] {
        if pixels.count <= 1 {
            guard let only = pixels.first else { return [] }
            return [ColorToolValue(r: Double(only.0) / 255,
                                   g: Double(only.1) / 255,
                                   b: Double(only.2) / 255)]
        }
        var buckets: [[(Int, Int, Int)]] = [pixels]
        while buckets.count < targetBuckets {
            // Find the bucket with the largest range on any channel.
            var bestIdx = -1
            var bestRange = -1
            var bestChannel = 0
            for (i, b) in buckets.enumerated() {
                guard b.count > 1 else { continue }
                let rs = b.map { $0.0 }, gs = b.map { $0.1 }, bs = b.map { $0.2 }
                let rr = (rs.max() ?? 0) - (rs.min() ?? 0)
                let gr = (gs.max() ?? 0) - (gs.min() ?? 0)
                let br = (bs.max() ?? 0) - (bs.min() ?? 0)
                let (range, ch) = [rr, gr, br].enumerated().max(by: { $0.element < $1.element })
                    .map { ($0.element, $0.offset) } ?? (0, 0)
                if range > bestRange {
                    bestRange = range
                    bestIdx = i
                    bestChannel = ch
                }
            }
            // Red-team #4: black/white image → no further splits possible.
            // We accept fewer than `targetBuckets` rather than emit duplicates.
            if bestIdx < 0 || bestRange == 0 { break }
            var bucket = buckets[bestIdx]
            bucket.sort { a, b in
                let av = bestChannel == 0 ? a.0 : (bestChannel == 1 ? a.1 : a.2)
                let bv = bestChannel == 0 ? b.0 : (bestChannel == 1 ? b.1 : b.2)
                return av < bv
            }
            let mid = bucket.count / 2
            let lo = Array(bucket[..<mid])
            let hi = Array(bucket[mid...])
            buckets.remove(at: bestIdx)
            buckets.append(lo)
            buckets.append(hi)
        }
        let avgs: [ColorToolValue] = buckets.compactMap { b in
            guard !b.isEmpty else { return nil }
            let n = Double(b.count)
            let sr = Double(b.reduce(0) { $0 + $1.0 }) / n / 255
            let sg = Double(b.reduce(0) { $0 + $1.1 }) / n / 255
            let sb = Double(b.reduce(0) { $0 + $1.2 }) / n / 255
            return ColorToolValue(r: sr, g: sg, b: sb)
        }
        // Sort by bucket size desc (most dominant first) via re-pairing.
        let withSizes = zip(buckets, avgs).map { (count: $0.0.count, value: $0.1) }
        return withSizes.sorted { $0.count > $1.count }.map { $0.value }
    }

    /// Downscale-to-disk path. Used when user drops a file — we copy to a
    /// temp file at ≤safeMaxDimension to bound memory, then extract.
    /// Returns the temp URL so callers can keep displaying a preview without
    /// holding the original 60MP frame in memory.
    static func downsampledCopy(of url: URL) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(safeMaxDimension),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-color-\(UUID().uuidString.prefix(8)).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return tmp
    }
}

// ===========================================================================
// MARK: - WCAG badges
// ===========================================================================

enum ColorToolWCAG {
    struct Badge: Identifiable {
        let id = UUID()
        let label: String   // "AA · Normal"
        let threshold: Double
        let passes: Bool
    }

    /// All five canonical WCAG checks. Thresholds:
    ///   • Normal text:           AA 4.5,  AAA 7.0
    ///   • Large text (≥18pt or ≥14pt bold): AA 3.0, AAA 4.5
    ///   • Non-text / UI components: 3.0
    static func badges(for ratio: Double) -> [Badge] {
        [
            Badge(label: "AA · Normal",       threshold: 4.5, passes: ratio >= 4.5),
            Badge(label: "AAA · Normal",      threshold: 7.0, passes: ratio >= 7.0),
            Badge(label: "AA · Large",        threshold: 3.0, passes: ratio >= 3.0),
            Badge(label: "AAA · Large",       threshold: 4.5, passes: ratio >= 4.5),
            Badge(label: "UI · Components",   threshold: 3.0, passes: ratio >= 3.0),
        ]
    }
}

// ===========================================================================
// MARK: - View: top-level pane
// ===========================================================================

public struct ColorToolView: View {
    @StateObject private var store = ColorToolStore()
    @State private var dropTargeted = false
    @State private var dropError: String? = nil
    @State private var lastImagePreview: NSImage? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pickSection
                imageSection
                contrastSection
                historySection
            }
            .padding(24)
        }
        .navigationTitle("Color")
        .navigationSubtitle(subtitle)
        .onAppear {
            ingestSmartColorPayload(StageSmartActionQueue.shared.drain(.troveSmartOpenInColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: .troveSmartOpenInColor)) { n in
            ingestSmartColorPayload(n.userInfo)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Text("Drop image to extract palette")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        // red-team-a11y: drop-target fade ignored Reduce Motion. Drop the
        // implicit overlay animation when the user requested no motion.
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                   ? nil : .easeOut(duration: 0.15),
                   value: dropTargeted)
    }

    private var subtitle: String {
        if let e = store.pickerError { return e }
        if !store.palette.isEmpty, let s = store.paletteSourceName {
            return "Palette from \(s) · \(store.palette.count) color\(store.palette.count == 1 ? "" : "s")"
        }
        if store.history.isEmpty {
            return "Pick from screen, drop an image, or check contrast"
        }
        return "\(store.history.count) in history"
    }

    // -- Section A: pick ----------------------------------------------------

    private var pickSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pick").font(.headline)
                Text("Click the button, then click anywhere on screen with the loupe to sample a pixel. macOS may prompt for **Screen Recording** the first time — accept it for accurate reads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        store.pickerError = nil
                        ColorToolPicker.pick { value in
                            // Red-team #1: hop back to main; nil means cancel/denied.
                            DispatchQueue.main.async {
                                guard let value = value else {
                                    // Fix 20: disambiguate "denied" vs "user cancelled"
                                    // using CGPreflightScreenCaptureAccess.
                                    if CGPreflightScreenCaptureAccess() {
                                        // Access is granted — user simply cancelled the picker.
                                        store.pickerError = nil
                                    } else {
                                        store.pickerError = "denied"
                                    }
                                    return
                                }
                                store.pickerError = nil
                                store.record(value, source: "Picker")
                                SharedStore.stage.flash("Picked \(value.hex)")
                            }
                        }
                    } label: {
                        Label("Pick from screen", systemImage: "eyedropper")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("p", modifiers: [.command])

                    Button {
                        // Pick uses macOS color panel — useful when you want
                        // to dial in a specific value rather than sample one.
                        let panel = NSColorPanel.shared
                        panel.color = .white
                        panel.isContinuous = false
                        panel.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        // No callback hook in NSColorPanel; user can grab from
                        // panel and use "Manual" via contrast pickers below.
                    } label: {
                        Label("Open color panel…", systemImage: "paintpalette")
                    }
                    .controlSize(.large)
                }
                if store.pickerError == "denied" {
                    // Fix 20: render an actionable button instead of a static path string.
                    HStack(spacing: 8) {
                        Label("Screen Recording permission required", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open System Settings") {
                            _ = TCCDeepLink.screenRecording.open()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                    .padding(.top, 2)
                } else if let err = store.pickerError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
        }
    }

    // -- Section B: image → palette -----------------------------------------

    private var imageSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("From image").font(.headline)
                    Spacer()
                    Button {
                        chooseImage()
                    } label: {
                        Label("Choose…", systemImage: "photo")
                    }
                    .disabled(store.paletteLoading)
                }
                Text("Drop an image anywhere in this pane, or click Choose. We extract the 6 most-dominant colors via median-cut bucketing.")
                    .font(.callout).foregroundStyle(.secondary)

                if store.paletteLoading {
                    // speed: include the source filename in the loading row
                    // so the user gets immediate visual confirmation that
                    // the drop landed — same speed-illusion pattern as the
                    // PDF / image_tools panes (row first, work in bg).
                    HStack {
                        ProgressView().controlSize(.small)
                        if let name = store.paletteSourceName {
                            Text("Extracting palette from \(name)…")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Extracting palette…").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                if let err = store.paletteError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                        .padding(.vertical, 4)
                }
                if let dropErr = dropError {
                    Label(dropErr, systemImage: "xmark.octagon.fill")
                        .font(.callout).foregroundStyle(.red)
                        .padding(.vertical, 4)
                }

                if !store.palette.isEmpty {
                    paletteActionsBar
                    HStack(alignment: .top, spacing: 12) {
                        if let preview = lastImagePreview {
                            Image(nsImage: preview)
                                .resizable().interpolation(.medium).scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 10)], alignment: .leading, spacing: 10) {
                                ForEach(Array(store.palette.enumerated()), id: \.offset) { _, c in
                                    ColorToolSwatchCard(value: c) {
                                        store.contrastA = c
                                    }
                                }
                            }
                        }
                    }
                    // Row-level drag — drag the palette CSV straight into
                    // Finder, Mail, Slack, etc. Written to a temp file on
                    // demand so we always reflect the current palette.
                    .onDrag {
                        let url = Self.writePaletteToTempCSV(store.palette,
                                                            sourceName: store.paletteSourceName)
                        return url.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
                            ?? NSItemProvider()
                    }
                    .contextMenu {
                        Button { savePalette() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                        Button { quickSavePaletteToDownloads() } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                        Button { revealPaletteInFinder() } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                        Button { sendPaletteToStage() } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
                        Divider()
                        Button { copyAsCSSHexList() } label: { Label("Copy as CSS hex list", systemImage: "doc.on.doc") }
                        Button { copyAsTailwindHexList() } label: { Label("Copy as Tailwind hex list", systemImage: "doc.on.doc") }
                        Button { copyAsSwiftColorArray() } label: { Label("Copy as Swift Color array", systemImage: "doc.on.doc") }
                    }
                }
            }
        }
        // Drop-target highlight — .onDrop is attached at the view root (so
        // the user can drop anywhere on the pane), but the visible card here
        // gets the tint + dashed border to make the affordance obvious.
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.10) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                   ? nil : .easeInOut(duration: 0.15),
                   value: dropTargeted)
    }

    /// Action bar above the swatch grid: Save…, Save All…, and a More menu
    /// with clipboard copy-as variants. Matches pdf.swift / image_tools.swift.
    @ViewBuilder
    private var paletteActionsBar: some View {
        HStack(spacing: 8) {
            Text("\(store.palette.count) color\(store.palette.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { savePalette() } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save palette as CSV (⌘S).")

            Menu {
                Button { quickSavePaletteToDownloads() } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("d", modifiers: [.command])
                Button { revealPaletteInFinder() } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button { sendPaletteToStage() } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
                Divider()
                Button { copyAsCSSHexList() } label: {
                    Label("Copy as CSS hex list", systemImage: "doc.on.doc")
                }
                Button { copyAsTailwindHexList() } label: {
                    Label("Copy as Tailwind hex list", systemImage: "doc.on.doc")
                }
                Button { copyAsSwiftColorArray() } label: {
                    Label("Copy as Swift Color array", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
    }

    // -- Palette save/export helpers ----------------------------------------

    private func savePalette() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.defaultPaletteFilename(sourceName: store.paletteSourceName)
        if let ut = UTType("public.comma-separated-values-text") {
            panel.allowedContentTypes = [ut]
        } else if let ut = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = Self.lastSaveDir() ?? Self.downloadsDir()
        let palette = store.palette
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            Self.setLastSaveDir(dest.deletingLastPathComponent())
            do {
                let csv = Self.paletteCSV(palette)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try csv.data(using: .utf8)?.write(to: dest, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved palette to \(dest.deletingLastPathComponent().lastPathComponent)")
                OutputsLibrary.shared.record(
                    url: dest,
                    producer: "color.palette",
                    sourceLabel: store.paletteSourceName ?? "Palette",
                    kind: "other"
                )
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    private func quickSavePaletteToDownloads() {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let name = Self.defaultPaletteFilename(sourceName: store.paletteSourceName)
        let dest = Self.collisionFreeURL(in: downloads, name: name)
        do {
            let csv = Self.paletteCSV(store.palette)
            try csv.data(using: .utf8)?.write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved palette to Downloads")
            OutputsLibrary.shared.record(
                url: dest,
                producer: "color.palette",
                sourceLabel: store.paletteSourceName ?? "Palette",
                kind: "other"
            )
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    private func revealPaletteInFinder() {
        guard let url = Self.writePaletteToTempCSV(store.palette,
                                                   sourceName: store.paletteSourceName) else {
            SharedStore.stage.flash("Couldn't write temporary palette CSV")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sendPaletteToStage() {
        guard let url = Self.writePaletteToTempCSV(store.palette,
                                                   sourceName: store.paletteSourceName) else {
            SharedStore.stage.flash("Couldn't write temporary palette CSV")
            return
        }
        SharedStore.stage.addFile(url)
        SharedStore.stage.flash("Sent \(url.lastPathComponent) to Stage")
    }

    private func copyAsCSSHexList() {
        let s = store.palette.map { $0.hex.lowercased() }.joined(separator: "\n")
        Self.copyToPasteboard(s)
        SharedStore.stage.flash("Copied CSS hex list")
    }

    private func copyAsTailwindHexList() {
        // Tailwind config snippet: arbitrary names palette-1…N → hex.
        let lines = store.palette.enumerated().map { idx, c in
            "  'palette-\(idx + 1)': '\(c.hex.lowercased())',"
        }
        let s = "{\n" + lines.joined(separator: "\n") + "\n}"
        Self.copyToPasteboard(s)
        SharedStore.stage.flash("Copied Tailwind hex list")
    }

    private func copyAsSwiftColorArray() {
        let items = store.palette.map { $0.swiftUILiteral }.joined(separator: ",\n    ")
        let s = "let palette: [Color] = [\n    \(items)\n]"
        Self.copyToPasteboard(s)
        SharedStore.stage.flash("Copied Swift Color array")
    }

    // ---- shared save helpers (statics so closures don't capture self) ----

    private static let kSaveDirKey = "color.palette.saveDir.last"

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

    private static func paletteCSV(_ palette: [ColorToolValue]) -> String {
        // One #RRGGBB per line — universally importable by design tools.
        palette.map { $0.hex }.joined(separator: "\n") + "\n"
    }

    private static func defaultPaletteFilename(sourceName: String?) -> String {
        let raw = (sourceName ?? "palette")
        // Strip extension off any source image filename, then sanitize for FS.
        let stem = (raw as NSString).deletingPathExtension
        let safe = stem.replacingOccurrences(of: "/", with: "-")
                       .replacingOccurrences(of: ":", with: "-")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "palette" : safe
        return "\(base).csv"
    }

    /// Write the current palette to a temp file so it can participate in
    /// drag-and-drop / Reveal / Stage flows the same way real file outputs do.
    private static func writePaletteToTempCSV(_ palette: [ColorToolValue],
                                              sourceName: String?) -> URL? {
        guard !palette.isEmpty else { return nil }
        let name = defaultPaletteFilename(sourceName: sourceName)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-color-palettes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        } catch { return nil }
        let url = collisionFreeURL(in: dir, name: name)
        do {
            try paletteCSV(palette).data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    private static func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // -- Section C: contrast ------------------------------------------------

    private var contrastSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Contrast").font(.headline)
                Text("Two colors → WCAG 2.x contrast ratio. AA passes at 4.5:1 (normal text), 3:1 (large/UI). AAA passes at 7:1 (normal), 4.5:1 (large).")
                    .font(.callout).foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    ColorToolWellEditor(title: "Foreground", value: $store.contrastA)
                    Image(systemName: "circle.lefthalf.filled.righthalf.striped.horizontal")
                        .font(.title2).foregroundStyle(.tertiary)
                    ColorToolWellEditor(title: "Background", value: $store.contrastB)
                    Spacer()
                    Button {
                        let t = store.contrastA; store.contrastA = store.contrastB; store.contrastB = t
                    } label: {
                        Label("Swap", systemImage: "arrow.left.arrow.right")
                    }
                    .help("Swap foreground and background")
                }

                ColorToolContrastReadout(a: store.contrastA, b: store.contrastB)
            }
        }
    }

    // -- Section D: history -------------------------------------------------

    private var historySection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("History").font(.headline)
                    Text("(in-memory, up to \(ColorToolStore.maxHistory))")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if !store.history.isEmpty {
                        Button(role: .destructive) { store.clearHistory() } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                if store.history.isEmpty {
                    Text("Pick a color or extract a palette to start logging.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(store.history) { entry in
                            ColorToolHistoryRow(
                                entry: entry,
                                onRename: { store.rename(entry.id, to: $0) },
                                onAddTag: { store.addTag(entry.id, $0) },
                                onRemoveTag: { store.removeTag(entry.id, $0) },
                                onRemove: { store.remove(entry.id) },
                                onUseAsFG: { store.contrastA = entry.value },
                                onUseAsBG: { store.contrastB = entry.value }
                            )
                        }
                    }
                }
            }
        }
    }

    // -- helpers ------------------------------------------------------------

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.resolvesAliases = true   // red-team-sec: resolve Finder aliases up front
        if panel.runModal() == .OK, let u = panel.url {
            // red-team-sec: NSOpenPanel respects allowedContentTypes for the
            // file the user clicks, but the file could still be a symlink
            // pointing anywhere (e.g. /etc/passwd). We're only READING, and
            // CGImageSource will reject non-images, but reject obvious
            // non-regular files (devices, sockets, FIFOs) explicitly so we
            // don't block on /dev/random.
            let resolved = u.resolvingSymlinksInPath()
            if let vals = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
               vals.isRegularFile != true {
                store.paletteFailed("Selected item isn't a regular file — skipped.")
                return
            }
            loadPalette(from: resolved)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        dropError = nil
        // Red-team #3: reject non-image files cleanly.
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let u = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        let isImage = (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
                        if !isImage {
                            dropError = "“\(u.lastPathComponent)” isn't an image — skipped."
                            return
                        }
                        loadPalette(from: u)
                    }
                }
                return
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async { loadPalette(from: img) }
                }
                return
            }
        }
        dropError = "Drop must be an image file."
    }

    private func loadPalette(from url: URL) {
        // red-team-sec: resolve symlinks + reject non-regular files BEFORE
        // any ImageIO call touches the path. Mirror of the chooseImage()
        // guard; the drop handler hits this path too. CGImageSource decoder
        // CVEs (HEIC, WebP, various RAW) shouldn't be reachable via a
        // symlink to /dev/random or a FIFO.
        let resolved = url.resolvingSymlinksInPath()
        if let vals = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
           vals.isRegularFile != true {
            store.paletteFailed("Selected item isn't a regular file — skipped.")
            return
        }
        // speed: the row appears instantly — set the source name and the
        // loading flag synchronously so the user sees "Extracting palette
        // from <name>…" the moment they drop. Heavy decode runs detached.
        let displayName = resolved.lastPathComponent
        store.paletteLoading = true
        store.paletteError = nil
        store.paletteSourceName = displayName
        Task.detached(priority: .userInitiated) {
            // speed: single in-memory thumbnail decode at safeMaxDimension
            // (was 1024 → now 512) + an inline 256-px preview. Replaces the
            // previous disk-hop downsampledCopy → PNG → re-read pipeline,
            // which both wrote to /var/folders/ and forced two ImageIO
            // passes. RAW files hit the embedded-preview path automatically.
            do {
                let result = try ColorToolPalette.extractWithPreview(from: resolved, count: 6)
                await MainActor.run {
                    store.paletteLoading = false
                    lastImagePreview = result.preview
                    if result.palette.isEmpty {
                        store.paletteFailed("No colors extracted (image had no opaque pixels).")
                    } else {
                        store.setPalette(result.palette, from: displayName)
                    }
                }
            } catch {
                await MainActor.run {
                    store.paletteLoading = false
                    store.paletteFailed("Couldn't read \(displayName) — \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadPalette(from img: NSImage) {
        // speed: row appears instantly — show the loading state with a
        // generic source name before the detached extraction starts.
        store.paletteLoading = true
        store.paletteError = nil
        store.paletteSourceName = "dropped image"
        // red-team: previous version wrote a PNG to /var/folders/ on every
        // drop and never cleaned it up — orphaned temp files leak every drop.
        // Decode directly via tiffRepresentation → CGImage (no disk hop).
        Task.detached(priority: .userInitiated) {
            var rect = CGRect(origin: .zero, size: img.size)
            // red-team: very small or zero-sized NSImage (degenerate drag of a
            // 1×1 PDF or empty preview) — guard before cgImage to avoid a
            // nil-CG decode crash deep in CoreGraphics.
            guard rect.width >= 1, rect.height >= 1,
                  let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                await MainActor.run {
                    store.paletteLoading = false
                    store.paletteFailed("Dropped image couldn't be decoded.")
                }
                return
            }
            do {
                let palette = try ColorToolPalette.extract(from: cg, count: 6)
                await MainActor.run {
                    store.paletteLoading = false
                    // Cap preview thumbnail at a reasonable display size so
                    // a 60MP drop doesn't bloat the view.
                    let previewSize = NSSize(
                        width: min(img.size.width, 256),
                        height: min(img.size.height, 256)
                    )
                    let preview = NSImage(size: previewSize)
                    preview.lockFocus()
                    img.draw(in: NSRect(origin: .zero, size: previewSize))
                    preview.unlockFocus()
                    lastImagePreview = preview
                    if palette.isEmpty {
                        store.paletteFailed("No colors extracted.")
                    } else {
                        store.setPalette(palette, from: "dropped image")
                    }
                }
            } catch {
                await MainActor.run {
                    store.paletteLoading = false
                    store.paletteFailed("Couldn't process dropped image — \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Smart Action receiver

    private func ingestSmartColorPayload(_ info: [AnyHashable: Any]?) {
        guard let info,
              let urls = info[StageSmartKey.urls] as? [URL],
              let url = urls.first else { return }
        loadPalette(from: url)
    }
}

// ===========================================================================
// MARK: - Sub-views
// ===========================================================================

/// Compact swatch with stacked format pills + click-to-copy on each.
struct ColorToolSwatchCard: View {
    let value: ColorToolValue
    var onUseInContrast: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(value.swiftUI)
                    .frame(height: 64)
                Text(value.hex)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
            VStack(spacing: 4) {
                ColorToolCopyPill(label: "HEX",   payload: value.hex)
                ColorToolCopyPill(label: "RGB",   payload: value.rgbString)
                ColorToolCopyPill(label: "HSL",   payload: value.hslString)
                ColorToolCopyPill(label: "OKLCH", payload: value.oklchString)
                ColorToolCopyPill(label: "SwiftUI", payload: value.swiftUILiteral)
            }
            .padding(8)
        }
        .background(Color.troveCardSolid.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .contextMenu {
            if let onUseInContrast = onUseInContrast {
                Button("Use as foreground in contrast") { onUseInContrast() }
            }
        }
    }
}

struct ColorToolCopyPill: View {
    let label: String
    let payload: String
    @State private var copied: Bool = false

    var body: some View {
        Button {
            // red-team-sec: color hex/rgb/oklch payloads are non-sensitive,
            // but clearing the pasteboard first prevents any accidental retain
            // of a previous sensitive payload by clipboard managers that
            // dedupe by `.lastChangeCount` alone.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
            SharedStore.stage.flash("Copied \(label): \(payload)")
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .frame(width: 52, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(payload)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.troveBgElev.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Copy \(label): \(payload)")
        // red-team-a11y: VoiceOver reads "Copy HEX FFAABB, button" rather
        // than the truncated payload from the secondary text.
        .accessibilityLabel("Copy \(label) value \(payload)")
        .accessibilityHint("Copies \(payload) to the clipboard")
    }
}

/// One side of the contrast pair: a labelled color well + hex below.
struct ColorToolWellEditor: View {
    let title: String
    @Binding var value: ColorToolValue
    @State private var showPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ColorToolColorWell(value: $value)
                .frame(width: 80, height: 40)
            Text(value.hex)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// NSColorWell wrapper. Avoids SwiftUI's `ColorPicker` (which is fine, but the
/// AppKit well integrates with the floating NSColorPanel better and matches
/// native chrome conventions used elsewhere in Trove).
struct ColorToolColorWell: NSViewRepresentable {
    @Binding var value: ColorToolValue

    func makeCoordinator() -> Coord { Coord(parent: self) }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.color = value.nsColor
        well.target = context.coordinator
        well.action = #selector(Coord.colorChanged(_:))
        return well
    }

    func updateNSView(_ nsView: NSColorWell, context: Context) {
        // red-team: ColorToolValue uses exact `Double` equality, but the
        // round-trip nsView.color → ColorToolValue → nsColor introduces
        // sub-ULP drift in the color-space conversion. Comparing with `!=`
        // can therefore loop forever (SwiftUI: updateNSView → set color →
        // KVO → coordinator → bind → updateNSView). Compare with a small
        // epsilon on each channel instead.
        let current = ColorToolValue(nsColor: nsView.color)
        let eps = 1.0 / 512.0   // ~half a quantization step at 8-bit depth
        let close = abs(current.r - value.r) < eps
                 && abs(current.g - value.g) < eps
                 && abs(current.b - value.b) < eps
                 && abs(current.a - value.a) < eps
        if !close {
            nsView.color = value.nsColor
        }
    }

    final class Coord: NSObject {
        var parent: ColorToolColorWell
        init(parent: ColorToolColorWell) { self.parent = parent }
        @objc func colorChanged(_ sender: NSColorWell) {
            parent.value = ColorToolValue(nsColor: sender.color)
        }
    }
}

/// Big ratio + five WCAG badges, plus a live preview row.
struct ColorToolContrastReadout: View {
    let a: ColorToolValue
    let b: ColorToolValue

    var ratio: Double { ColorToolValue.contrastRatio(a, b) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(String(format: "%.2f:1", ratio))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ratioColor)
                if ratio >= 7 {
                    Text("Excellent — passes everything")
                        .font(.callout).foregroundStyle(.secondary)
                } else if ratio >= 4.5 {
                    Text("Solid for body text")
                        .font(.callout).foregroundStyle(.secondary)
                } else if ratio >= 3 {
                    Text("OK for large text + UI only")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Too low — fails all WCAG checks")
                        .font(.callout).foregroundStyle(.red)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(ColorToolWCAG.badges(for: ratio)) { b in
                    ColorToolBadgeView(badge: b)
                }
            }
            // Preview block — actually shows what the pair looks like.
            HStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(b.swiftUI)
                    VStack(spacing: 4) {
                        Text("Aa  The quick brown fox").font(.title3.weight(.regular)).foregroundStyle(a.swiftUI)
                        Text("Body text on background").font(.callout).foregroundStyle(a.swiftUI)
                        Text("Large 18pt text").font(.title.weight(.semibold)).foregroundStyle(a.swiftUI)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 90)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        }
    }

    private var ratioColor: Color {
        ratio >= 7 ? .green : (ratio >= 4.5 ? .blue : (ratio >= 3 ? .orange : .red))
    }
}

struct ColorToolBadgeView: View {
    let badge: ColorToolWCAG.Badge
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(badge.passes ? Color.green : Color.red)
            Text(badge.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((badge.passes ? Color.green : Color.red).opacity(0.12),
                    in: Capsule())
    }
}

/// History row with rename, tags, copy buttons.
struct ColorToolHistoryRow: View {
    let entry: ColorToolHistoryEntry
    let onRename: (String) -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void
    let onRemove: () -> Void
    let onUseAsFG: () -> Void
    let onUseAsBG: () -> Void

    @State private var editingName: String = ""
    @State private var tagDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(entry.value.swiftUI)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name (e.g. brand primary)",
                              text: Binding(get: { editingName.isEmpty ? entry.name : editingName },
                                            set: { editingName = $0 }))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit {
                        onRename(editingName)
                        editingName = ""
                    }
                    Text(entry.value.hex)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Use as foreground") { onUseAsFG() }
                    Button("Use as background") { onUseAsBG() }
                    Divider()
                    Button("Copy HEX")     { copy(entry.value.hex,           label: "HEX") }
                    Button("Copy RGB")     { copy(entry.value.rgbString,     label: "RGB") }
                    Button("Copy HSL")     { copy(entry.value.hslString,     label: "HSL") }
                    Button("Copy OKLCH")   { copy(entry.value.oklchString,   label: "OKLCH") }
                    Button("Copy SwiftUI") { copy(entry.value.swiftUILiteral, label: "SwiftUI") }
                    Divider()
                    Button(role: .destructive) { onRemove() } label: { Text("Remove") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
            }

            HStack {
                ForEach(entry.tags, id: \.self) { t in
                    HStack(spacing: 3) {
                        Text(t).font(.caption2)
                        Button { onRemoveTag(t) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                TextField("+ tag", text: $tagDraft)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(maxWidth: 80)
                    .onSubmit {
                        onAddTag(tagDraft)
                        tagDraft = ""
                    }
                Spacer()
                Text(entry.source).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.troveCardSolid.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
    }

    private func copy(_ s: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        SharedStore.stage.flash("Copied \(label): \(s)")
    }
}
