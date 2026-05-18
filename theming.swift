// theming.swift — Trove theme system.
//
// Default is `.dark` (the original Trove look). Users can switch in Settings
// or pick on first run via the welcome sheet. `.system` follows macOS Light/
// Dark; everything else is a pinned, app-defined palette so the chrome and
// content stay coherent regardless of the system appearance.

import SwiftUI
import AppKit
import Combine

// MARK: - Theme enum

enum TroveTheme: String, CaseIterable, Identifiable {
    case dark, light, system, linear, cron, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dark:   return "Dark"
        case .light:  return "Light"
        case .system: return "Match System"
        case .linear: return "Linear"
        case .cron:   return "Cron"
        case .custom: return "Custom"
        }
    }
    var isRecommended: Bool { self == .dark }
    /// The macOS NSAppearance to pin to the main window so chrome (titlebar,
    /// sidebar inset, scrollers) matches the inner content. For `.custom`,
    /// callers must pass `customIsLight` since this is a `nonisolated` enum
    /// computed property and can't reach into `@MainActor` state.
    func nsAppearance(customIsLight: Bool = false) -> NSAppearance? {
        switch self {
        case .dark, .linear, .cron:    return NSAppearance(named: .darkAqua)
        case .light:                   return NSAppearance(named: .aqua)
        case .system:                  return nil // OS decides
        case .custom:
            return customIsLight
                ? NSAppearance(named: .aqua)
                : NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Color palette per theme

struct TrovePalette: Equatable {
    let bg:         Color  // outermost window background
    let bgElev:     Color  // sidebar / inset / elevated surface
    let cardSolid:  Color  // card fill
    let cardBorder: Color  // card outline (nil-equivalent for dark themes)
    let fg:         Color  // primary text
    let fgDim:      Color  // secondary text
    let fgMute:     Color  // tertiary / placeholder
    let line:       Color  // divider
    let accentTint: Double // gradient overlay opacity (0.0...0.12)

    /// The original Trove dark palette — what the app shipped with.
    static let dark = TrovePalette(
        bg:         Color(red: 0.06, green: 0.06, blue: 0.07),
        bgElev:     Color(red: 0.09, green: 0.09, blue: 0.10),
        cardSolid:  Color(red: 0.11, green: 0.11, blue: 0.12),
        cardBorder: Color.white.opacity(0.04),
        fg:         Color(red: 0.94, green: 0.94, blue: 0.93),
        fgDim:      Color(red: 0.68, green: 0.68, blue: 0.66),
        fgMute:     Color(red: 0.46, green: 0.46, blue: 0.44),
        line:       Color.white.opacity(0.08),
        accentTint: 0.08
    )

    /// Light theme — warm off-white inner, deep neutral text. Doesn't use
    /// pure white (washes out content) or pure black (too harsh against the
    /// accent color).
    static let light = TrovePalette(
        bg:         Color(red: 0.980, green: 0.978, blue: 0.969), // FAFAF7
        bgElev:     Color(red: 0.961, green: 0.957, blue: 0.945), // F5F4F1
        cardSolid:  Color(red: 0.945, green: 0.941, blue: 0.925), // F1F0EB
        cardBorder: Color.black.opacity(0.06),
        fg:         Color(red: 0.110, green: 0.106, blue: 0.102), // 1C1B1A
        fgDim:      Color(red: 0.361, green: 0.353, blue: 0.333), // 5C5A55
        fgMute:     Color(red: 0.557, green: 0.545, blue: 0.518), // 8E8B85
        line:       Color.black.opacity(0.08),
        accentTint: 0.05
    )

    /// Linear-style: cool blue-gray, slightly cooler than pure dark.
    static let linear = TrovePalette(
        bg:         Color(red: 0.075, green: 0.082, blue: 0.094),
        bgElev:     Color(red: 0.106, green: 0.114, blue: 0.129),
        cardSolid:  Color(red: 0.137, green: 0.145, blue: 0.165),
        cardBorder: Color.white.opacity(0.05),
        fg:         Color(red: 0.92,  green: 0.93,  blue: 0.94),
        fgDim:      Color(red: 0.65,  green: 0.67,  blue: 0.70),
        fgMute:     Color(red: 0.43,  green: 0.45,  blue: 0.48),
        line:       Color.white.opacity(0.06),
        accentTint: 0.06
    )

    /// Cron-style: warm cream-toned dark with a hint of sepia.
    static let cron = TrovePalette(
        bg:         Color(red: 0.078, green: 0.071, blue: 0.063),
        bgElev:     Color(red: 0.110, green: 0.102, blue: 0.090),
        cardSolid:  Color(red: 0.137, green: 0.125, blue: 0.110),
        cardBorder: Color.white.opacity(0.04),
        fg:         Color(red: 0.957, green: 0.945, blue: 0.918),
        fgDim:      Color(red: 0.706, green: 0.690, blue: 0.643),
        fgMute:     Color(red: 0.486, green: 0.471, blue: 0.435),
        line:       Color.white.opacity(0.06),
        accentTint: 0.07
    )

    /// For `.system`, pick dark or light based on the resolved appearance.
    static func forSystem(_ resolved: NSAppearance?) -> TrovePalette {
        let isDark = resolved?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .dark : .light
    }
}

// MARK: - User-customizable theme (for .custom)

struct TroveCustomTheme: Codable, Equatable {
    var isLight: Bool = false
    var accentHex: String = "#F08227"     // Trove warm orange default
    var bgHexA: String = "#0F0F11"        // gradient top
    var bgHexB: String = "#0A0A0C"        // gradient bottom

    static let dark = TroveCustomTheme(
        isLight: false,
        accentHex: "#F08227",
        bgHexA: "#0F0F11",
        bgHexB: "#0A0A0C"
    )
    static let light = TroveCustomTheme(
        isLight: true,
        accentHex: "#D9651C",
        bgHexA: "#FAFAF7",
        bgHexB: "#F1F0EB"
    )

    func toPalette() -> TrovePalette {
        let base: TrovePalette = isLight ? .light : .dark
        // Replace bg/bgElev with user's pick; keep semantic text/line tones.
        return TrovePalette(
            bg:         Color(hex: bgHexA) ?? base.bg,
            bgElev:     Color(hex: bgHexB) ?? base.bgElev,
            cardSolid:  base.cardSolid,
            cardBorder: base.cardBorder,
            fg:         base.fg,
            fgDim:      base.fgDim,
            fgMute:     base.fgMute,
            line:       base.line,
            accentTint: base.accentTint
        )
    }
}

// MARK: - Theme store (shared singleton + @AppStorage binding)

@MainActor
final class TroveThemeStore: ObservableObject {
    static let shared = TroveThemeStore()

    @Published var theme: TroveTheme = .dark { didSet { persistTheme() ; applyAppearance() } }
    @Published var customTheme: TroveCustomTheme = .dark { didSet { persistCustom(); applyAppearance() } }

    var customIsLight: Bool { customTheme.isLight }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.keyTheme),
           let t = TroveTheme(rawValue: raw) {
            self.theme = t
        }
        if let data = UserDefaults.standard.data(forKey: Self.keyCustom),
           let dec = try? JSONDecoder().decode(TroveCustomTheme.self, from: data) {
            self.customTheme = dec
        }
    }

    func applyAppearance() {
        // Pin every NSWindow's appearance to match the chosen theme so chrome
        // doesn't drift to system mode. Skip when theme is `.system` (let OS
        // decide). New windows pick up `NSApp.appearance` automatically.
        let app = theme.nsAppearance(customIsLight: customTheme.isLight)
        NSApp.appearance = app
        for w in NSApp.windows {
            w.appearance = app
        }
    }

    func resolvedPalette(systemAppearance: NSAppearance?) -> TrovePalette {
        switch theme {
        case .dark:   return .dark
        case .light:  return .light
        case .linear: return .linear
        case .cron:   return .cron
        case .system: return TrovePalette.forSystem(systemAppearance)
        case .custom: return customTheme.toPalette()
        }
    }

    private func persistTheme() {
        UserDefaults.standard.set(theme.rawValue, forKey: Self.keyTheme)
    }
    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customTheme) {
            UserDefaults.standard.set(data, forKey: Self.keyCustom)
        }
    }

    static let keyTheme = "trove.theme.v1"
    static let keyCustom = "trove.theme.custom.v1"
}

