// Trove — OCR pane.
//
// Capture a screen region → run Vision text recognition on-device → auto-detect
// the source language → optionally translate via Apple's Translation framework.
// The whole flow lives in one pane: competitors (TextSniper, TRex) make you
// shuttle text to a separate translation app. Local-only; no cloud OCR, no API
// keys, no network calls.
//
// Step-ups vs reference apps:
//   1. One-flow capture → OCR → translate, no app-switching.
//   2. Layout-aware extraction: paragraph breaks reconstructed from bounding-box
//      y-positions so bullet lists and stanzas stay intact.
//   3. Auto-detected source language via NLLanguageRecognizer, with a sensible
//      default target (English unless the system already runs in English).
//   4. History strip of the last 10 OCR captures — re-copy old results without
//      re-shooting your screen.
//   5. Vision revision 3, .accurate level, language correction on.

import SwiftUI
import AppKit
import Vision
import NaturalLanguage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics  // for CGPreflightScreenCaptureAccess (post-capture TCC probe)
#if canImport(Translation)
import Translation
#endif

// ===========================================================================
// MARK: - Recognition pipeline (pure, off main thread)
// ===========================================================================

/// A single recognized line plus the geometry we need to glue paragraphs back
/// together. Vision yields one observation per line; we group them ourselves.
struct OCRLine: Hashable {
    let text: String
    let confidence: Float
    let yCenter: CGFloat        // 0...1, top-of-image space
    let xMin: CGFloat
    let xMax: CGFloat
    let height: CGFloat
    let isRTL: Bool
}

/// Result of recognizing one image: ordered lines, joined paragraph text, and
/// the detected source language (if NLLanguageRecognizer was confident).
struct OCRRecognition: Hashable {
    let lines: [OCRLine]
    let paragraphs: String      // layout-aware, ready to display / copy
    let detectedLanguage: NLLanguage?
    let languageConfidence: Double
    var isEmpty: Bool { lines.isEmpty }
}

// red-team: Vision often emits 0.0 confidence on perfectly correct lines
// (especially short tokens or symbols). A 0.4 cutoff drowns the user in
// false-positive ⚠ markers. Treat *exactly* 0.0 as "unreported" and only
// flag lines whose confidence is positive-but-low.
let ocrLowConfidence: Float = 0.3

enum OCREngine {

    /// Recognize text in `image` using Vision (on-device, revision 3, accurate).
    /// Returns `nil` only on truly catastrophic failure — an image with no text
    /// returns an empty recognition so the caller can show a friendly message
    /// (red-team #2).
    static func recognize(_ image: NSImage) -> OCRRecognition? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        // red-team: zero-pixel inputs (a user dragging a 0×0 selection out of
        // habit, or a corrupted PNG that decoded to an empty bitmap) make
        // Vision return either nil or an empty observations array. Short-
        // circuit so the UI shows the friendly "No text detected" branch
        // instead of looking broken.
        guard cg.width > 0, cg.height > 0 else {
            return OCRRecognition(lines: [], paragraphs: "", detectedLanguage: nil, languageConfidence: 0)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Revision 3 is the latest on macOS 13+ and gives the best multilingual
        // accuracy. Pin explicitly so OS upgrades don't silently change behavior.
        if VNRecognizeTextRequest.supportedRevisions.contains(VNRecognizeTextRequestRevision3) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        // red-team: setting recognitionLanguages to *every* supported language
        // is actively harmful — Vision uses the list as a hint and degrades
        // accuracy when forced to consider unrelated scripts. Leave the
        // property unset so Vision uses its built-in heuristic; we detect the
        // final source language with NLLanguageRecognizer afterwards.
        // (Previously: request.recognitionLanguages = supportedRecognitionLanguages.)

        // red-team: VNImageRequestHandler is single-use, but more importantly
        // VNRecognizeTextRequest is also single-use — reusing one after a
        // .perform leaves stale .results visible. We build a fresh handler
        // here and the request was created locally above, so we're safe; do
        // not hoist either into a property.
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else {
            return OCRRecognition(lines: [], paragraphs: "", detectedLanguage: nil, languageConfidence: 0)
        }

        var lines: [OCRLine] = []
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let s = top.string
            if s.isEmpty { continue }
            // VNRectangleObservation's boundingBox is in normalized image space
            // with origin at the bottom-left. Flip Y so "smaller y" means "higher
            // on the page" — easier mental model for paragraph grouping.
            let bb = obs.boundingBox
            let yCenter = 1 - (bb.minY + bb.height / 2)
            let line = OCRLine(
                text: s,
                confidence: top.confidence,
                yCenter: yCenter,
                xMin: bb.minX,
                xMax: bb.maxX,
                height: bb.height,
                isRTL: scriptIsRTL(s)
            )
            lines.append(line)
        }

