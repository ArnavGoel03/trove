// app_intents.swift — Trove's AppIntents surface.
//
// Exposes Trove's most-useful actions to macOS Shortcuts, Spotlight, Focus
// filters, AppleScript automation, and Siri. Every intent reuses an
// existing in-app code path so this file is pure plumbing — no business
// logic lives here that isn't also reachable via the UI. Intents run
// silently in the background by default (openAppWhenRun = false), so a
// Shortcut that calls "Add Text to Trove Stage" doesn't steal focus
// from the user's current app.
//
// Conventions:
//   * Title strings start with a verb in user-facing form ("Add", "Open",
//     "Capture") so they read naturally in the Shortcuts catalogue.
//   * Every intent has an IntentDescription so users browsing the
//     Shortcuts library understand what it does without running it.
//   * Intents that produce content (QR, Hash) return an `IntentFile` /
//     `String` so the result can be piped into the next Shortcut step.
//   * `@MainActor` is applied to the perform() of any intent that touches
//     SharedStore.stage or other MainActor-isolated state.
//   * Macros < macOS 13 are gated via `@available(macOS 13.0, *)`. Trove's
//     deployment target is 13.0 so every intent is reachable from a real
//     Trove build.
//
// What ships here (v1.1.0-beta.11):
//
//   Navigation:
//     • OpenPaneIntent
//
//   Stage actions:
//     • AddTextToStageIntent
//     • AddFileToStageIntent
//     • PasteClipboardToStageIntent
//     • CaptureScreenshotToStageIntent
//     • CopyStageAsFilesIntent
//     • CopyStageAsTextIntent
//     • ClearStageIntent
//     • GetStageCountIntent
//
//   Producers (return a value or file to the Shortcut pipeline):
//     • EvaluateExpressionIntent       → String
//     • GenerateQRCodeIntent           → IntentFile (PNG)
//     • HashFileIntent                 → String (multi-line hash block)
//
//   AppShortcutsProvider declaring 5 default phrases so the user gets a
//   working catalogue on first launch without configuring anything.
//
// What's deliberately NOT here yet:
//   • Snippets entity intents — SnippetStore is per-view @StateObject,
//     not a singleton. Adding a `SnippetIndex` actor for cross-process
//     read access is its own pass.
//   • History entity intents — same singleton-access concern.
//   • PDF tools intents — PDF ops are interactive (multi-source drops,
//     ranges, etc.); a single-parameter intent would underserve the
//     real workflow. Better as a follow-up with custom parameter types.

import AppIntents
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - AppEnum: Pane (used by OpenPaneIntent)
// ===========================================================================

/// A flat, Shortcuts-pickable enum of every pane the user can navigate to.
/// Cases are deliberately ordered to match the sidebar so the dropdown the
/// user sees in the Shortcuts editor mirrors the in-app order.
@available(macOS 13.0, *)
enum PaneIntentEnum: String, AppEnum {
    // Clipboard
    case stage, history, snippets, notes
    // Compute
    case calculator, textTools
    // Capture
    case color, qr, ocr, recorder, snip, mirror
    // Files
    case imageTools, pdfTools, hash, rename
    // System
    case windowSnap, switcher, moveFiles, finder, processes
    // Storage
    case overview, scan, clean, sweep, library
    // Tools
    case keepAwake, permissions, log, gpu, diskSpeed, network
    // Profile
    case account

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Trove Pane"

    static var caseDisplayRepresentations: [PaneIntentEnum: DisplayRepresentation] = [
        .stage:       "Stage",
        .history:     "Clipboard History",
        .snippets:    "Snippets",
        .notes:       "Notes",
        .calculator:  "Calculator",
        .textTools:   "Text Tools",
        .color:       "Color",
        .qr:          "QR",
        .ocr:         "OCR",
        .recorder:    "Recorder",
        .snip:        "Snip",
        .mirror:      "Mirror",
        .imageTools:  "Image Tools",
        .pdfTools:    "PDF Tools",
        .hash:        "Hash",
        .rename:      "Rename",
        .windowSnap:  "Window Snap",
        .switcher:    "App Switcher",
        .moveFiles:   "Move Files",
        .finder:      "Finder Tweaks",
        .processes:   "Processes",
        .overview:    "Disk Overview",
        .scan:        "Deep Scan",
        .clean:       "Clean Dev Caches",
        .sweep:       "Sweep Downloads",
        .library:     "Library",
        .keepAwake:   "Keep Awake",
        .permissions: "Permissions",
        .log:         "System Log",
        .gpu:         "GPU Monitor",
        .diskSpeed:   "Disk Speed",
        .network:     "Network",
        .account:     "Account",
    ]

