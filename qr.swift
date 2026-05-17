// Trove — QR Generator pane.
//
// Type or paste anything; get a clean, scannable QR code. Save it, copy it,
// or push it onto the Stage for batch sending. Useful for shipping a Wi-Fi
// password or a URL between devices without involving a network.

import SwiftUI
import AppKit
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Generator (pure, off main thread)
// ===========================================================================

enum QRCorrection: String, CaseIterable, Identifiable {
    case L, M, Q, H
    var id: String { rawValue }
    var label: String {
        switch self {
        case .L: return "L · ~7%"
        case .M: return "M · ~15%"
        case .Q: return "Q · ~25%"
        case .H: return "H · ~30%"
        }
    }
}

enum QRGenError: Error, Equatable {
    case empty
    case tooLong
    case encoderFailed
}

/// One CIContext lives across calls so we don't pay setup cost on every keystroke.
/// CIContext is documented thread-safe for createCGImage.
private let qrCIContext = CIContext(options: nil)

enum QRGenerator {
    /// Render `text` to a high-resolution NSImage. Throws on empty or too-long input,
    /// since CIQRCodeGenerator silently returns nil for unencodable payloads.
    static func render(_ text: String, correction: QRCorrection, targetSize: CGFloat = 1024) throws -> NSImage {
        if text.isEmpty { throw QRGenError.empty }

        // Red-team #3: encode as UTF-8 so emoji / non-ASCII round-trip cleanly.
        guard let data = text.data(using: .utf8) else { throw QRGenError.encoderFailed }

        // Red-team #2: hard-cap at 4296 bytes — even level L tops out around there.
        // Beyond that CIFilter quietly returns nil, which would surface as "encoderFailed".
        // Catch it early with a clearer signal.
        if data.count > 4296 { throw QRGenError.tooLong }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { throw QRGenError.tooLong }

        // Red-team #4: native output is ~25–177px square. Scale to ≥1024 with
        // nearest-neighbor (default for CIImage transformed) so module edges stay crisp.
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { throw QRGenError.encoderFailed }
        let scale = max(1, targetSize / extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = qrCIContext.createCGImage(scaled, from: scaled.extent) else {
            throw QRGenError.encoderFailed
        }
        let pxSize = NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: pxSize)
    }