        // Vision returns observations in confidence order; we want reading order.
        lines.sort { a, b in
            if abs(a.yCenter - b.yCenter) < 0.005 { return a.xMin < b.xMin }
            return a.yCenter < b.yCenter
        }

        let paragraphs = reconstructParagraphs(lines)
        let (lang, conf) = detectLanguage(paragraphs)
        return OCRRecognition(
            lines: lines,
            paragraphs: paragraphs,
            detectedLanguage: lang,
            languageConfidence: conf
        )
    }

    /// Group lines whose y-centers are within ~1.5× the local line height into
    /// the same paragraph. Bigger gaps become blank lines. Preserves the natural
    /// shape of bullet lists, code blocks, and prose — a step up over the
    /// "join everything with spaces" extraction TextSniper does.
    ///
    /// red-team: on rotated pages, y-gaps don't correspond to reading order so
    /// the threshold heuristic produces garbage paragraph breaks. We detect
    /// the dominant text "angle" by checking how much the line-height varies
    /// vs the x-span — if line-heights span an unusually large range, the
    /// page is probably skewed/rotated and we fall back to a single block.
    private static func reconstructParagraphs(_ lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "" }

        // Rotation heuristic: if observation heights vary wildly (>4×), the
        // page is likely rotated and Vision's boundingBoxes don't share a
        // common "line height" reference — fall back to plain concatenation.
        let heights = lines.map { $0.height }.filter { $0 > 0 }
        if let mn = heights.min(), let mx = heights.max(), mn > 0, mx / mn > 4 {
            return lines.map { $0.text }.joined(separator: "\n")
        }

        var out: [String] = []
        var current: [OCRLine] = [lines[0]]

        for i in 1..<lines.count {
            let prev = lines[i - 1]
            let cur = lines[i]
            let gap = cur.yCenter - prev.yCenter
            // Threshold scaled by the larger of the two line heights so dense
            // 8-pt fine print and wide-spaced 32-pt headers both work.
            let threshold = max(prev.height, cur.height) * 1.5
            if gap > threshold {
                out.append(joinLines(current))
                current = [cur]
            } else {
                current.append(cur)
            }
        }
        out.append(joinLines(current))
        return out.joined(separator: "\n\n")
    }

    private static func joinLines(_ block: [OCRLine]) -> String {
        // red-team: Vision reports 0.0 confidence on many *correct* short
        // tokens. Treat exactly-zero as "no signal" and skip the marker, only
        // flag genuinely-low (positive) confidence.
        block.map { line in
            let unreported = line.confidence == 0
            let lowSignal = !unreported && line.confidence < ocrLowConfidence
            let prefix = lowSignal ? "⚠ " : ""
            return prefix + line.text
        }.joined(separator: "\n")
    }

    /// NLLanguageRecognizer over the joined paragraph text. Returns the top
    /// hypothesis only when its probability is meaningfully above noise.
    private static func detectLanguage(_ text: String) -> (NLLanguage?, Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return (nil, 0) }
        let r = NLLanguageRecognizer()
        r.processString(trimmed)
        guard let lang = r.dominantLanguage else { return (nil, 0) }
        let hypotheses = r.languageHypotheses(withMaximum: 1)
        let conf = hypotheses[lang] ?? 0
        return (lang, conf)
    }

    // speed: thumbnail helper used by both the capture preview load and the
    // history strip. CGImageSourceCreateThumbnailAtIndex with a max-pixel
    // hint decodes only what's needed for display (10-100× faster than
    // NSImage(contentsOf:) for large source PNGs, which lazily-but-fully
    // decodes the entire bitmap on first draw). Always-thumbnail-from-image
    // forces ImageIO to synthesize one even when no embedded thumb exists.
    nonisolated static func fastThumbnail(url: URL, maxPixel: Int) -> NSImage? {
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
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Cheap RTL detector — Vision doesn't tell us, but if the first non-trivial
    /// character of the line is in an RTL script (Arabic, Hebrew, etc.), tag
    /// the line so the UI can render with the right base writing direction.
    private static func scriptIsRTL(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            let v = scalar.value
            // Hebrew, Arabic, Syriac, Thaana, NKo, Arabic Supplement / Extended-A.
            if (0x0590...0x05FF).contains(v) { return true }
            if (0x0600...0x06FF).contains(v) { return true }
            if (0x0700...0x074F).contains(v) { return true }
            if (0x0750...0x077F).contains(v) { return true }
            if (0x0780...0x07BF).contains(v) { return true }
            if (0x07C0...0x07FF).contains(v) { return true }
            if (0x08A0...0x08FF).contains(v) { return true }
            if (0xFB50...0xFDFF).contains(v) { return true }
            if (0xFE70...0xFEFF).contains(v) { return true }
            return false
        }
        return false
    }
}

