// customization_settings.swift — pro-level Settings cards for Trove.
//
// Bundles four large customization surfaces under one file so they're easy
// to find and extend:
//
//   1. AccessibilitySettingsCard
//        — Reduce-motion respect, increase-contrast hints, VoiceOver
//          announcement verbosity, dynamic-type preview, keyboard-focus
//          ring style, per-pane accessibility shortcuts inventory.
//
//   2. UIDensitySettingsCard
//        — Compact / Default / Comfortable density, sidebar width slider,
//          card corner radius, base font scale (independent of system
//          Dynamic Type), toast lifetime, hover-reveal timing.
//
//   3. KeyboardShortcutsSettingsCard
//        — Catalogue of every shortcut Trove ships with, organised by
//          surface (App / File / Edit / View / Tools / per-pane). Each
//          row exposes the chord visually + a one-line action description.
//          Read-only display today; the per-row recorder lives in the
//          existing HotkeySettingsCard for the global hotkeys this card
//          links to.
//
//   4. DefaultsSettingsCard
//        — Per-pane default save folders (PDF / Image Tools / Recorder /
//          Snip / OCR / QR / Color), default new-tab body for Notes,
//          default snippet sort, default calc angle unit, default
//          updater channel display.
//
// All four cards adopt the existing `Card { … }` chrome + `.headerText()`
// pattern, so they slot into CustomizeView without visual breaks. Every
// @AppStorage key is namespaced under `trove.ui.*` (display prefs) or
// `trove.defaults.*` (per-pane defaults) so they round-trip cleanly
// through the profile-sync bundle list.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - UI density model
// ===========================================================================

/// One source-of-truth for compact / default / comfortable density. Every
/// card / list / row in the app reads these values via the existing
/// @AppStorage keys; the picker writes them as a bundle so all the per-axis
/// values move together.
enum TroveUIDensity: String, CaseIterable, Identifiable {
    case compact, `default`, comfortable
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .compact:     return "Compact"
        case .default:     return "Default"
        case .comfortable: return "Comfortable"
        }
    }
    var rowSpacing: CGFloat {
        switch self {
        case .compact:     return 4
        case .default:     return 8
        case .comfortable: return 14
        }
    }
    var cardCornerRadius: CGFloat {
        switch self {
        case .compact:     return 8
        case .default:     return 12
        case .comfortable: return 16
        }
    }
    var basePadding: CGFloat {
        switch self {
        case .compact:     return 8
        case .default:     return 12
        case .comfortable: return 18
        }
    }
    var description: String {
        switch self {
        case .compact:
            return "Tighter rows + smaller corner radii. Best on 13″ laptops."
        case .default:
            return "Balanced spacing — recommended."
        case .comfortable:
            return "Generous padding + larger touch targets. Best on external displays."
        }
    }
}

// ===========================================================================
// MARK: - AccessibilitySettingsCard
// ===========================================================================

/// Surfaces Trove's accessibility posture: which OS-level toggles it
/// respects, which it can't, and the per-pane keyboard inventory the user
/// should know about. No new behaviour is wired here — every toggle is a
/// preference Trove already reads at the relevant code site. This card is
/// the canonical "what's available" surface so the user doesn't have to dig.
struct AccessibilitySettingsCard: View {
    @AppStorage("trove.a11y.respectReduceMotion")
    private var respectReduceMotion: Bool = true

    @AppStorage("trove.a11y.respectReduceTransparency")
    private var respectReduceTransparency: Bool = true

    @AppStorage("trove.a11y.respectIncreaseContrast")
    private var respectIncreaseContrast: Bool = true

    @AppStorage("trove.a11y.announceStateChanges")
    private var announceStateChanges: Bool = true