    /// Map back to the in-app `Pane` enum's raw value (UserDefaults key
    /// `trove.selectedPane` reads it). Keep in sync with `enum Pane` in
    /// main.swift; if a pane's rawValue ever drifts, fix the right-hand
    /// side here too.
    var paneRawValue: String {
        switch self {
        case .stage:       return "Stage"
        case .history:     return "History"
        case .snippets:    return "Snippets"
        case .notes:       return "Notes"
        case .calculator:  return "Calculator"
        case .textTools:   return "Text Tools"
        case .color:       return "Color"
        case .qr:          return "QR"
        case .ocr:         return "OCR"
        case .recorder:    return "Record"
        case .snip:        return "Snip"
        case .mirror:      return "Mirror"
        case .imageTools:  return "Image Tools"
        case .pdfTools:    return "PDF"
        case .hash:        return "Hash"
        case .rename:      return "Rename"
        case .windowSnap:  return "Snap"
        case .switcher:    return "Switcher"
        case .moveFiles:   return "Move Files"
        case .finder:      return "Finder"
        case .processes:   return "Processes"
        case .overview:    return "Overview"
        case .scan:        return "Scan"
        case .clean:       return "Clean"
        case .sweep:       return "Sweep"
        case .library:     return "Library"
        case .keepAwake:   return "Awake"
        case .permissions: return "Permissions"
        case .log:         return "Log"
        case .gpu:         return "GPU"
        case .diskSpeed:   return "Disk Speed"
        case .network:     return "Network"
        case .account:     return "Account"
        }
    }
}

// ===========================================================================
// MARK: - OpenPaneIntent
// ===========================================================================

@available(macOS 13.0, *)
struct OpenPaneIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Pane in Trove"
    static var description = IntentDescription(
        "Switch the Trove window to a specific pane.",
        categoryName: "Navigation"
    )

    @Parameter(title: "Pane")
    var pane: PaneIntentEnum

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(pane.paneRawValue, forKey: "trove.selectedPane")
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$pane) in Trove")
    }
}

// ===========================================================================
// MARK: - Stage actions
// ===========================================================================

@available(macOS 13.0, *)
struct AddTextToStageIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Text to Trove Stage"
    static var description = IntentDescription(
        "Adds a piece of text as a new staged item. Stage is Trove's flagship multi-clipboard — items survive quits and can be copied/dragged out together.",
        categoryName: "Stage"
    )

    @Parameter(title: "Text")
    var text: String

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        SharedStore.stage.addText(text)
        return .result(value: text)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Trove Stage")
    }
}

@available(macOS 13.0, *)
struct AddFileToStageIntent: AppIntent {
    static var title: LocalizedStringResource = "Add File to Trove Stage"
    static var description = IntentDescription(
        "Adds a file to Stage so it can be dragged out / copied / sent elsewhere later.",
        categoryName: "Stage"
    )

    @Parameter(title: "File",
               supportedTypeIdentifiers: ["public.item"])
    var file: IntentFile

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = file.fileURL else {
            throw TroveIntentError.fileURLMissing
        }
        SharedStore.stage.addFile(url)
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$file) to Trove Stage")
    }
}