// ===========================================================================
// MARK: - Target-language picker model
// ===========================================================================

/// Curated short list of common target languages. ISO 639-1 codes match what
/// `Locale.Language(identifier:)` and the Translation framework expect.
struct OCRTargetLanguage: Hashable, Identifiable {
    let code: String
    let label: String
    var id: String { code }
}

enum OCRTargets {
    static let all: [OCRTargetLanguage] = [
        .init(code: "en", label: "English"),
        .init(code: "es", label: "Spanish"),
        .init(code: "fr", label: "French"),
        .init(code: "de", label: "German"),
        .init(code: "ja", label: "Japanese"),
        .init(code: "zh", label: "Chinese"),
        .init(code: "hi", label: "Hindi"),
        .init(code: "ar", label: "Arabic"),
        .init(code: "pt", label: "Portuguese"),
    ]

    /// Default target: English, unless the user is already running an English
    /// system, in which case fall back to Spanish (the next-most-common second
    /// language globally). User can still pick whatever they want.
    static func smartDefault() -> OCRTargetLanguage {
        let sys = Locale.current.language.languageCode?.identifier ?? "en"
        if sys.hasPrefix("en") {
            return all.first { $0.code == "es" } ?? all[0]
        }
        return all[0]
    }

    /// Friendly name for an NLLanguage code, for the "Detected: Spanish" label.
    static func displayName(for nl: NLLanguage?) -> String {
        guard let nl = nl else { return "—" }
        let id = nl.rawValue
        let loc = Locale(identifier: "en_US")
        return loc.localizedString(forLanguageCode: id)?.capitalized ?? id
    }
}

// ===========================================================================
// MARK: - History (in-memory, bounded to 10)
// ===========================================================================

// speed: tiny in-memory thumbnail cache so SwiftUI re-evaluating the history
// strip body (which happens on every state mutation — translation toggle,
// hover, etc.) doesn't re-decode the on-disk PNG every time. Keyed by the
// imageURL path; capacity is intentionally small because history is capped
// at 10. NSCache is thread-safe so the lookup is fine from any actor.
private let ocrThumbCache: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>()
    c.countLimit = 32
    return c
}()

struct OCRHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let imageURL: URL           // on-disk PNG of the original capture
    let recognition: OCRRecognition
    let capturedAt: Date
    // speed: cache-then-fast-thumbnail. Falls through to OCREngine.fastThumbnail
    // (CGImageSourceCreateThumbnailAtIndex at 256 px) on miss — an order of
    // magnitude faster than NSImage(contentsOf:) for full-screen captures.
    var thumb: NSImage? {
        let key = imageURL.path as NSString
        if let cached = ocrThumbCache.object(forKey: key) { return cached }
        guard let img = OCREngine.fastThumbnail(url: imageURL, maxPixel: 256) else { return nil }
        ocrThumbCache.setObject(img, forKey: key)
        return img
    }

    var summary: String {
        let one = recognition.paragraphs.replacingOccurrences(of: "\n", with: " ")
        return one.isEmpty ? "(no text)" : String(one.prefix(80))
    }
}

@MainActor
final class OCRHistoryStore: ObservableObject {
    @Published private(set) var entries: [OCRHistoryEntry] = []
    static let maxEntries = 10

    /// red-team: closure invoked just before a history entry is evicted, so
    /// the view model can clear `capturedURL`/`capturedImage` if the user is
    /// currently viewing it. Without this, the user would see a broken
    /// preview after the tmp PNG is deleted out from under them.
    var willEvict: ((OCRHistoryEntry) -> Void)?

    func add(_ entry: OCRHistoryEntry) {
        entries.insert(entry, at: 0)
        // Bound to 10, delete dropped tmp PNGs so /tmp doesn't grow without
        // bound across a long session.
        while entries.count > Self.maxEntries {
            if let dropped = entries.popLast() {
                willEvict?(dropped)
                // speed: drop the cached thumbnail for the evicted entry so
                // the cache doesn't pin NSImages whose backing files are gone.
                ocrThumbCache.removeObject(forKey: dropped.imageURL.path as NSString)
                try? FileManager.default.removeItem(at: dropped.imageURL)
            }
        }
    }

    func remove(_ id: UUID) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let dropped = entries.remove(at: idx)
            willEvict?(dropped)
            // speed: see comment in add() — purge cache on manual remove too.
            ocrThumbCache.removeObject(forKey: dropped.imageURL.path as NSString)
            try? FileManager.default.removeItem(at: dropped.imageURL)
        }
    }
}