    @AppStorage("trove.a11y.focusRingStyle")
    private var focusRingStyle: String = "default"

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "accessibility.fill").foregroundStyle(.tint)
                    Text("Accessibility").headerText()
                    Spacer()
                    Text("VoiceOver-first")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.troveAccent.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.troveAccent)
                }
                Text("Trove respects the macOS Accessibility toggles by default. Each switch below lets you opt out of one specific accommodation if it conflicts with your workflow.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $respectReduceMotion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Respect Reduce Motion")
                        Text("Skips card / overlay / preview transitions when System Settings → Accessibility → Display → Reduce Motion is on. Strongly recommended.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $respectReduceTransparency) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Respect Reduce Transparency")
                        Text("Replaces .thinMaterial / .ultraThinMaterial backgrounds with solid palette tokens when Reduce Transparency is on. Required for vestibular-sensitive users.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $respectIncreaseContrast) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Respect Increase Contrast")
                        Text("Strengthens card borders + raises foreground text weight when Increase Contrast is on.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Toggle(isOn: $announceStateChanges) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Announce state changes via VoiceOver")
                        Text("Posts NSAccessibility.announcementRequested for every confirmation toast, recording state transition, and async-completion event. Turn off if your screen reader echoes them already.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Picker("Focus ring style", selection: $focusRingStyle) {
                    Text("Default (system)").tag("default")
                    Text("Bold accent").tag("bold")
                    Text("Subtle border").tag("subtle")
                }
                .pickerStyle(.menu)
                .font(.callout)
                Text("Affects the focus ring shown around keyboard-focused controls. Bold accent uses the active accent color at full opacity.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("Per-pane shortcuts the heading rotor surfaces:")
                    .font(.caption).foregroundStyle(.secondary)
                accessibilityShortcutsList
            }
        }
    }

    private var accessibilityShortcutsList: some View {
        VStack(alignment: .leading, spacing: 3) {
            shortcutRow("⌘1 – ⌘4",  "Jump to Stage / History / Snippets / Notes")
            shortcutRow("⌘K",       "Quick Switcher — fuzzy-find any pane")
            shortcutRow("⌘/",       "Open the Keyboard Shortcuts sheet")
            shortcutRow("⌘,",       "Open Settings")
            shortcutRow("⌘⇧,",      "Customize Sidebar")
            shortcutRow("⌘⇧V",     "Paste clipboard contents into Stage")
            shortcutRow("⌘⇧N",     "Capture screenshot into Stage")
            shortcutRow("⌘⇧C",     "Copy all staged items as files")
            shortcutRow("⌘⇧⌥C",    "Copy all staged items as text")
            shortcutRow("⌘⇧⌫",     "Clear Stage")
            shortcutRow("⌘⌥4",     "Capture region → OCR")
            shortcutRow("⌘⌥5",     "Capture region → Snip")
            shortcutRow("⌘⌥P",     "Pin window on top")
            shortcutRow("⌘⇧F",     "Detach Stage as floating panel")
            shortcutRow("Space",    "Quick Look the focused Stage / Library / History item")
        }
    }

    @ViewBuilder
    private func shortcutRow(_ chord: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(chord)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.troveBgElev, in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 64, alignment: .leading)
            Text(desc).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// ===========================================================================
// MARK: - UIDensitySettingsCard
// ===========================================================================

/// Density + visual customization. Picker writes a single token; downstream
/// view code reads via TroveUIDensity helpers so density changes can be
/// adopted incrementally without touching every card.
struct UIDensitySettingsCard: View {
    @AppStorage("trove.ui.density")
    private var densityRaw: String = TroveUIDensity.default.rawValue

    @AppStorage("trove.ui.sidebarWidth")
    private var sidebarWidth: Double = 224

    @AppStorage("trove.ui.toastLifetime")
    private var toastLifetime: Double = 4.0

    @AppStorage("trove.ui.hoverRevealDelay")
    private var hoverRevealDelay: Double = 0.0

    @AppStorage("trove.ui.compactLists")
    private var compactLists: Bool = false

    @AppStorage("trove.ui.preferDoubleClickActivation")
    private var preferDoubleClickActivation: Bool = false