@available(macOS 13.0, *)
struct PasteClipboardToStageIntent: AppIntent {
    static var title: LocalizedStringResource = "Paste Clipboard to Trove Stage"
    static var description = IntentDescription(
        "Pulls the current clipboard contents into Trove's Stage, the same as pressing ⌘⇧V in the app.",
        categoryName: "Stage"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.stage.pasteFromClipboard()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureScreenshotToStageIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Screenshot to Trove Stage"
    static var description = IntentDescription(
        "Triggers an interactive screen capture (⌘⇧4-style crosshair) and adds the result to Stage.",
        categoryName: "Stage"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.stage.captureScreenshot()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CopyStageAsFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Trove Stage as Files"
    static var description = IntentDescription(
        "Copies every staged item to the system clipboard as files (file URLs). Equivalent to ⌘⇧C in the app.",
        categoryName: "Stage"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.stage.copyAllAsFiles()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CopyStageAsTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Trove Stage as Text"
    static var description = IntentDescription(
        "Joins every staged text item into one string and copies it to the system clipboard. Equivalent to ⌘⇧⌥C in the app.",
        categoryName: "Stage"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.stage.copyAllAsText()
        return .result()
    }
}

@available(macOS 13.0, *)
struct ClearStageIntent: AppIntent {
    static var title: LocalizedStringResource = "Clear Trove Stage"
    static var description = IntentDescription(
        "Removes every staged item. This is destructive; pair with a Shortcuts confirmation step if needed.",
        categoryName: "Stage"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.stage.items.removeAll()
        SharedStore.stage.schedulePersist()
        return .result()
    }
}

@available(macOS 13.0, *)
struct GetStageCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Trove Stage Item Count"
    static var description = IntentDescription(
        "Returns the number of items currently in Stage so a Shortcut can branch on it (e.g., \"if more than 0, send to email…\").",
        categoryName: "Stage"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        return .result(value: SharedStore.stage.items.count)
    }
}

// ===========================================================================
// MARK: - Producers — return content into the Shortcut pipeline
// ===========================================================================

@available(macOS 13.0, *)
struct EvaluateExpressionIntent: AppIntent {
    static var title: LocalizedStringResource = "Evaluate Expression with Trove"
    static var description = IntentDescription(
        "Runs the input through Trove's Soulver-class calculator engine. Supports variables, units, percentages, currency conversion, and references to previous lines.",
        categoryName: "Compute"
    )

    @Parameter(title: "Expression")
    var expression: String

    @Parameter(title: "Angle unit",
               default: AngleUnitIntentEnum.degrees)
    var angleUnit: AngleUnitIntentEnum

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let eval = CalcEvaluator()
        let unit: AngleUnit = (angleUnit == .degrees ? .degrees : .radians)
        let results = eval.evaluate(text: expression, angleUnit: unit)
        // The user typically wants the LAST line's value (matches what
        // CalcView's "Copy result" surfaces). Falling back to the joined
        // multi-line block for multi-line expressions where every result
        // is meaningful.
        if results.count == 1 {
            return .result(value: results[0].display)
        }
        let joined = results.map { $0.display }.joined(separator: "\n")
        return .result(value: joined)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Evaluate \(\.$expression) (\(\.$angleUnit))")
    }
}

@available(macOS 13.0, *)
enum AngleUnitIntentEnum: String, AppEnum {
    case degrees, radians

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Angle Unit"

    static var caseDisplayRepresentations: [AngleUnitIntentEnum: DisplayRepresentation] = [
        .degrees: "Degrees",
        .radians: "Radians",
    ]
}

@available(macOS 13.0, *)
struct GenerateQRCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Generate QR Code with Trove"
    static var description = IntentDescription(
        "Renders the input text or URL as a QR code (PNG) and returns the file so it can be saved, attached, or shared in the next Shortcut step.",
        categoryName: "Capture"
    )

    @Parameter(title: "Text or URL")
    var content: String

    @Parameter(title: "Size in pixels",
               default: 1024)
    var size: Int

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        // Map the size parameter into the renderer's CGFloat target.
        let target = CGFloat(max(64, min(size, 4096)))
        let img: NSImage
        do {
            img = try QRGenerator.render(content,
                                          correction: .M,
                                          targetSize: target,
                                          fgColor: .black,
                                          bgColor: .white)
        } catch {
            throw TroveIntentError.qrEncodingFailed
        }
        // PNG-encode + write to a temp file. IntentFile is the canonical
        // way to hand a file off to the next Shortcuts step.
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { throw TroveIntentError.qrEncodingFailed }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-qr-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: tmp, options: .atomic)
        return .result(value: IntentFile(fileURL: tmp))
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Generate QR code for \(\.$content) at \(\.$size) pixels")
    }
}