// ===========================================================================
// MARK: - Capture
// ===========================================================================

/// Run macOS `screencapture -i` against a fresh tmp PNG. The system overlay
/// handles region selection. Hide the app so its window doesn't block the
/// area the user wants to OCR, then bring it back afterwards.
///
/// Red-team #1: if the user hits Esc, screencapture exits 0 but never creates
/// the file — detect by checking existence rather than by exit code.
enum OCRCapture {
    /// red-team: across launches, the `trove-ocr` tmp dir accumulates PNGs
    /// from the prior session — history is in-memory only, so the on-disk
    /// images outlive their owners. Sweep anything older than 24h on view
    /// appear; we never reference these from disk except via the in-memory
    /// history (which holds its own URL), so deletion is safe.
    static func sweepStaleTmp() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-ocr", isDirectory: true)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for url in items {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantFuture
            if mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func captureRegion(completion: @escaping (URL?) -> Void) {
        // red-team: serialize with Stage screenshot + Recorder region picker — all
        // three shell out to `screencapture -i` and overlap badly if two fire at
        // once (double crosshair, ambiguous Esc). Caller is on MainActor here
        // because callers are all SwiftUI button actions.
        guard MainActor.assumeIsolated({ InteractiveCaptureGate.tryAcquire() }) else {
            completion(nil)
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-ocr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ocr-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")

        NSApp.hide(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            // red-team: use `executableURL` (modern API since 10.13);
            // `launchPath` was deprecated and emits warnings. Behavior is
            // identical — Process resolves the URL to launch the binary.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", url.path]
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                    InteractiveCaptureGate.release()
                    completion(nil)
                }
                return
            }
            p.waitUntilExitOffMain()
            DispatchQueue.main.async {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                InteractiveCaptureGate.release()
                if FileManager.default.fileExists(atPath: url.path) {
                    completion(url)
                } else {
                    // User pressed Esc, or the system declined for some reason.
                    completion(nil)
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

@MainActor
final class OCRViewModel: ObservableObject {
    @Published var capturedImage: NSImage?
    @Published var capturedURL: URL?
    @Published var recognition: OCRRecognition?
    @Published var working = false
    @Published var statusMessage: String?

    @Published var translationTarget: OCRTargetLanguage = OCRTargets.smartDefault()
    @Published var translatedText: String = ""
    @Published var wantsTranslation: Bool = false
    @Published var translationConfigVersion: Int = 0   // bump to re-arm Translation session

    let history = OCRHistoryStore()

    init() {
        // red-team: if the user is currently viewing the entry that's about
        // to be evicted (either by overflow or manual remove), wipe the main
        // pane back to empty state before the file disappears, so we never
        // render a dangling URL.
        history.willEvict = { [weak self] evicted in
            guard let self = self else { return }
            if self.capturedURL == evicted.imageURL {
                self.capturedURL = nil
                self.capturedImage = nil
                self.recognition = nil
                self.translatedText = ""
            }
        }
    }

    func capture() {
        statusMessage = nil
        OCRCapture.captureRegion { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                // red-team: screencapture -i exits 0 on Esc and never writes
                // the file. Don't just show a message — also clear any prior
                // working state so the pane reflects "no current capture"
                // rather than confusingly keeping the previous result.
                // red-team: same "exit 0, no file" symptom fires when Screen
                // Recording TCC is denied. Probe `CGPreflightScreenCaptureAccess`
                // and route the user straight to the Privacy pane with a
                // toast action button — otherwise they'd just see "cancelled"
                // and assume their click missed.
                if !CGPreflightScreenCaptureAccess() {
                    self.statusMessage = "Screen Recording permission required."
                    SharedStore.stage.flash("Screen Recording permission required",
                                            kind: .warning,
                                            actionLabel: "Open Settings") {
                        TCCDeepLink.screenRecording.open()
                    }
                } else {
                    self.statusMessage = "Capture cancelled."
                }
                self.working = false
                return
            }
            // speed: set URL + working state synchronously so the UI flips to
            // the result pane *immediately*. Preview image and Vision both
            // load off-main below — no full-bitmap decode on the main actor.
            self.capturedURL = url
            self.capturedImage = nil
            self.recognition = nil
            self.translatedText = ""
            self.working = true
            Task { await self.runRecognition(url: url) }
        }
    }

    func runRecognition(url: URL) async {
        working = true
        defer { working = false }
        // speed: decode a small preview thumb on a background thread and push
        // it to the UI before Vision finishes. The preview frame tops out at
        // ~380 pt; 1024 px gives crisp @2x display without paying for a
        // full-bitmap decode of a 4K capture.
        let previewTask = Task.detached(priority: .userInitiated) {
            OCREngine.fastThumbnail(url: url, maxPixel: 1024)
        }
        // Vision recognition runs in parallel with the preview decode. Heavy
        // op stays off-main; the main actor only owns the lightweight result
        // hand-off. Loading the CGImage from URL inside the detached task
        // keeps the full bitmap out of MainActor memory until Vision needs it.
        let recognizeTask = Task.detached(priority: .userInitiated) { () -> OCRRecognition? in
            guard let img = NSImage(contentsOf: url) else { return nil }
            return OCREngine.recognize(img)
        }
        if let preview = await previewTask.value {
            self.capturedImage = preview
        }
        let result = await recognizeTask.value
        guard let result = result else {
            statusMessage = "Couldn't read that image."
            return
        }
        recognition = result
        translatedText = ""
        if result.isEmpty {
            // Red-team #2: empty extraction is shown explicitly so the user
            // knows the OCR ran and just found nothing — not a UI freeze.
            statusMessage = "No text detected."
        } else {
            statusMessage = nil
            history.add(OCRHistoryEntry(
                imageURL: url,
                recognition: result,
                capturedAt: Date()
            ))
            if wantsTranslation { requestTranslation() }
        }
    }

    /// Re-arm the Translation session — actual translate calls happen in the
    /// view via `.translationTask(configuration:)`. Bumping the version forces
    /// the modifier to re-fire when source or target changes.
    func requestTranslation() {
        translationConfigVersion &+= 1
    }

    /// Pick from history — load the entry back into the main pane.
    func selectHistory(_ entry: OCRHistoryEntry) {
        capturedURL = entry.imageURL
        // speed: instantly show the cached 256 px thumb (already in memory
        // because the history strip just rendered it) so the preview pane
        // flips immediately. Then upgrade to a crisper 1024 px decode in the
        // background — same fast-thumbnail path, just a larger budget.
        capturedImage = entry.thumb
        recognition = entry.recognition
        translatedText = ""
        statusMessage = nil
        let url = entry.imageURL
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let crisp = OCREngine.fastThumbnail(url: url, maxPixel: 1024) else { return }
            await MainActor.run {
                guard let self = self, self.capturedURL == url else { return }
                self.capturedImage = crisp
            }
        }
        if wantsTranslation { requestTranslation() }
    }

    var sourceLanguageDisplay: String {
        guard let r = recognition, let lang = r.detectedLanguage else { return "—" }
        let pct = Int((r.languageConfidence * 100).rounded())
        return "\(OCRTargets.displayName(for: lang))  ·  \(pct)%"
    }

    var detectedNLLanguage: NLLanguage? { recognition?.detectedLanguage }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct OCRView: View {
    @EnvironmentObject var stage: Stage
    @StateObject private var vm = OCRViewModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                captureCard
                // speed: gate on capturedURL too so the panes flip the moment
                // a capture is acquired — before the preview thumbnail decode
                // and the Vision pass finish. The panes themselves render a
                // "Recognizing…" placeholder while vm.working is true.
                if vm.recognition != nil || vm.capturedImage != nil || vm.capturedURL != nil {
                    panesCard
                    actionsCard
                }
                historyCard
            }
            .padding(24)
        }
        .navigationTitle("OCR")
        .navigationSubtitle(navSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { vm.capture() } label: {
                    Label("Capture region", systemImage: "viewfinder.rectangular")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(vm.working)
            }
        }
        .modifier(OCRTranslationModifier(vm: vm))
        // red-team: prune orphaned tmp PNGs from prior launches so /tmp doesn't
        // grow without bound across long-lived user sessions. Background prio
        // because it's filesystem-bound and never blocks the UI critical path.
        .task {
            await Task.detached(priority: .background) {
                OCRCapture.sweepStaleTmp()
            }.value
        }
    }

