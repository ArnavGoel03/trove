// Trove — Stage Smart Actions bar.
//
// A contextual action bar that lives inside the Stage view between the
// toolbar and the grid (or empty state). It classifies the bag of staged
// items with O(n) short-circuit rules and surfaces 0–3 pill buttons that
// hand off to the right tool pane via NotificationCenter — so the user
// doesn't have to remember which pane handles what.
//
// Pure function of `items: [StagedItem]`. No singletons, no observed
// state — easy to unit-test by instantiating with synthetic input.
//
// Compiles with `swiftc -parse-as-library` alongside main.swift; it relies
// on `StagedItem` / `ItemKind` / `Card` / `SharedStore.stage.flash(…)`.

import SwiftUI
import AppKit
import Foundation

// ===========================================================================
// MARK: - Notification protocol
// ===========================================================================

extension Notification.Name {
    /// Open the PDF Tools pane and pre-load the named op + URLs.
    static let troveSmartOpenInPDFTool   = Notification.Name("trove.smart.openInPDFTool")
    /// Open Image Tools and pre-load URLs (+ optional preset like shrinkForChat).
    static let troveSmartOpenInImageTools = Notification.Name("trove.smart.openInImageTools")
    /// Open OCR pre-loaded with a PDF or image URL.
    static let troveSmartOpenInOCR       = Notification.Name("trove.smart.openInOCR")
    /// Open the Color pane with image URLs to pull a palette from.
    static let troveSmartOpenInColor     = Notification.Name("trove.smart.openInColor")
    /// Open Text Tools with payload text staged.
    static let troveSmartOpenInXform     = Notification.Name("trove.smart.openInXform")
    /// Open Snippets ready to save the payload as a snippet.
    static let troveSmartOpenInSnippets  = Notification.Name("trove.smart.openInSnippets")
    /// Open QR pane with the payload string.
    static let troveSmartOpenInQR        = Notification.Name("trove.smart.openInQR")
}

/// Centralised userInfo key constants so receivers and senders stay in sync.
enum StageSmartKey {
    static let urls = "urls"   // [URL]
    static let text = "text"   // String
    static let op   = "op"     // String (free-form op hint)
}

// ===========================================================================
// MARK: - Pending-action queue (red-team #2)
// ===========================================================================

/// Receiver panes may not be instantiated when a smart-action notification is
/// posted (lazy `NavigationStack` destinations don't mount until selected).
/// `StageSmartActionQueue` buffers the most recent payload per notification
/// name; receiver views drain it in their `.onAppear`. This means a click on
/// "OCR this image" works whether or not the OCR pane has ever been opened
/// in the current session.
///
/// We only keep the latest payload per name — older queued ops are stomped.
/// Rationale: smart actions are user-initiated and one-shot; if the user
/// clicks "Compress" then "Merge" we want the second one to win, not both.
@MainActor
final class StageSmartActionQueue {
    static let shared = StageSmartActionQueue()
    private init() {}

    private var pending: [Notification.Name: [AnyHashable: Any]] = [:]

    /// Post immediately AND park the userInfo. Receivers can drain on appear.
    func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]) {
        pending[name] = userInfo
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// Pop the most recent payload for `name` (returns nil if nothing queued).
    /// Receiver-pane `onAppear` should call this and ingest the result.
    func drain(_ name: Notification.Name) -> [AnyHashable: Any]? {
        let v = pending[name]
        pending[name] = nil
        return v
    }
}

// ===========================================================================
// MARK: - Classification
// ===========================================================================