@available(macOS 13.0, *)
struct HashFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Hash File with Trove"
    static var description = IntentDescription(
        "Computes MD5, SHA-1, SHA-256, and SHA-512 of the input file in one streaming pass. Returns a multi-line block suitable for paste-into-issue / verify-checksum workflows.",
        categoryName: "Files"
    )

    @Parameter(title: "File",
               supportedTypeIdentifiers: ["public.item"])
    var file: IntentFile

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let url = file.fileURL else { throw TroveIntentError.fileURLMissing }
        let (md5, sha1, sha2, sha5) = try await computeHashes(of: url, progress: { _ in })
        let lines = [
            "MD5:    \(md5)",
            "SHA1:   \(sha1)",
            "SHA256: \(sha2)",
            "SHA512: \(sha5)",
        ]
        return .result(value: lines.joined(separator: "\n"))
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Hash \(\.$file)")
    }
}

// ===========================================================================
// MARK: - AppShortcutsProvider — default phrases
// ===========================================================================

/// Ships a starter set of 5 voice-/Spotlight-friendly phrases so the user
/// gets a working Trove Shortcuts catalogue on first launch without
/// configuring anything. The `\(.applicationName)` placeholder is required;
/// macOS substitutes the localized app name at runtime.
@available(macOS 13.0, *)
struct TroveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PasteClipboardToStageIntent(),
            phrases: [
                "Paste to \(.applicationName) Stage",
                "Send clipboard to \(.applicationName)",
            ],
            shortTitle: "Paste Clipboard to Stage",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: CaptureScreenshotToStageIntent(),
            phrases: [
                "Capture screenshot with \(.applicationName)",
                "Screenshot to \(.applicationName) Stage",
            ],
            shortTitle: "Capture Screenshot to Stage",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: AddTextToStageIntent(),
            phrases: [
                "Add text to \(.applicationName) Stage",
            ],
            shortTitle: "Add Text to Stage",
            systemImageName: "text.alignleft"
        )
        AppShortcut(
            intent: EvaluateExpressionIntent(),
            phrases: [
                "Calculate with \(.applicationName)",
                "Evaluate with \(.applicationName)",
            ],
            shortTitle: "Evaluate Expression",
            systemImageName: "function"
        )
        AppShortcut(
            intent: GenerateQRCodeIntent(),
            phrases: [
                "Generate QR code with \(.applicationName)",
            ],
            shortTitle: "Generate QR Code",
            systemImageName: "qrcode"
        )
    }
}

// ===========================================================================
// MARK: - Errors
// ===========================================================================

enum TroveIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case fileURLMissing
    case qrEncodingFailed
    case snippetNotFound(String)
    case clipboardIndexOutOfRange(Int, Int)
    case clipboardEntryNotText

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .fileURLMissing:
            return "Couldn't read the file URL from the Shortcut input."
        case .qrEncodingFailed:
            return "Couldn't encode the QR image as PNG."
        case .snippetNotFound(let name):
            return "No Trove snippet named \"\(name)\" — try the picker variant of this intent."
        case .clipboardIndexOutOfRange(let i, let n):
            return "Clipboard history has \(n) item\(n == 1 ? "" : "s"); index \(i) is out of range."
        case .clipboardEntryNotText:
            return "That clipboard entry isn't text (it's an image or file). Use \"Get Recent Clipboard Text\" to skip non-text entries."
        }
    }
}

// ===========================================================================
// MARK: - SnippetIndex — cross-process read-only access to snippets.json
// ===========================================================================
//
// `SnippetStore` is per-view `@StateObject` so it isn't reachable from
// AppIntents (which run out-of-process in `xpcd_helper` / Shortcuts'
// extension host). `SnippetIndex` is a read-only snapshot read directly
// from the on-disk JSON the store persists. No locks, no mutation — the
// intents that match this index call back into the running app (via a
// `URL(string: "trove://...")` open) when they need to MUTATE state; for
// pure read intents (Get Snippet by Name, Get Snippet, List Snippets)
// this is sufficient.