    private var navSubtitle: String {
        if vm.working { return "Recognizing…" }
        if let msg = vm.statusMessage { return msg }
        if let r = vm.recognition {
            return r.isEmpty
                ? "No text detected"
                : "Detected: \(vm.sourceLanguageDisplay)"
        }
        return "Capture a region to extract its text"
    }

    // -----------------------------------------------------------------------
    // Capture card — empty state + the big "Capture region" button.
    // -----------------------------------------------------------------------
    @ViewBuilder private var captureCard: some View {
        // speed: hide the empty-state card the instant a capture URL exists,
        // even before the preview thumbnail decodes — keeps the pane from
        // briefly flashing back to the splash between capture and decode.
        if vm.capturedImage == nil && vm.capturedURL == nil {
            Card {
                VStack(spacing: 14) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Pull text off your screen").font(.title2.weight(.medium))
                    Text("Drag a region to OCR it locally. Source language is auto-detected; translate to any of nine common languages without leaving the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button {
                        vm.capture()
                    } label: {
                        Label("Capture region", systemImage: "viewfinder.rectangular")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.working)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Side-by-side image + extracted text.
    // -----------------------------------------------------------------------
    @ViewBuilder private var panesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Result").font(.headline)
                    Spacer()
                    if vm.working {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    capturePreview
                        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 380)
                    textPanes
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var capturePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.5))
            if let img = vm.capturedImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var textPanes: some View {
        VStack(spacing: 12) {
            originalPane
            if vm.wantsTranslation { translationPane }
        }
    }

    @ViewBuilder private var originalPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.secondary)
                Text("Original").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let r = vm.recognition, !r.isEmpty {
                    Text("·").foregroundStyle(.secondary)
                    Text(vm.sourceLanguageDisplay)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                if let r = vm.recognition {
                    if r.isEmpty {
                        // Red-team #2.
                        Text("No text detected.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        Text(r.paragraphs)
                            .font(.system(.body, design: .default))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            // Red-team #5: respect the script's native direction.
                            .environment(\.layoutDirection, dominantLayoutDirection(r))
                            .padding(10)
                    }
                } else if vm.working {
                    Text("Recognizing…").foregroundStyle(.secondary).padding(10)
                } else {
                    Text("Capture a region to see extracted text here.")
                        .foregroundStyle(.tertiary).padding(10)
                }
            }
            .frame(minHeight: 130, maxHeight: 220)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var translationPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble").font(.caption2).foregroundStyle(.tint)
                Text("Translation · \(vm.translationTarget.label)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                if !vm.translatedText.isEmpty {
                    Text(vm.translatedText)
                        .font(.system(.body, design: .default))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                } else if vm.working {
                    Text("Translating…").foregroundStyle(.secondary).padding(10)
                } else {
                    // Red-team #3: surface what to expect. If the language model
                    // isn't downloaded, the Translation framework presents the
                    // download UI itself — we just need to not look broken
                    // while that happens.
                    Text("Translation will appear here. The first time you use a new language pair, macOS may prompt you to download the on-device model (one-time, ~50–100 MB).")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(10)
                }
            }
            .frame(minHeight: 130, maxHeight: 220)
            .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func dominantLayoutDirection(_ r: OCRRecognition) -> LayoutDirection {
        let rtl = r.lines.filter { $0.isRTL }.count
        return rtl * 2 > r.lines.count ? .rightToLeft : .leftToRight
    }