enum StageSmartClassifier {
    /// Image extensions accepted as `.file` items that are really images.
    /// Kept lowercase; matched against `pathExtension.lowercased()`.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif",
        "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2", "pef", "rwl",
        "3fr", "nrw", "sr2", "bmp",
    ]

    /// Short-circuiting "every item is a usable PDF on disk" check.
    /// Returns false as soon as a non-PDF item is seen — does NOT scan a
    /// 1000-item stage when the first item already disqualifies the bag.
    static func allPDFs(_ items: [StagedItem]) -> Bool {
        guard !items.isEmpty else { return false }
        for it in items {
            switch it.kind {
            case .file(let u):
                if u.pathExtension.lowercased() != "pdf" { return false }
            case .text, .image:
                return false
            }
        }
        return true
    }

    /// Every item is either a staged image OR a file whose extension is an
    /// image format. Short-circuits.
    static func allImages(_ items: [StagedItem]) -> Bool {
        guard !items.isEmpty else { return false }
        for it in items {
            switch it.kind {
            case .image:
                continue
            case .file(let u):
                if !imageExtensions.contains(u.pathExtension.lowercased()) {
                    return false
                }
            case .text:
                return false
            }
        }
        return true
    }

    /// Every item is text. Short-circuits.
    static func allText(_ items: [StagedItem]) -> Bool {
        guard !items.isEmpty else { return false }
        for it in items {
            if case .text = it.kind { continue }
            return false
        }
        return true
    }

    /// Extract URLs from `.file` items (and `.image(url)`). Used to build
    /// the userInfo payload for file-based ops.
    static func urls(from items: [StagedItem]) -> [URL] {
        // red-team: a user can drop the same file onto the Stage twice (Stage
        // doesn't de-dupe — that's by design so duplicates can be intentional
        // for some ops). But running "Merge into one PDF" on [a.pdf, a.pdf]
        // produces a doubled PDF, almost never what's intended. De-dupe by
        // canonical (symlinks-resolved + standardized) path here so smart
        // dispatch is always operating on a unique set.
        var seen = Set<String>()
        var out: [URL] = []
        for it in items {
            let u: URL?
            switch it.kind {
            case .file(let url):  u = url
            case .image(let url): u = url
            case .text:           u = nil
            }
            guard let url = u else { continue }
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(key).inserted {
                out.append(url)
            }
        }
        return out
    }

    /// Filter URLs to ones whose file currently exists on disk. Red-team #1:
    /// Sweep / Clean could have moved the underlying file between staging
    /// and the smart-action click.
    ///
    /// red-team: a file evicted to iCloud reports `fileExists == true` for the
    /// sidecar placeholder but isn't actually downloaded. Dispatching ops on a
    /// dataless stub triggers macOS' "download now" alert and the receiver
    /// pane crunches a 0-byte file. Treat iCloud stubs as dead.
    static func existing(_ urls: [URL]) -> (live: [URL], dead: [URL]) {
        var live: [URL] = []
        var dead: [URL] = []
        let fm = FileManager.default
        for u in urls {
            guard fm.fileExists(atPath: u.path) else {
                dead.append(u); continue
            }
            if isiCloudPlaceholder(u) {
                dead.append(u); continue
            }
            live.append(u)
        }
        return (live, dead)
    }

    /// macOS dataless-file detection. The placeholder is `.<basename>.icloud`
    /// adjacent to the would-be file. Cheap two-stat probe.
    private static func isiCloudPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") && name.hasSuffix(".icloud") { return true }
        let sidecar = url.deletingLastPathComponent()
            .appendingPathComponent(".\(name).icloud")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    /// Concatenate text payloads with a blank-line separator. Trims trailing
    /// whitespace so the joined string doesn't end with `\n\n`.
    static func joinedText(_ items: [StagedItem]) -> String {
        let parts: [String] = items.compactMap {
            if case .text(let s) = $0.kind { return s } else { return nil }
        }
        return parts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cached regex for the bare-domain heuristic. Building NSRegularExpression
    /// every keystroke is wasteful when the smart bar re-evaluates on each
    /// stage change.
    private static let urlTokenRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"^[A-Za-z0-9._\-/:?&=%+#~@]+$"#)

    /// Heuristic: a single short URL-looking text payload that would make
    /// sense as a QR code. Keeps the URL detector deliberately loose — if
    /// the user wants a QR for a plain string they can always paste in
    /// the QR pane manually.
    static func looksLikeShortURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 0, t.count <= 512, !t.contains(where: \.isNewline) else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        // red-team: mailto:, tel:, sms:, and geo: are extremely common QR
        // payloads (vCard scanners). Previously these slipped through the
        // bare-domain branch only when they happened to contain a dot —
        // `tel:+15551234567` for example didn't match. Surface the suggestion
        // explicitly for these well-known URI schemes.
        for scheme in ["mailto:", "tel:", "sms:", "geo:", "facetime:", "facetime-audio:"] {
            if lower.hasPrefix(scheme) { return true }
        }
        // bare-domain heuristic: contains a dot, no spaces, looks token-y.
        if t.contains(".") && !t.contains(" ") && t.count <= 200 {
            guard let re = urlTokenRegex else { return false }
            let range = NSRange(t.startIndex..., in: t)
            return re.firstMatch(in: t, options: [], range: range) != nil
        }
        return false
    }
}

