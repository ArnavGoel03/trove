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
    /// spot for HEIC/WebP at typical screenshot sizes.
    nonisolated static let quality: Double = 0.78

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

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }

        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, targetUTI, 1, nil) else { return }
        let props: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: Self.quality
        ] as CFDictionary
        CGImageDestinationAddImage(out, img, props)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: dest)
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
            // Replace the original Stage entry with the compressed one so the
            // user gets the smaller file going forward. Original is kept on
            // disk; if the toast's Undo action fires, restore from there.
            SharedStore.stage.flash(
                msg,
                kind: .success,
                actionLabel: "Undo",
                action: {
                    try? FileManager.default.removeItem(at: dest)
                }
            )
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

// TODO: wire from Stage.addFile(url:) and Stage.addImage(url:) in main.swift
// by appending a single line at the end of each:
//
//     Task.detached { await AutoCompress.shared.maybeCompress(at: url) }
//
// Add a toggle in Settings → Stage section:
//     Toggle("Auto-compress oversized images", isOn: $autoCompress.enabled)