    // -----------------------------------------------------------------------
    // Actions row — copy / send-to-stage / translate toggle + picker.
    // -----------------------------------------------------------------------
    @ViewBuilder private var actionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Toggle(isOn: $vm.wantsTranslation) {
                        Label("Translate to", systemImage: "character.bubble")
                    }
                    .toggleStyle(.switch)
                    .onChange(of: vm.wantsTranslation) { _, on in
                        if on, let r = vm.recognition, !r.isEmpty { vm.requestTranslation() }
                    }

                    Picker("", selection: $vm.translationTarget) {
                        ForEach(OCRTargets.all) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                    .disabled(!vm.wantsTranslation)
                    .onChange(of: vm.translationTarget) { _, _ in
                        if vm.wantsTranslation, let r = vm.recognition, !r.isEmpty {
                            vm.requestTranslation()
                        }
                    }
                    Spacer()
                }

                Divider()

                // ---- OCR text row: Copy / Save As… / More ▼ ------------------
                HStack(spacing: 10) {
                    Text("Recognized text").font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        copyToPasteboard(originalText())
                        stage.flash("Copied OCR text")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(!hasOriginal)
                    // ⌘C would clash with system text-selection copy; use ⌘⇧C
                    // for the "copy whole result" affordance.
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy recognized text to the clipboard (⌘⇧C)")

                    Button {
                        if let t = originalText() {
                            Self.saveOCRText(t, kind: .original)
                        }
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!hasOriginal)
                    .keyboardShortcut("s", modifiers: [.command])
                    .help("Save the recognized text as a .txt file (⌘S).")

                    Menu {
                        Button {
                            if let t = originalText() {
                                Self.quickSaveOCRTextToDownloads(t, kind: .original)
                            }
                        } label: {
                            Label("Save to Downloads", systemImage: "arrow.down.circle")
                        }
                        .keyboardShortcut("d", modifiers: [.command])
                        Button {
                            if let t = originalText() {
                                stage.addText(t)
                                stage.flash("Added OCR text to Stage")
                            }
                        } label: {
                            Label("Send to Stage", systemImage: "tray.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!hasOriginal)
                    .help("More actions")
                }
                // Drag the recognized text as a .txt file straight into Finder
                // or any app that accepts file drops. Provider materializes
                // the file on-demand via fileRepresentation.
                .onDrag {
                    Self.makeTextItemProvider(originalText() ?? "", kind: .original)
                }
                .contextMenu {
                    Button {
                        copyToPasteboard(originalText())
                        stage.flash("Copied OCR text")
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(!hasOriginal)
                    Button {
                        if let t = originalText() {
                            Self.saveOCRText(t, kind: .original)
                        }
                    } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .disabled(!hasOriginal)
                    Button {
                        if let t = originalText() {
                            Self.quickSaveOCRTextToDownloads(t, kind: .original)
                        }
                    } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                    .disabled(!hasOriginal)
                    Button {
                        if let t = originalText() {
                            stage.addText(t)
                            stage.flash("Added OCR text to Stage")
                        }
                    } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
                    .disabled(!hasOriginal)
                }

                // ---- Translation row: same affordances, gated on translation -
                HStack(spacing: 10) {
                    Text("Translation").font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        copyToPasteboard(vm.translatedText)
                        stage.flash("Copied translation")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc.fill")
                    }
                    .disabled(vm.translatedText.isEmpty)
                    .help("Copy translated text to the clipboard")

                    Button {
                        if !vm.translatedText.isEmpty {
                            Self.saveOCRText(vm.translatedText, kind: .translation)
                        }
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(vm.translatedText.isEmpty)
                    .help("Choose where to save the translated text as a .txt file.")

                    Menu {
                        Button {
                            if !vm.translatedText.isEmpty {
                                Self.quickSaveOCRTextToDownloads(vm.translatedText, kind: .translation)
                            }
                        } label: {
                            Label("Save to Downloads", systemImage: "arrow.down.circle")
                        }
                        Button {
                            if !vm.translatedText.isEmpty {
                                stage.addText(vm.translatedText)
                                stage.flash("Added translation to Stage")
                            }
                        } label: {
                            Label("Send to Stage", systemImage: "tray.and.arrow.down.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(vm.translatedText.isEmpty)
                    .help("More actions")
                }
                .onDrag {
                    Self.makeTextItemProvider(vm.translatedText, kind: .translation)
                }
                .contextMenu {
                    Button {
                        copyToPasteboard(vm.translatedText)
                        stage.flash("Copied translation")
                    } label: { Label("Copy", systemImage: "doc.on.doc.fill") }
                    .disabled(vm.translatedText.isEmpty)
                    Button {
                        if !vm.translatedText.isEmpty {
                            Self.saveOCRText(vm.translatedText, kind: .translation)
                        }
                    } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .disabled(vm.translatedText.isEmpty)
                    Button {
                        if !vm.translatedText.isEmpty {
                            Self.quickSaveOCRTextToDownloads(vm.translatedText, kind: .translation)
                        }
                    } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                    .disabled(vm.translatedText.isEmpty)
                    Button {
                        if !vm.translatedText.isEmpty {
                            stage.addText(vm.translatedText)
                            stage.flash("Added translation to Stage")
                        }
                    } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down.fill") }
                    .disabled(vm.translatedText.isEmpty)
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Save helpers — statics so closures don't capture self.
    // -----------------------------------------------------------------------

    fileprivate enum OCRSaveKind {
        case original, translation
        var label: String { self == .original ? "OCR result" : "OCR translation" }
    }

    /// Save As… with NSSavePanel. Default `.txt`, name pre-filled with
    /// "<label> <timestamp>.txt". Remembers last-used directory.
    fileprivate static func saveOCRText(_ text: String, kind: OCRSaveKind) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "\(kind.label) \(timestampForFilename()).txt"
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                try text.write(to: dest, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved \(kind.label) to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    fileprivate static func quickSaveOCRTextToDownloads(_ text: String, kind: OCRSaveKind) {
        guard let downloads = downloadsDir() else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let name = "\(kind.label) \(timestampForFilename()).txt"
        let dest = collisionFreeURL(in: downloads, name: name)
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved \(kind.label) to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    /// Build an NSItemProvider that materializes a .txt file on-demand.
    /// Receivers (Finder, Mail, Slack, etc.) accept this as a real file drop.
    fileprivate static func makeTextItemProvider(_ text: String, kind: OCRSaveKind) -> NSItemProvider {
        let provider = NSItemProvider()
        let filename = "\(kind.label).txt"
        provider.suggestedName = filename
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(filename)")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                completion(url, false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    // ---- shared save-dir state (statics so closures don't capture self) ----

    private static let kSaveDirKey = "ocr.text.saveDir.last"

    fileprivate static func lastSaveDir() -> URL? {
        guard let p = UserDefaults.standard.string(forKey: kSaveDirKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    fileprivate static func setLastSaveDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: kSaveDirKey)
    }

    fileprivate static func downloadsDir() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Append " (2)", " (3)"… before the extension until the destination
    /// doesn't exist. Cap at 99 — past that, return the last candidate and
    /// let the write fail with a sane error rather than loop forever.
    fileprivate static func collisionFreeURL(in dir: URL, name: String) -> URL {
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

    /// "2026-05-13 21:45" — local time, sortable, filename-safe.
    fileprivate static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    private var hasOriginal: Bool {
        if let r = vm.recognition, !r.isEmpty { return true }
        return false
    }

    private func originalText() -> String? {
        guard let r = vm.recognition, !r.isEmpty else { return nil }
        return r.paragraphs
    }

    private func copyToPasteboard(_ s: String?) {
        guard let s = s, !s.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // -----------------------------------------------------------------------
    // History strip — last 10 OCR captures, thumbnail + summary.
    // -----------------------------------------------------------------------
    @ViewBuilder private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent captures").font(.headline)
                    Spacer()
                    if !vm.history.entries.isEmpty {
                        Text("\(vm.history.entries.count) of \(OCRHistoryStore.maxEntries)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if vm.history.entries.isEmpty {
                    Text("No captures yet. Anything you OCR shows up here so you can re-copy without re-shooting.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(vm.history.entries) { entry in
                                OCRHistoryThumb(entry: entry,
                                                onSelect: { vm.selectHistory(entry) },
                                                onRemove: { vm.history.remove(entry.id) })
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - History thumbnail
// ===========================================================================

private struct OCRHistoryThumb: View {
    let entry: OCRHistoryEntry
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = entry.thumb {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 130, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hover ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                                      lineWidth: hover ? 1.2 : 0.5)
                )
                if hover {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            Text(entry.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 130, alignment: .leading)
        }
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .help(entry.recognition.paragraphs)
    }
}

// ===========================================================================
// MARK: - Translation glue
// ===========================================================================
//
// Apple's Translation framework runs on-device when the chosen language pair
// has been downloaded. We use the SwiftUI `.translationTask(configuration:)`
// modifier so the framework owns the lifecycle (and the download UI prompt
// when needed). This file is fine to compile on older OSes — the framework
// only activates when available.

private struct OCRTranslationModifier: ViewModifier {
    @ObservedObject var vm: OCRViewModel

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 14.0, *) {
            content.modifier(OCRTranslationTask(vm: vm))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 14.0, *)
private struct OCRTranslationTask: ViewModifier {
    @ObservedObject var vm: OCRViewModel
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: vm.translationConfigVersion) { _, _ in rebuild() }
            .onAppear { rebuild() }
            .translationTask(config) { session in
                guard let r = vm.recognition, !r.isEmpty else { return }
                let source = r.paragraphs
                // red-team: prepareTranslation() is what triggers the system
                // download prompt for a missing language pack. If the user
                // dismisses the prompt the call throws — we surface a
                // friendly note rather than leaving the pane saying
                // "Translating…" forever, *and* we clear `wantsTranslation`'s
                // visible spinner by writing an empty translation.
                do {
                    try await session.prepareTranslation()
                } catch {
                    await MainActor.run {
                        vm.translatedText = ""
                        vm.statusMessage = "Translation model not available. Approve the macOS download prompt and try again."
                    }
                    return
                }
                do {
                    let response = try await session.translate(source)
                    await MainActor.run { vm.translatedText = response.targetText }
                } catch {
                    // For any other failure we leave the previous translation
                    // in place and note it.
                    await MainActor.run {
                        vm.statusMessage = "Translation unavailable — \(error.localizedDescription)"
                    }
                }
            }
    }

    private func rebuild() {
        guard vm.wantsTranslation,
              let r = vm.recognition,
              !r.isEmpty else {
            config = nil
            return
        }
        let sourceCode = vm.detectedNLLanguage?.rawValue
        let source: Locale.Language? = sourceCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: vm.translationTarget.code)
        // If source == target there's nothing to do; mirror the original text.
        if let src = source, src.languageCode?.identifier == target.languageCode?.identifier {
            vm.translatedText = r.paragraphs
            config = nil
            return
        }
        config = TranslationSession.Configuration(source: source, target: target)
    }
}
#endif