    private var density: TroveUIDensity {
        get { TroveUIDensity(rawValue: densityRaw) ?? .default }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.compress.vertical").foregroundStyle(.tint)
                    Text("Density & layout").headerText()
                }
                Picker("Density", selection: $densityRaw) {
                    ForEach(TroveUIDensity.allCases) { d in
                        Text(d.displayName).tag(d.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(density.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sidebar width").font(.callout)
                        Spacer()
                        Text("\(Int(sidebarWidth)) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $sidebarWidth, in: 180...320, step: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Toast lifetime").font(.callout)
                        Spacer()
                        Text(String(format: "%.1f s", toastLifetime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $toastLifetime, in: 1.5...12.0, step: 0.5)
                    Text("How long confirmation toasts stay on screen before auto-dismissing. Action toasts (Undo, Retry) get +50% extra.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Hover-reveal delay").font(.callout)
                        Spacer()
                        Text(String(format: "%.0f ms", hoverRevealDelay * 1000))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $hoverRevealDelay, in: 0.0...0.6, step: 0.05)
                    Text("Delay before hover-revealed buttons (Remove, Pin, Copy on each row) appear. Raise this if buttons fire on stray cursor passes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                Toggle(isOn: $compactLists) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Compact list rows")
                        Text("Tighter row height + smaller per-row metadata. Independent of overall density so you can keep cards spacious while lists stay information-dense.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $preferDoubleClickActivation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prefer double-click activation")
                        Text("Single-click selects; double-click opens. macOS-Finder behaviour. Off by default — single-click opens everywhere.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - KeyboardShortcutsSettingsCard
// ===========================================================================

/// Read-only catalogue of every Trove shortcut, grouped by menu surface.
/// Sourced from the same `.commands { }` block in main.swift — keep in
/// sync when adding new shortcuts. The display is informational; the
/// per-row recorder for rebinding lives in HotkeySettingsCard (global
/// hotkey for full-screen-to-Stage) and WindowSnapSettingsCard (per-
/// direction snap shortcuts). Both already ship.
struct KeyboardShortcutsSettingsCard: View {

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard").foregroundStyle(.tint)
                    Text("Keyboard shortcuts").headerText()
                    Spacer()
                    Text("\(totalCount) chords")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("Every chord Trove registers. Per-direction Snap shortcuts and the global-screen-capture chord are rebindable in their own cards below.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(groups, id: \.title) { group in
                    Divider()
                    Text(group.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(group.items, id: \.chord) { item in
                            shortcutRow(item.chord, item.description)
                        }
                    }
                }
            }
        }
    }

    private struct ShortcutGroup { let title: String; let items: [Shortcut] }
    private struct Shortcut { let chord: String; let description: String }

    private var groups: [ShortcutGroup] { [
        ShortcutGroup(title: "App", items: [
            .init(chord: "⌘,",       description: "Settings"),
            .init(chord: "⌘Q",       description: "Quit Trove"),
            .init(chord: "⌘H",       description: "Hide Trove"),
            .init(chord: "⌘⌥H",      description: "Hide other apps"),
            .init(chord: "⌘W",       description: "Close window"),
        ]),
        ShortcutGroup(title: "File", items: [
            .init(chord: "⌘N",       description: "New snippet (switches to Snippets pane)"),
            .init(chord: "⌘O",       description: "Open files into Stage"),
        ]),
        ShortcutGroup(title: "Edit", items: [
            .init(chord: "⌘X / ⌘C / ⌘V", description: "System cut / copy / paste"),
            .init(chord: "⌘Z / ⌘⇧Z", description: "System undo / redo"),
            .init(chord: "⌘⇧V",     description: "Paste clipboard into Stage"),
            .init(chord: "⌘⇧C",     description: "Copy all staged as files"),
            .init(chord: "⌘⇧⌥C",    description: "Copy all staged as text"),
            .init(chord: "⌘⇧N",     description: "Capture screenshot → Stage"),
            .init(chord: "⌘⌥4",     description: "Capture region → OCR"),
            .init(chord: "⌘⌥5",     description: "Capture region → Snip"),
            .init(chord: "⌘⇧⌫",     description: "Clear Stage"),
        ]),
        ShortcutGroup(title: "View", items: [
            .init(chord: "⌘1",       description: "Jump to Stage"),
            .init(chord: "⌘2",       description: "Jump to History"),
            .init(chord: "⌘3",       description: "Jump to Snippets"),
            .init(chord: "⌘4",       description: "Jump to Notes"),
            .init(chord: "⌘K",       description: "Quick Switcher — fuzzy-find any pane"),
            .init(chord: "⌘⌥P",     description: "Pin window on top"),
            .init(chord: "⌘⇧F",     description: "Detach Stage as floating panel"),
            .init(chord: "⌘⇧,",      description: "Customize Sidebar"),
            .init(chord: "⌘/",       description: "Open Keyboard Shortcuts sheet"),
        ]),
        ShortcutGroup(title: "Per-pane", items: [
            .init(chord: "Space",    description: "Quick Look any image/file item in Stage, Library, History"),
            .init(chord: "⌘F",       description: "Search within Notes / Log / Library / Snippets"),
            .init(chord: "⌘⏎",       description: "Run the current op (PDF, Image Tools, etc.)"),
            .init(chord: "⌘P",       description: "Preview the focused output before save"),
            .init(chord: "⌘S",       description: "Save the focused output"),
            .init(chord: "⌘D",       description: "Save the focused output to Downloads"),
            .init(chord: "⌘R",       description: "Reveal the focused output in Finder"),
            .init(chord: "⌘.",       description: "Cancel the current op (where applicable)"),
            .init(chord: "Esc",      description: "Cancel preview / dismiss sheet / Pinpoint exit"),
        ]),
    ] }

    private var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    @ViewBuilder
    private func shortcutRow(_ chord: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(chord)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.troveBgElev, in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 96, alignment: .leading)
            Text(desc).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// ===========================================================================
// MARK: - DefaultsSettingsCard
// ===========================================================================

/// Per-pane default-save-folder picker. Each pane already persists its
/// own "last save dir" — this card lets the user lock in an upstream
/// default that wins until the pane writes a new last-used value.
struct DefaultsSettingsCard: View {
    @AppStorage("trove.defaults.pdfSaveDir")          private var pdfDir: String = ""
    @AppStorage("trove.defaults.imageToolsSaveDir")   private var imgDir: String = ""
    @AppStorage("trove.defaults.recorderSaveDir")     private var recDir: String = ""
    @AppStorage("trove.defaults.snipSaveDir")         private var snipDir: String = ""
    @AppStorage("trove.defaults.ocrSaveDir")          private var ocrDir: String = ""
    @AppStorage("trove.defaults.qrSaveDir")           private var qrDir: String = ""
    @AppStorage("trove.defaults.colorSaveDir")        private var colorDir: String = ""
    @AppStorage("trove.defaults.snippetsSortMode")    private var snippetsSort: String = "alpha"
    @AppStorage("trove.defaults.calcAngleUnit")       private var calcAngle: String = "degrees"

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill.badge.gearshape").foregroundStyle(.tint)
                    Text("Defaults").headerText()
                }
                Text("Per-pane defaults. Each pane will use its own last-used location once you save something — these are the starting values.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                folderRow("PDF outputs",          binding: $pdfDir)
                folderRow("Image Tools outputs",  binding: $imgDir)
                folderRow("Recorder captures",    binding: $recDir)
                folderRow("Snip captures",        binding: $snipDir)
                folderRow("OCR text exports",     binding: $ocrDir)
                folderRow("QR images",            binding: $qrDir)
                folderRow("Color palette exports", binding: $colorDir)

                Divider()
                Picker("Snippets sort", selection: $snippetsSort) {
                    Text("Alphabetical").tag("alpha")
                    Text("Recently used").tag("recent")
                    Text("Most used").tag("used")
                    Text("Newest first").tag("created")
                }
                .pickerStyle(.menu)
                .font(.callout)

                Picker("Calculator angle unit", selection: $calcAngle) {
                    Text("Degrees").tag("degrees")
                    Text("Radians").tag("radians")
                }
                .pickerStyle(.menu)
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ label: String, binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 180, alignment: .leading)
            Text(binding.wrappedValue.isEmpty
                 ? "Last used (per session)"
                 : (binding.wrappedValue as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    binding.wrappedValue = url.path
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !binding.wrappedValue.isEmpty {
                Button {
                    binding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset \(label) to last-used")
                .help("Reset to last-used per session")
            }
        }
    }
}
