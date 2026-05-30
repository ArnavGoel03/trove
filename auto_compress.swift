// auto_compress.swift — auto-compress oversized images dropped into Stage.
//
// Cuts Clop ($14): when a user drops a >2 MB PNG or screenshot into Stage,
// silently re-encode it (best-effort) into a smaller WebP or HEIC variant,
// keeping the original. Show a one-toast "PNG 4.2 MB → WebP 380 KB" hint
// with an Undo action — Clop's hallmark UX.
//
// Wires from `Stage.addFile(_:)` and `Stage.addImage(_:)` via a single call
// at the bottom of each:
//
//     Task.detached { await AutoCompress.shared.maybeCompress(at: url) }
//
// Off-main, idempotent (skips re-compress when the file is already small,
// or already in a small format), opt-in via @AppStorage so users can disable.

import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AutoCompress: ObservableObject {
    static let shared = AutoCompress()

    /// Threshold above which we'll attempt compression. Below = leave alone.
    nonisolated static let thresholdBytes: Int64 = 2_000_000  // 2 MB

    /// Hard upper cap — don't try to compress files >200 MB (rare, but a
    /// recorded video could end up in Stage and we don't want to chew CPU).
    nonisolated static let maxInputBytes: Int64 = 200_000_000

    /// Compression quality (0.0...1.0). 0.78 is the visually-lossless sweet
    /// spot for HEIC/WebP at typical screenshot sizes — the default. Users
    /// who archive photos can push toward 0.95; users who only ever share
    /// screenshots on the web can drop to 0.55 for ~half-size output.
    nonisolated static let defaultQuality: Double = 0.78
    nonisolated static let qualityKey = "trove.stage.autoCompress.quality"
    /// Live-read of the persisted quality, clamped to [0.5, 0.98] so a hand-
    /// edited UserDefaults value can't produce a useless 0.0 (which encodes
    /// pure noise) or 1.0 (which defeats the purpose).
    nonisolated static var quality: Double {
        let raw = UserDefaults.standard.object(forKey: qualityKey) as? Double
            ?? defaultQuality
        return min(0.98, max(0.50, raw))
    }

    /// Persistence key — user can disable via Settings toggle (default ON).
    nonisolated static let prefKey = "trove.stage.autoCompress"

    /// User can disable. Read/written via UserDefaults so the value is visible
    /// from nonisolated contexts (e.g., the off-main compression Task).
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.prefKey) }
    }

    private init() {
        // Default to ON unless the user has explicitly set it to false.
        if UserDefaults.standard.object(forKey: Self.prefKey) == nil {
            self.enabled = true
        } else {
            self.enabled = UserDefaults.standard.bool(forKey: Self.prefKey)
        }
    }

    /// Nonisolated read of the persisted preference. Cheaper than hopping to
    /// MainActor just to read a bool.
    nonisolated static func isEnabled() -> Bool {
        UserDefaults.standard.object(forKey: prefKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: prefKey)
    }

    /// Attempt to produce a smaller variant of `url` alongside it. Returns
    /// the new URL if compression actually shrank the file by ≥30%, else nil.
    /// Called off-main from Stage producers. Side-effects (toast, history)
    /// are dispatched to MainActor at the end.
    nonisolated func maybeCompress(at url: URL) async {
        // Quick gates before doing any work.
        guard Self.isEnabled() else { return }
        guard Self.shouldConsider(url) else { return }

        // P1 fix: skip symlinks / non-regular files. Every other ImageIO call site
        // in the codebase (color, image_tools, pdf) gates on isSymbolicLinkKey +
        // isRegularFileKey before handing the URL to CGImageSourceCreateWithURL —
        // this was the last unguarded entry point. A symlink to /dev/urandom would
        // cause CGImageSourceCreateWithURL to read forever (no EOF).
        let resourceVals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if resourceVals?.isSymbolicLink == true { return }
        if resourceVals?.isRegularFile != true { return }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let originalBytes = (attrs?[.size] as? Int64) ?? 0
        guard originalBytes >= Self.thresholdBytes,
              originalBytes <= Self.maxInputBytes else { return }

        // Decide target format: WebP for screenshots (PNG source), HEIC for
        // JPEG sources. Both produce significantly smaller files at q=0.78.
        let targetUTI: CFString
        let suffix: String
        if url.pathExtension.lowercased() == "png" {
            targetUTI = "org.webmproject.webp" as CFString
            suffix = "webp"
        } else if ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
            targetUTI = UTType.heic.identifier as CFString
            suffix = "heic"
        } else {
            return  // unsupported source format
        }

        let dest = url.deletingPathExtension().appendingPathExtension(suffix)
        // Don't clobber an existing file. Stage producers create per-session
        // names so collisions are rare; still skip cleanly.
        if FileManager.default.fileExists(atPath: dest.path) { return }

        // P0 FIX: probe pixel dimensions BEFORE decoding to cap raster scale
        // and avoid OOM on pathologically large inputs (e.g. 500 MB PNG).
        // Cap at 8192 px on the long side — well above screen resolution;
        // beyond that the compressed output is no smaller anyway.
        let maxPixelSide = 8192
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return }
        var pixelW = 0, pixelH = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            pixelW = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            pixelH = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }
        // If we can't probe dims, bail — safer than a silent OOM.
        guard pixelW > 0, pixelH > 0 else { return }
        let longSide = max(pixelW, pixelH)
        // Use thumbnail decode to cap memory: if the image fits under the cap,
        // CGImageSourceCreateThumbnailAtIndex returns full-res from the cache.
        let decodeSize = min(longSide, maxPixelSide)
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSize,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return }

        // P0 FIX: atomic write — encode to a .tmp sibling, then moveItem into
        // place. The previous code wrote directly to `dest`; a crash mid-encode
        // left a partial file, and the fileExists guard above then permanently
        // blocked future passes on that URL.
        let tmp = dest.deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(suffix)
        guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, targetUTI, 1, nil) else { return }
        let props: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: Self.quality
        ] as CFDictionary
        CGImageDestinationAddImage(out, img, props)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        // Move tmp → dest atomically.
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return
        }

        let newAttrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let newBytes = (newAttrs?[.size] as? Int64) ?? 0
        // Only keep the compressed variant if it's at least 30% smaller —
        // otherwise the perceived quality drop isn't worth it.
        let shrinkRatio = Double(originalBytes - newBytes) / Double(originalBytes)
        guard newBytes > 0, shrinkRatio >= 0.3 else {
            try? FileManager.default.removeItem(at: dest)
            return
        }

        let before = Self.humanBytes(originalBytes)
        let after = Self.humanBytes(newBytes)
        let percent = Int((shrinkRatio * 100).rounded())
        let originalFormat = url.pathExtension.uppercased()
        let newFormat = suffix.uppercased()
        let msg = "Compressed \(originalFormat) \(before) → \(newFormat) \(after) (\(percent)% smaller)"

        await MainActor.run {
            // Fix 6: replace the Stage entry so the user gets the compressed file.
            if let idx = SharedStore.stage.items.firstIndex(where: {
                if case .image(let u) = $0.kind { return u == url }
                if case .file(let u)  = $0.kind { return u == url }
                return false
            }) {
                let original = SharedStore.stage.items[idx]
                let newKind: ItemKind = {
                    switch original.kind {
                    case .image: return .image(dest)
                    case .file:  return .file(dest)
                    case .text(let s): return .text(s)
                    }
                }()
                SharedStore.stage.items[idx] = StagedItem(kind: newKind)
            }
            SharedStore.stage.flash(msg, kind: .success, actionLabel: "Undo") {
                // Undo: restore original URL in Stage, delete compressed sibling.
                if let idx = SharedStore.stage.items.firstIndex(where: {
                    if case .image(let u) = $0.kind { return u == dest }
                    if case .file(let u)  = $0.kind { return u == dest }
                    return false
                }) {
                    let cur = SharedStore.stage.items[idx]
                    let restored: ItemKind = {
                        switch cur.kind {
                        case .image: return .image(url)
                        case .file:  return .file(url)
                        case .text(let s): return .text(s)
                        }
                    }()
                    SharedStore.stage.items[idx] = StagedItem(kind: restored)
                }
                try? FileManager.default.removeItem(at: dest)
            }
        }
    }

    // MARK: - Helpers

    /// Type check — only PNG/JPEG sources are worth compressing. WebP/HEIC/
    /// AVIF inputs are already compact.
    private nonisolated static func shouldConsider(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg"].contains(ext)
    }

    private nonisolated static func humanBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}