// ===========================================================================
// MARK: - Action model
// ===========================================================================

/// One pill button in the smart actions bar.
struct StageSmartAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    /// When true, the button is rendered `.borderedProminent`. Reserved for
    /// the *primary* action of the bag (e.g. "Merge into one PDF").
    let primary: Bool
    let perform: () -> Void
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct StageSmartActionsBar: View {
    let items: [StagedItem]

    // P1: cache reduceMotion via @Environment instead of querying NSWorkspace on every render.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // P1: Reduce Transparency guard.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // red-team: `StagedItem` is an internal type in main.swift, so this
    // initializer can't be marked `public`. Module-internal access is all
    // we need — `StageView` lives in the same module.
    init(items: [StagedItem]) {
        self.items = items
    }

    public var body: some View {
        smartActionsContent
    }

    @ViewBuilder
    private var smartActionsContent: some View {
        // P1: show a brief informational label instead of silently showing EmptyView
        // when the bag is too large for Smart Actions to classify.
        if items.count > 200 {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.troveFgMute)
                Text("Too many items for Smart Actions (\(items.count) of 200 max)")
                    .font(.caption)
                    .foregroundStyle(Color.troveFgDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else {
            SmartActionsBar(
                actions: Self.actions(for: items),
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            )
        }
    }
}

// Private helper view so @ViewBuilder doesn't need `let` inside a branch.
private struct SmartActionsBar: View {
    let actions: [StageSmartAction]
    let reduceMotion: Bool
    let reduceTransparency: Bool

    var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Smart actions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Divider().frame(height: 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(actions) { a in
                            if a.primary {
                                Button(action: a.perform) {
                                    Label(a.title, systemImage: a.icon)
                                }
                                .controlSize(.regular)
                                .buttonStyle(.borderedProminent)
                                .help(a.title)
                            } else {
                                Button(action: a.perform) {
                                    Label(a.title, systemImage: a.icon)
                                }
                                .controlSize(.regular)
                                .buttonStyle(.bordered)
                                .help(a.title)
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // P1: Reduce-Transparency guard — solid token fallback.
            .background(
                reduceTransparency ? Color.troveBgElev : Color.troveBgElev.opacity(0.8),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
            // P1: use cached @Environment reduceMotion instead of NSWorkspace per-render.
            .transition(reduceMotion
                        ? .identity
                        : .move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Smart actions for staged items")
        }
    }

} // end SmartActionsBar

// ===========================================================================
// MARK: - Rule table (pure function — testable without SwiftUI runtime)
// ===========================================================================

extension StageSmartActionsBar {
    /// Build the action set for the current bag.
    /// Exposed as `static` so tests can call it without a SwiftUI runtime.
    static func actions(for items: [StagedItem]) -> [StageSmartAction] {
        guard !items.isEmpty else { return [] }
        // red-team: cap classification work. If a user drag-drops their
        // entire Downloads folder onto the Stage (5000 items), running the
        // `allPDFs` / `allImages` short-circuits is still 5000 syscalls of
        // path-extension lookup per render. Stage mutates frequently during a
        // drag — we'd be doing this 60+ times. Smart actions are only useful
        // for small curated bags anyway, so suppress when the bag is huge.
        // Users who deliberately staged 500 PDFs can still open the PDF Tools
        // pane directly.
        guard items.count <= 200 else { return [] }

        let cls = StageSmartClassifier.self

        // PDFs ----------------------------------------------------------
        if cls.allPDFs(items) {
            let urls = cls.urls(from: items)
            if items.count >= 2 {
                return [
                    .init(title: "Merge into one PDF",
                          icon: "arrow.triangle.merge",
                          primary: true) {
                              Self.dispatchPDF(op: "merge", urls: urls)
                          },
                    .init(title: "Compress all",
                          icon: "arrow.down.right.and.arrow.up.left",
                          primary: false) {
                              Self.dispatchPDF(op: "compress", urls: urls)
                          },
                    .init(title: "Add watermark",
                          icon: "drop.halffull",
                          primary: false) {
                              Self.dispatchPDF(op: "watermark", urls: urls)
                          },
                ]
            } else {
                // Single PDF.
                return [
                    .init(title: "Organize pages",
                          icon: "square.grid.3x3",
                          primary: true) {
                              Self.dispatchPDF(op: "organize", urls: urls)
                          },
                    .init(title: "Compress",
                          icon: "arrow.down.right.and.arrow.up.left",
                          primary: false) {
                              Self.dispatchPDF(op: "compress", urls: urls)
                          },
                    .init(title: "OCR",
                          icon: "doc.text.viewfinder",
                          primary: false) {
                              Self.dispatchOCR(urls: urls)
                          },
                    .init(title: "Add page numbers",
                          icon: "number",
                          primary: false) {
                              Self.dispatchPDF(op: "pageNumbers", urls: urls)
                          },
                ]
            }
        }

        // Images --------------------------------------------------------
        if cls.allImages(items) {
            let urls = cls.urls(from: items)
            if items.count >= 2 {
                return [
                    .init(title: "Convert all",
                          icon: "wand.and.stars",
                          primary: true) {
                              Self.dispatchImages(op: nil, urls: urls)
                          },
                    .init(title: "Combine into a PDF",
                          icon: "doc.on.doc",
                          primary: false) {
                              Self.dispatchPDF(op: "imagesToPDF", urls: urls)
                          },
                    .init(title: "Shrink for chat",
                          icon: "arrow.down.right.and.arrow.up.left",
                          primary: false) {
                              Self.dispatchImages(op: "shrinkForChat", urls: urls)
                          },
                ]
            } else {
                // Single image. Spec says: keep palette + OCR; skip QR.
                return [
                    .init(title: "Resize / convert",
                          icon: "wand.and.stars",
                          primary: true) {
                              Self.dispatchImages(op: "resize", urls: urls)
                          },
                    .init(title: "OCR this image",
                          icon: "doc.text.viewfinder",
                          primary: false) {
                              Self.dispatchOCR(urls: urls)
                          },
                    .init(title: "Pick palette colors",
                          icon: "paintpalette",
                          primary: false) {
                              Self.dispatchColor(urls: urls)
                          },
                ]
            }
        }

        // Text ----------------------------------------------------------
        if cls.allText(items) {
            let joined = cls.joinedText(items)
            var out: [StageSmartAction] = [
                .init(title: "Run text transforms",
                      icon: "textformat",
                      primary: true) {
                          Self.dispatchXform(text: joined)
                      },
                .init(title: "Add to Snippets",
                      icon: "tray.and.arrow.down",
                      primary: false) {
                          Self.dispatchSnippets(text: joined)
                      },
            ]
            // QR only when there's a single short URL-looking payload.
            if items.count == 1, cls.looksLikeShortURL(joined) {
                out.append(.init(title: "Generate QR",
                                 icon: "qrcode",
                                 primary: false) {
                    Self.dispatchQR(text: joined)
                })
            }
            return out
        }

        // Mixed bag — no auto-suggestions.
        return []
    }

    // -------------------------------------------------------------------
    // Dispatchers — wrap NotificationCenter posting and red-team #1
    // (dead URLs) so each rule body stays one line.
    // -------------------------------------------------------------------

    private static func dispatchPDF(op: String, urls: [URL]) {
        let (live, dead) = StageSmartClassifier.existing(urls)
        if live.isEmpty {
            SharedStore.stage.flash("Smart action: all files missing")
            return
        }
        if !dead.isEmpty {
            SharedStore.stage.flash("\(dead.count) item\(dead.count == 1 ? "" : "s") missing, proceeding with the rest")
        }
        StageSmartActionQueue.shared.post(
            .troveSmartOpenInPDFTool,
            userInfo: [StageSmartKey.urls: live, StageSmartKey.op: op]
        )
    }

    private static func dispatchImages(op: String?, urls: [URL]) {
        let (live, dead) = StageSmartClassifier.existing(urls)
        if live.isEmpty {
            SharedStore.stage.flash("Smart action: all images missing")
            return
        }
        if !dead.isEmpty {
            SharedStore.stage.flash("\(dead.count) item\(dead.count == 1 ? "" : "s") missing, proceeding with the rest")
        }
        var info: [AnyHashable: Any] = [StageSmartKey.urls: live]
        if let op = op { info[StageSmartKey.op] = op }
        StageSmartActionQueue.shared.post(.troveSmartOpenInImageTools, userInfo: info)
    }

    private static func dispatchOCR(urls: [URL]) {
        let (live, dead) = StageSmartClassifier.existing(urls)
        if live.isEmpty {
            SharedStore.stage.flash("Smart action: file missing")
            return
        }
        if !dead.isEmpty {
            SharedStore.stage.flash("\(dead.count) item\(dead.count == 1 ? "" : "s") missing, proceeding with the rest")
        }
        StageSmartActionQueue.shared.post(
            .troveSmartOpenInOCR,
            userInfo: [StageSmartKey.urls: live, StageSmartKey.op: "ocr"]
        )
    }

    private static func dispatchColor(urls: [URL]) {
        let (live, dead) = StageSmartClassifier.existing(urls)
        if live.isEmpty {
            SharedStore.stage.flash("Smart action: image missing")
            return
        }
        if !dead.isEmpty {
            SharedStore.stage.flash("\(dead.count) item\(dead.count == 1 ? "" : "s") missing, proceeding with the rest")
        }
        StageSmartActionQueue.shared.post(
            .troveSmartOpenInColor,
            userInfo: [StageSmartKey.urls: live]
        )
    }

    private static func dispatchXform(text: String) {
        StageSmartActionQueue.shared.post(
            .troveSmartOpenInXform,
            userInfo: [StageSmartKey.text: text]
        )
    }

    private static func dispatchSnippets(text: String) {
        StageSmartActionQueue.shared.post(
            .troveSmartOpenInSnippets,
            userInfo: [StageSmartKey.text: text]
        )
    }

    private static func dispatchQR(text: String) {
        StageSmartActionQueue.shared.post(
            .troveSmartOpenInQR,
            userInfo: [StageSmartKey.text: text]
        )
    }
}

// ===========================================================================
// MARK: - (AnyButtonStyle removed)
// ===========================================================================
//
// red-team: the previous AnyButtonStyle wrapper rebuilt a Button inside its
// own `makeBody`, which caused a double-fire on macOS 14 trackpad taps and
// fought SwiftUI's gesture system. Replaced with an `if a.primary` branch in
// the view body — SwiftUI happily picks the concrete `BorderedProminentButtonStyle`
// vs `BorderedButtonStyle` at compile time that way.