@available(macOS 13.0, *)
enum SnippetIndex {

    private static var jsonURL: URL? {
        // Power-user item #8: AppIntents reads must consult TrovePaths
        // so a user who opted into XDG still gets the right snippet
        // library inside Shortcuts.
        TrovePaths.appSupportDir.appendingPathComponent("snippets.json")
    }

    /// Loads + decodes the persisted snippet library. Returns an empty
    /// array on first-launch (file missing) / corrupt / unreadable — the
    /// caller surfaces a friendly error instead of crashing.
    static func read() -> [Snippet] {
        guard let url = jsonURL,
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Snippet].self, from: data)) ?? []
    }
}

// ===========================================================================
// MARK: - SnippetEntity + EntityQuery (picker support in Shortcuts)
// ===========================================================================

@available(macOS 13.0, *)
struct SnippetEntity: AppEntity, Identifiable {
    var id: UUID
    @Property(title: "Name")
    var name: String
    @Property(title: "Body")
    var body: String

    init(snippet: Snippet) {
        self.id = snippet.id
        self.name = snippet.name
        self.body = snippet.body
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Snippet", numericFormat: "\(placeholder: .int) snippets")

    var displayRepresentation: DisplayRepresentation {
        let preview = body.replacingOccurrences(of: "\n", with: " ")
        let snippet = String(preview.prefix(80))
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: snippet.isEmpty ? "Empty snippet" : "\(snippet)"
        )
    }

    static var defaultQuery = SnippetEntityQuery()
}

@available(macOS 13.0, *)
struct SnippetEntityQuery: EntityQuery {

    /// Resolve a set of IDs (used after the user has picked one in the
    /// Shortcuts editor and the saved Shortcut later runs).
    func entities(for identifiers: [UUID]) async throws -> [SnippetEntity] {
        let all = SnippetIndex.read()
        return all
            .filter { identifiers.contains($0.id) }
            .map(SnippetEntity.init(snippet:))
    }

    /// Suggest entities for the dropdown picker in the Shortcuts editor.
    /// Returns the user's whole library so the suggested list doubles as
    /// a "snippet browser." Capped at 200 to keep the picker snappy.
    func suggestedEntities() async throws -> [SnippetEntity] {
        let all = SnippetIndex.read()
        return all.prefix(200).map(SnippetEntity.init(snippet:))
    }
}

@available(macOS 13.0, *)
extension SnippetEntityQuery: EntityStringQuery {
    /// Implements live filtering as the user types into the picker.
    func entities(matching string: String) async throws -> [SnippetEntity] {
        let q = string.lowercased()
        if q.isEmpty { return try await suggestedEntities() }
        let all = SnippetIndex.read()
        return all
            .filter { $0.name.lowercased().contains(q) || $0.body.lowercased().contains(q) }
            .map(SnippetEntity.init(snippet:))
    }
}

// ===========================================================================
// MARK: - Snippet intents
// ===========================================================================

@available(macOS 13.0, *)
struct GetSnippetIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Trove Snippet"
    static var description = IntentDescription(
        "Returns the body of a Trove snippet. The Shortcuts editor shows a picker so the user selects which snippet to use; the picker filters by name + body content as the user types.",
        categoryName: "Snippets"
    )

    @Parameter(title: "Snippet")
    var snippet: SnippetEntity

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: snippet.body)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$snippet) from Trove")
    }
}

@available(macOS 13.0, *)
struct GetSnippetByNameIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Trove Snippet by Name"
    static var description = IntentDescription(
        "Returns the body of the first Trove snippet whose name matches the input. Useful in Shortcuts that compute the snippet name dynamically (e.g., from a date). Falls back to case-insensitive substring match.",
        categoryName: "Snippets"
    )

    @Parameter(title: "Name")
    var name: String

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let all = SnippetIndex.read()
        let q = name.lowercased()
        // Exact-name match first; then case-insensitive starts-with; then contains.
        if let exact = all.first(where: { $0.name.lowercased() == q }) {
            return .result(value: exact.body)
        }
        if let prefix = all.first(where: { $0.name.lowercased().hasPrefix(q) }) {
            return .result(value: prefix.body)
        }
        if let partial = all.first(where: { $0.name.lowercased().contains(q) }) {
            return .result(value: partial.body)
        }
        throw TroveIntentError.snippetNotFound(name)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Get Trove snippet named \(\.$name)")
    }
}