    /// PNG bytes for an NSImage backed by a single CGImage. Prefers the
    /// CGImage path so we don't double-encode through TIFF on every save/
    /// copy — the CIContext rendered to a CGImage already; round-tripping
    /// it through NSBitmapImageRep(data: tiffRepresentation) was reparsing
    /// a freshly serialized TIFF blob purely to re-serialize it as PNG.
    /// Falls back to the TIFF path for any NSImage that wasn't constructed
    /// from a single CGImage (defensive — our own pipeline always is).
    static func pngData(_ image: NSImage) -> Data? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: cg.width, height: cg.height)
            if let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct QRView: View {
    @EnvironmentObject var stage: Stage

    @State private var text: String = ""
    @State private var correction: QRCorrection = .M
    @State private var image: NSImage? = nil
    @State private var errorText: String? = nil
    @State private var debounceTask: Task<Void, Never>? = nil
    /// On every successful regen, the QR is also written to a temp PNG so
    /// the Save / drag / Save-to-Downloads affordances can treat it like
    /// any other on-disk capture (matching the pdf.swift pattern).
    @State private var materializedURL: URL? = nil

    public init() {}

    private var byteCount: Int { text.data(using: .utf8)?.count ?? 0 }
    private var actionsEnabled: Bool { image != nil && errorText == nil }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inputCard
                previewCard
                actionsRow
            }
            .padding(24)
        }
        .navigationTitle("QR")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        .onChange(of: text) { _ in scheduleRegen() }
        .onChange(of: correction) { _ in scheduleRegen() }
        .onAppear {
            ingestSmartQRPayload(StageSmartActionQueue.shared.drain(.troveSmartOpenInQR))
        }
        .onReceive(NotificationCenter.default.publisher(for: .troveSmartOpenInQR)) { n in
            ingestSmartQRPayload(n.userInfo)
        }
    }

    private func ingestSmartQRPayload(_ info: [AnyHashable: Any]?) {
        guard let info,
              let t = info[StageSmartKey.text] as? String, !t.isEmpty else { return }
        text = t
    }

    private var subtitle: String {
        if let s = stage.transientStatus { return s }
        if text.isEmpty { return "Type or paste anything to generate" }
        // red-team / security-lens: surface dangerous URL schemes in the
        // subtitle so a user reviewing what they're about to share notices
        // before they ship a code that, when scanned, opens a local file
        // path or executes a JS handler in the scanner's webview. We do NOT
        // refuse to generate (the user might legitimately want a `file://`
        // for an internal kiosk) — we just tag it visibly.
        if let warn = dangerousSchemeWarning {
            return "\(warn) · \(byteCount) byte\(byteCount == 1 ? "" : "s") · level \(correction.rawValue)"
        }
        return "\(text.count) char\(text.count == 1 ? "" : "s") · \(byteCount) byte\(byteCount == 1 ? "" : "s") · level \(correction.rawValue)"
    }

    /// Returns a short warning if the payload starts with a URL scheme that
    /// is risky to embed in a QR (will auto-open on scan into the scanner's
    /// browser/file handler). Nil otherwise.
    private var dangerousSchemeWarning: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("javascript:") { return "WARNING: javascript: URL — recipients' scanners may execute" }
        if trimmed.hasPrefix("file://")     { return "Note: file:// URL — only valid on the recipient's local disk" }
        if trimmed.hasPrefix("data:")       { return "Note: data: URL — many scanners refuse to open these" }
        return nil
    }

    // -------------------------------------------------------------------
    // Input
    // -------------------------------------------------------------------

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Input").font(.headline)
                    Spacer()
                    Picker("Error correction", selection: $correction) {
                        ForEach(QRCorrection.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .labelsHidden()
                    .help("Higher levels survive more damage but pack less data per pixel.")
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 180)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                        )
                        // red-team / a11y: VoiceOver reads an empty TextEditor
                        // as "text area, empty" with no hint what to type.
                        // Make the role + intent explicit so VO announces
                        // "QR payload, text area" on focus.
                        .accessibilityLabel("QR payload")
                        .accessibilityHint("Enter or paste the text, URL, or data to encode.")
                    if text.isEmpty {
                        Text("Type or paste anything…")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                            // The visible placeholder is decorative — the real
                            // affordance is read out via the editor's
                            // accessibilityHint above.
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Preview
    // -------------------------------------------------------------------

    private var previewCard: some View {
        Card {
            VStack(spacing: 12) {
                HStack {
                    Text("Preview").font(.headline)
                    Spacer()
                    if let img = image {
                        Text("\(Int(img.size.width))×\(Int(img.size.height)) px")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white)
                        .frame(width: 280, height: 280)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                        )
                    previewBody
                        .frame(width: 256, height: 256)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        if let err = errorText {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        } else if let img = image {
            Image(nsImage: img)
                .resizable()
                .interpolation(.none)            // keep module edges sharp at 280pt
                .scaledToFit()
                // red-team: VoiceOver had no readout for the generated QR.
                // Expose the encoded text so VO can describe what the code
                // contains (truncated for very long payloads).
                .accessibilityLabel("QR code")
                .accessibilityValue(text.count > 200
                                    ? "Encodes \(text.count) characters of data."
                                    : "Encodes: \(text)")
                .contextMenu {
                    Button { saveAs() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    Button { saveToDownloads() } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                    Button { revealInFinder() } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                    Button { sendToStage() } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
                    Divider()
                    Button { copyImage() } label: { Label("Copy image to clipboard", systemImage: "doc.on.doc") }
                    Button { copyPath() } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                }
        } else if text.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Type something to generate a QR")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // -------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button {
                saveAs()
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .disabled(!actionsEnabled)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save this QR (⌘S — PNG / JPEG / PDF).")

            Menu {
                Button { saveToDownloads() } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("d", modifiers: [.command])
                Button { revealInFinder() } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button { sendToStage() } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
                Divider()
                Button { copyImage() } label: {
                    Label("Copy image to clipboard", systemImage: "doc.on.doc")
                }
                Button { copyPath() } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!actionsEnabled)
            .help("More actions")

            Button {
                sendToStage()
            } label: {
                Label("Send to Stage", systemImage: "tray.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!actionsEnabled)

            Spacer()
        }
        .controlSize(.large)
        // Drag the QR out of the actions row straight into Finder, Mail,
        // Slack, etc. The materialized temp PNG is the source of truth —
        // NSItemProvider(contentsOf:) yields a file URL the receiver
        // accepts as a real file drop.
        .onDrag {
            if let url = materializedURL {
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            return NSItemProvider()
        }
    }

    // -------------------------------------------------------------------
    // Toolbar
    // -------------------------------------------------------------------

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .help("Paste clipboard text into the QR input (⌘⌥V)")

            Button(role: .destructive) {
                text = ""
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(text.isEmpty)
            .help("Clear the input")
        }
    }

    // -------------------------------------------------------------------
    // Behavior
    // -------------------------------------------------------------------

    /// Red-team #5: cancel any in-flight regen and schedule a fresh one ~200ms out.
    /// On rapid typing only the last value renders.
    private func scheduleRegen() {
        debounceTask?.cancel()
        let snapshotText = text
        let snapshotLevel = correction
        if snapshotText.isEmpty {
            // Red-team #1: empty state — clear preview, keep actions disabled.
            image = nil
            errorText = nil
            materializedURL = nil
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await regenerate(text: snapshotText, level: snapshotLevel)
        }
    }

    @MainActor
    private func regenerate(text: String, level: QRCorrection) async {
        // Off-main render so a 4 KB payload doesn't hitch the editor.
        let result: Result<NSImage, QRGenError> = await Task.detached(priority: .userInitiated) {
            do {
                let img = try QRGenerator.render(text, correction: level)
                return .success(img)
            } catch let e as QRGenError {
                return .failure(e)
            } catch {
                return .failure(.encoderFailed)
            }
        }.value

        // Drop late results if the user has typed past us.
        if text != self.text || level != self.correction { return }

        switch result {
        case .success(let img):
            image = img
            errorText = nil
            // Materialize to a temp PNG so Save / drag / Save-to-Downloads
            // can treat the QR like any other on-disk capture. Done off
            // the hot UI path; failure here just leaves the on-disk URL
            // nil and the drag handler degrades gracefully.
            materializedURL = QRSaver.materialize(img)
        case .failure(let e):
            image = nil
            materializedURL = nil
            switch e {
            case .empty:
                errorText = nil  // empty handled by previewBody
            case .tooLong:
                // red-team: the bare "try a shorter version" wasn't actionable
                // — users don't know the spec ceiling. Tell them the level-L
                // upper bound (4296 bytes) and that dropping the EC level
                // doesn't help past that point.
                let bytes = text.data(using: .utf8)?.count ?? text.count
                errorText = "Input is \(bytes) bytes; QR tops out at 4296 bytes (level L). Shorten the payload — lowering the EC level won't fit it."
            case .encoderFailed:
                errorText = "Couldn't encode this input as a QR"
            }
        }
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            text = s
        } else {
            stage.flash("Clipboard has no text to paste")
        }
    }

    private func copyImage() {
        guard let img = image else { return }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        pb.clearContents()
        // red-team: declare BOTH .png and .tiff up-front before writing data.
        // Calling `writeObjects([img])` writes TIFF and declares only TIFF;
        // a subsequent `setData(_:forType:.png)` on some macOS versions does
        // not auto-promote the declared types, so Slack/web inputs that ask
        // for PNG see "nothing here". Declaring first guarantees both flavors.
        pb.declareTypes([.png, .tiff], owner: nil)
        var wrote = false
        if let png = QRGenerator.pngData(img) {
            wrote = pb.setData(png, forType: .png) || wrote
        }
        if let tiff = img.tiffRepresentation {
            wrote = pb.setData(tiff, forType: .tiff) || wrote
        }
        if wrote && pb.changeCount > before {
            stage.flash("QR copied to clipboard")
        } else {
            stage.flash("Couldn't copy QR to clipboard")
        }
    }

    /// NSSavePanel-driven save: lets the user pick PNG / JPEG / PDF and the
    /// destination. Remembers the last-used directory across sessions so the
    /// repeat-save flow is one Return-key away. Mirrors the pdf.swift pattern.
    private func saveAs() {
        guard let img = image else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "qr-\(stamp).png"
        // PNG default — QR is lossless; JPEG / PDF available via the format
        // popup the panel renders from `allowedContentTypes`.
        panel.allowedContentTypes = [.png, .jpeg, .pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = QRSaver.lastSaveDir() ?? QRSaver.downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            QRSaver.setLastSaveDir(dest.deletingLastPathComponent())
            do {
                try QRSaver.write(img, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                stage.flash("Saved \(dest.lastPathComponent)")
            } catch {
                stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    /// Falls back to NSSavePanel if the Downloads write is TCC-denied.
    private func saveToDownloads() {
        guard let img = image, let png = QRGenerator.pngData(img) else {
            stage.flash("Couldn't encode QR as PNG")
            return
        }
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let url = QRSaver.collisionFreeURL(in: downloads, name: "qr-\(stamp).png")
        do {
            try png.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            stage.flash("Saved \(url.lastPathComponent) to Downloads")
        } catch {
            // red-team: Downloads is gated by TCC. If the direct write is denied
            // (sandbox or "Files & Folders" permission missing), fall back to
            // an NSSavePanel — the user-driven panel grants implicit access to
            // the chosen URL via Powerbox, no TCC prompt required.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "qr-\(stamp).png"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.directoryURL = downloads
            panel.message = "Downloads write was denied — pick a location."
            if panel.runModal() == .OK, let chosen = panel.url {
                do {
                    try png.write(to: chosen, options: .atomic)
                    NSWorkspace.shared.activateFileViewerSelecting([chosen])
                    stage.flash("Saved \(chosen.lastPathComponent)")
                } catch {
                    stage.flash("Save failed: \(error.localizedDescription)")
                }
            } else {
                stage.flash("Save cancelled (\(error.localizedDescription))")
            }
        }
    }

    private func revealInFinder() {
        // Prefer revealing the materialized temp PNG so the user can see
        // what bytes ship on drag/copy. If we haven't materialized yet
        // (shouldn't happen once actionsEnabled is true), do nothing.
        guard let url = materializedURL else {
            stage.flash("Nothing on disk yet — Save first")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        guard let url = materializedURL else {
            stage.flash("Nothing on disk yet — Save first")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        stage.flash("Copied path")
    }

    private func sendToStage() {
        guard let img = image else { return }
        stage.addImage(img)
        stage.flash("QR added to Stage")
    }
}

// ===========================================================================
// MARK: - QR save helpers (statics so closures don't capture self)
// ===========================================================================

/// Save / format-conversion helpers for the materialized QR PNG. Mirrors the
/// pdf.swift `outputRow` helper pattern.
enum QRSaver {
    private static let kSaveDirKey = "qr.image.saveDir.last"

    /// Render the NSImage to PNG and stash it in a temp directory so the
    /// rest of the affordance stack can treat it like a real file URL.
    /// Returns nil on encode failure — caller should leave the drag/save
    /// affordances disabled in that case.
    static func materialize(_ image: NSImage) -> URL? {
        guard let png = QRGenerator.pngData(image) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-qr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("qr-\(stamp).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Write an NSImage to `dest`, encoding to the format implied by the
    /// destination's extension (PNG / JPEG / PDF). NSSavePanel ensures the
    /// extension matches whatever the user picked in the format popup.
    static func write(_ image: NSImage, to dest: URL) throws {
        let ext = dest.pathExtension.lowercased()
        let data: Data?
        switch ext {
        case "jpg", "jpeg":
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = NSSize(width: cg.width, height: cg.height)
                data = rep.representation(using: .jpeg,
                                          properties: [.compressionFactor: 0.95])
            } else if let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff) {
                data = rep.representation(using: .jpeg,
                                          properties: [.compressionFactor: 0.95])
            } else {
                data = nil
            }
        case "pdf":
            data = pdfData(image)
        default:
            // PNG covers .png and any unknown extension — sticking with the
            // lossless format avoids surprising the user.
            data = QRGenerator.pngData(image)
        }
        guard let bytes = data else {
            throw NSError(domain: "QRSaver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't encode image as \(ext.uppercased())"])
        }
        // NSSavePanel already confirmed overwrite consent.
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try bytes.write(to: dest, options: .atomic)
    }

    /// Wrap the QR bitmap in a single-page PDF. Fixed at 8.5×8.5 inch so
    /// printing for kiosks / posters yields a known physical size; QR
    /// readability is preserved by the vector container.
    private static func pdfData(_ image: NSImage) -> Data? {
        let pageSize = NSSize(width: 612, height: 612) // 8.5" @ 72 dpi
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        image.draw(in: CGRect(origin: .zero, size: pageSize),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
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

    /// Append " (2)", " (3)"… before the extension until the destination
    /// doesn't exist. Cap at 99 — past that, return the last candidate and
    /// let the copy fail with a sane error.
    static func collisionFreeURL(in dir: URL, name: String) -> URL {
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
}