// MARK: - Color hex helper (used by custom theme)

// MARK: - SwiftUI picker views

/// A 6-tile theme picker grid. Used by the welcome sheet (first run) and
/// the Settings → Theme card. Tap a tile to commit instantly — the change
/// is reversible from the same picker.
struct ThemePickerGrid: View {
    @ObservedObject private var store = TroveThemeStore.shared
    var compact: Bool = false   // welcome sheet uses compact tiles
    var body: some View {
        let cols = compact ? 2 : 3
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 10) {
            ForEach(TroveTheme.allCases) { t in
                ThemeTile(theme: t, selected: store.theme == t, compact: compact) {
                    store.theme = t
                }
            }
        }
    }
}

struct ThemeTile: View {
    let theme: TroveTheme
    let selected: Bool
    let compact: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // Mini preview swatch: a 3-stripe gradient mimicking the
                // theme's bg → bgElev → cardSolid.
                let palette = previewPalette
                HStack(spacing: 0) {
                    palette.bg
                    palette.bgElev
                    palette.cardSolid
                }
                .frame(height: compact ? 32 : 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack(spacing: 4) {
                    Text(theme.displayName)
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                        .foregroundStyle(palette.fg)
                    if theme.isRecommended {
                        Text("Recommended")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.06 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.white.opacity(0.08),
                            lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var previewPalette: TrovePalette {
        switch theme {
        case .dark:   return .dark
        case .light:  return .light
        case .linear: return .linear
        case .cron:   return .cron
        case .system: return .dark // approximation; system means OS-resolved
        case .custom: return TroveThemeStore.shared.customTheme.toPalette()
        }
    }
}

/// The full Settings → Theme card: picker grid, optional Custom panel
/// (accent + bg color wells, Reset button), and a small "Reset to Dark"
/// escape hatch so experimentation is always safely reversible.
struct ThemeSettingsCard: View {
    @ObservedObject private var store = TroveThemeStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Trove keeps its own theme so the app looks the same regardless of macOS Light / Dark mode. Pick one — or build your own.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ThemePickerGrid(compact: false)
            if store.theme == .custom {
                customPanel
            }
            HStack {
                Spacer()
                Button("Reset to Dark") {
                    store.theme = .dark
                    store.customTheme = .dark
                }
                .controlSize(.small)
                .disabled(store.theme == .dark)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06)))
    }

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            Text("Custom theme").font(.subheadline).foregroundStyle(.secondary)
            Toggle("Use light chrome", isOn: Binding(
                get: { store.customTheme.isLight },
                set: { store.customTheme.isLight = $0; store.applyAppearance() }
            ))
            HStack(spacing: 12) {
                customColorWell(label: "Accent", hexBinding: bind(\.accentHex))
                customColorWell(label: "BG top",  hexBinding: bind(\.bgHexA))
                customColorWell(label: "BG bottom", hexBinding: bind(\.bgHexB))
            }
            Button("Apply built-in dark preset to custom") {
                store.customTheme = .dark
            }
            .controlSize(.small)
        }
    }

    private func customColorWell(label: String, hexBinding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(hex: hexBinding.wrappedValue) ?? Color.gray },
                set: { hexBinding.wrappedValue = $0.toHex() }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44, height: 24)
            Text(hexBinding.wrappedValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func bind(_ kp: WritableKeyPath<TroveCustomTheme, String>) -> Binding<String> {
        Binding(
            get: { store.customTheme[keyPath: kp] },
            set: { store.customTheme[keyPath: kp] = $0 }
        )
    }
}

// MARK: - Color hex helper (used by custom theme)

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        let r = Double((n >> 16) & 0xFF) / 255.0
        let g = Double((n >> 8)  & 0xFF) / 255.0
        let b = Double(n         & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
    /// Hex string for the *sRGB* representation — used to round-trip the
    /// custom theme to UserDefaults.
    func toHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int((ns.redComponent   * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