@available(macOS 13.0, *)
struct ListSnippetsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Trove Snippets"
    static var description = IntentDescription(
        "Returns an array of every snippet name. Pipe into a Shortcuts Choose-from-Menu step for a custom-styled picker.",
        categoryName: "Snippets"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let names = SnippetIndex.read().map { $0.name }
        return .result(value: names)
    }
}

@available(macOS 13.0, *)
struct CountSnippetsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Trove Snippet Count"
    static var description = IntentDescription(
        "Returns how many snippets are currently in the user's library. Useful for conditional Shortcuts (e.g., \"if more than 100, run cleanup\").",
        categoryName: "Snippets"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        return .result(value: SnippetIndex.read().count)
    }
}

// ===========================================================================
// MARK: - ClipboardIndex — cross-process read of clipboard_history.json
// ===========================================================================
//
// Mirrors the file shape `ClipHistory` writes. `ClipEntryCodable` is
// `fileprivate` in history.swift so we use a parallel decoder here that
// matches the same on-disk JSON. We accept all three kinds (text / image
// path / file path); intents that return text bail on non-text entries
// with a friendly error.

@available(macOS 13.0, *)
enum ClipboardIndex {

    private static var jsonURL: URL? {
        TrovePaths.appSupportDir.appendingPathComponent("clipboard_history.json")
    }

    struct Entry: Identifiable {
        let id: UUID
        let kind: Kind
        let capturedAt: Date
        let pinned: Bool

        enum Kind { case text(String), imagePath(String), filePath(String) }

        /// Short, single-line summary mirroring `ClipEntry.summary`.
        var summary: String {
            switch kind {
            case .text(let s):
                return String(s.replacingOccurrences(of: "\n", with: " ").prefix(80))
            case .imagePath(let p):
                return "Image · " + (p as NSString).lastPathComponent
            case .filePath(let p):
                return "File · " + (p as NSString).lastPathComponent
            }
        }

        var kindLabel: String {
            switch kind {
            case .text:      return "Text"
            case .imagePath: return "Image"
            case .filePath:  return "File"
            }
        }

        /// `nil` for non-text entries — caller decides what to do.
        var textBody: String? {
            if case .text(let s) = kind { return s }
            return nil
        }
    }

    /// Parallel-decodes `clipboard_history.json` into `[Entry]`. Returns
    /// empty on first-launch / corrupt / unreadable — never throws.
    static func read() -> [Entry] {
        guard let url = jsonURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return [] }
        struct JSONEntry: Decodable {
            let id: UUID
            let kind: JSONKind
            let capturedAt: Date
            let pinned: Bool
        }
        struct JSONKind: Decodable {
            let type: String
            let value: String
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let arr = try? decoder.decode([JSONEntry].self, from: data) else {
            return []
        }
        return arr.map { je in
            let k: Entry.Kind
            switch je.kind.type {
            case "imagePath": k = .imagePath(je.kind.value)
            case "filePath":  k = .filePath(je.kind.value)
            default:          k = .text(je.kind.value)
            }
            return Entry(id: je.id, kind: k, capturedAt: je.capturedAt, pinned: je.pinned)
        }
    }
}

// ===========================================================================
// MARK: - ClipboardEntryEntity + EntityQuery (history picker in Shortcuts)
// ===========================================================================

@available(macOS 13.0, *)
struct ClipboardEntryEntity: AppEntity, Identifiable {
    var id: UUID
    @Property(title: "Preview")
    var preview: String
    @Property(title: "Captured at")
    var capturedAt: Date
    @Property(title: "Kind")
    var kind: String
    @Property(title: "Pinned")
    var pinned: Bool