// NOTE: AutoCompress is wired live from Stage.addFile/addImage/captureScreenshot
// in main.swift (Task.detached { await AutoCompress.shared.maybeCompress(at: url) }),
// and the Settings toggle is in main.swift's Stage card.

// ---------------------------------------------------------------------------
// MARK: - Quality slider
// ---------------------------------------------------------------------------
// A user-tunable quality knob bound to the same UserDefaults key that
// `AutoCompress.quality` reads non-isolated, so changes apply on the next
// compress without any reactive plumbing. Range [0.50, 0.98]: below 0.5 the
// perceptual quality collapses; above 0.98 there's no real shrink benefit.
struct AutoCompressQualitySlider: View {
    @AppStorage(AutoCompress.qualityKey) private var quality: Double = AutoCompress.defaultQuality
    private let minQ: Double = 0.50
    private let maxQ: Double = 0.98

    private var pct: Int { Int((quality * 100).rounded()) }
    private var label: String {
        switch quality {
        case ..<0.65: return "Aggressive (smaller files)"
        case ..<0.82: return "Balanced (default)"
        default:      return "Conservative (larger files)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Quality")
                    .font(.subheadline)
                Text("· \(label) · \(pct)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Reset") { quality = AutoCompress.defaultQuality }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(abs(quality - AutoCompress.defaultQuality) < 0.005)
            }
            Slider(value: $quality, in: minQ...maxQ, step: 0.01)
                .accessibilityLabel("Auto-compress quality")
                .accessibilityValue("\(pct) percent — \(label)")
        }
        .padding(.top, 2)
    }
}