    init(entry: ClipboardIndex.Entry) {
        self.id = entry.id
        self.preview = entry.summary
        self.capturedAt = entry.capturedAt
        self.kind = entry.kindLabel
        self.pinned = entry.pinned
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Clipboard Entry",
                                  numericFormat: "\(placeholder: .int) clipboard entries")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(preview)",
                              subtitle: "\(kind) · \(capturedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    static var defaultQuery = ClipboardEntryEntityQuery()
}

@available(macOS 13.0, *)
struct ClipboardEntryEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ClipboardEntryEntity] {
        ClipboardIndex.read()
            .filter { identifiers.contains($0.id) }
            .map(ClipboardEntryEntity.init(entry:))
    }

    func suggestedEntities() async throws -> [ClipboardEntryEntity] {
        ClipboardIndex.read()
            .prefix(60)
            .map(ClipboardEntryEntity.init(entry:))
    }
}

@available(macOS 13.0, *)
extension ClipboardEntryEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [ClipboardEntryEntity] {
        let q = string.lowercased()
        if q.isEmpty { return try await suggestedEntities() }
        return ClipboardIndex.read()
            .filter { $0.summary.lowercased().contains(q) || ($0.textBody?.lowercased().contains(q) == true) }
            .map(ClipboardEntryEntity.init(entry:))
    }
}

// ===========================================================================
// MARK: - Clipboard history intents
// ===========================================================================

@available(macOS 13.0, *)
struct GetClipboardHistoryAtIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Trove Clipboard History Item"
    static var description = IntentDescription(
        "Returns the text content of the clipboard history entry at the given index. Index 0 = most recent capture. Throws if the index is out of range OR the entry isn't text — use \"Get Recent Clipboard Text\" if you only care about text and want to skip image/file entries.",
        categoryName: "History"
    )

    @Parameter(title: "Index (0 = most recent)", default: 0)
    var index: Int

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let all = ClipboardIndex.read()
        guard index >= 0, index < all.count else {
            throw TroveIntentError.clipboardIndexOutOfRange(index, all.count)
        }
        guard let body = all[index].textBody else {
            throw TroveIntentError.clipboardEntryNotText
        }
        return .result(value: body)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Get Trove clipboard history item at index \(\.$index)")
    }
}

@available(macOS 13.0, *)
struct GetRecentClipboardTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Recent Trove Clipboard Text"
    static var description = IntentDescription(
        "Returns the body of the N-th most recent TEXT entry, skipping any image/file captures. Useful for \"give me my last URL\" / \"give me the 2nd-most-recent code snippet\" workflows.",
        categoryName: "History"
    )

    @Parameter(title: "Skip count (0 = most recent text)", default: 0)
    var skip: Int

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let texts = ClipboardIndex.read().compactMap { $0.textBody }
        guard skip >= 0, skip < texts.count else {
            throw TroveIntentError.clipboardIndexOutOfRange(skip, texts.count)
        }
        return .result(value: texts[skip])
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$skip)-skipped recent Trove clipboard text")
    }
}

@available(macOS 13.0, *)
struct CountClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Trove Clipboard History Count"
    static var description = IntentDescription(
        "Returns the total number of entries in clipboard history (text + image + file combined).",
        categoryName: "History"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        return .result(value: ClipboardIndex.read().count)
    }
}

@available(macOS 13.0, *)
struct PickClipboardEntryIntent: AppIntent {
    static var title: LocalizedStringResource = "Pick Trove Clipboard Entry"
    static var description = IntentDescription(
        "Surfaces a picker of all clipboard history entries (with previews + kind + date) and returns the text body of the chosen entry. Skips with a friendly error if the user picks an image / file entry.",
        categoryName: "History"
    )

    @Parameter(title: "Clipboard Entry")
    var entry: ClipboardEntryEntity

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let body = ClipboardIndex.read().first(where: { $0.id == entry.id })?.textBody else {
            throw TroveIntentError.clipboardEntryNotText
        }
        return .result(value: body)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Pick Trove clipboard entry \(\.$entry)")
    }
}
