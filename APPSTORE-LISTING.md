# Trove — App Store / Direct Distribution listing copy

Drop these into App Store Connect (or your direct-distribution landing page).

## App name (30 char max)

```
Trove
```

## Subtitle (30 char max)

```
Every Mac utility, one app.
```

## Promotional text (170 char max)

```
Multi-clipboard staging, clipboard history, snippets, screen recording with
audio, OCR, smart calculator, color picker, window snap. Local-only. No
telemetry.
```

## Description (~4000 char)

```
Trove bundles the 20+ Mac utilities you actually reach for into one fast,
keyboard-driven app. No subscription. No account required. No data ever
leaves your Mac.

CLIPBOARD
• Stage — collect screenshots, text, and files into one pile and paste them
  all at once somewhere else. Replaces "Cut & Paste" + 4 clicks of repetition.
• History — full clipboard history with search, pin, restore. Password
  managers' transient pastes are automatically skipped.
• Snippets — reusable templates with one-click copy.
• Notes — five colored markdown scratchpads with live preview and live word
  count. Always-on, auto-saved.

COMPUTE
• Calculator — Soulver/Numi-class tape. Variables, units, smart percent,
  live ECB currency rates ("100 dollars in euros", "5 mi to km", "tax =
  9.75%" then "120 * (1 + tax)"). Edit any line and downstream recalculates.
• Text Tools — 42 chainable transforms: Base64, URL, JSON pretty/minify,
  JWT decode, regex extract/replace, hashes, case conversions, UUID gen,
  Hex↔Dec↔Bin, line ops. Pipeline mode lets you chain and inspect each step.

CAPTURE
• Record — screen recording with SYSTEM AUDIO + microphone in one flow.
  No BlackHole/Loopback required. Three smart presets: Tutorial (region +
  audio + mic), Demo (full + system audio), Quiet (region only).
• OCR — capture region → on-device text recognition (Apple Vision) →
  optional translation via Apple's Translation framework. Layout-aware:
  preserves paragraphs and bullets.
• Color — pick from anywhere on screen, extract dominant palettes from
  any image, WCAG AA/AAA contrast checker, copy as Hex/RGB/HSL/OKLCH.
• QR — generate scannable QR codes from any text.

FILES
• Image Tools — convert/resize/compress HEIC ↔ PNG ↔ JPEG ↔ WebP.
  Strip metadata. Batch. Atomic writes. Collision-safe naming.
• Hash — drag any file, get MD5/SHA1/SHA256 simultaneously via streaming
  hash (works on multi-GB files).

SYSTEM (for Windows switchers)
• Snap — Aero-Snap-style window tiling. Smart presets that suggest layouts
  per app (Xcode gets 65% left, Terminal 35% right). Multi-window layout
  composer.
• Switcher — AltTab-style switcher that cycles individual windows (not
  apps). Type-to-filter. Color-coded by app.
• Move Files — ⌘X then ⌘V in Finder ACTUALLY MOVES files, like Windows.
  Visible cut state. Cross-Finder-window pastes. Files stay safe in source
  until paste.
• Finder — bundled Finder tweaks switchers always look up: show file
  extensions, hidden files, path bar, faster Dock, copy POSIX path of the
  current window with ⌘⇧C.
• Processes — top-N CPU/RAM with live sparklines and one-click kill.
  Grouped by parent app so you don't see 47 "Chrome Helper" rows.

STORAGE
• Overview — disk usage at a glance, biggest folders in your Home.
  Cached between launches so it paints instantly.
• Scan — drill into any folder, biggest sub-dirs or biggest files.
• Clean — one-click cleanup of npm / pnpm / yarn / pip / brew caches,
  Xcode DerivedData, iOS Simulator caches. Warns if Xcode is running.
• Sweep — auto-organize ~/Downloads into a dated _archive/ folder by age
  and type. Truly stale items go to Trash (recoverable).

DESIGN PRINCIPLES
• Native macOS. SwiftUI, system materials, no Electron, no subscriptions.
• Local-only. No analytics, no crash reporting, no third-party SDKs.
• Tap the sidebar pane you actually use, hide the rest in Customize.
• CLI integration: `trove add`, `trove capture`, `trove copy`.

The full source is one Swift module. The full network footprint is one
URL: the European Central Bank's public exchange-rate feed, fetched once
a day.
```

## Keywords (100 char max)

```
clipboard,screenshot,ocr,calculator,window,snap,productivity,utility,recorder,snippets,tools
```

## Category

Primary: **Productivity**
Secondary: **Utilities**

## Age rating

4+ (no restricted content)

## Support URL

`https://github.com/<your-handle>/trove` (or your personal site / Gumroad page)

## Marketing URL

Same as Support URL.

## Privacy policy URL

`https://github.com/<your-handle>/trove/blob/main/PRIVACY.md`
(or wherever you host `PRIVACY.md`. GitHub Gist works; the URL pattern is
`https://gist.github.com/<user>/<id>/raw/PRIVACY.md`.)

## What's New (release notes)

```
First release.
• Stage multi-clipboard with copy-all
• Persistent clipboard history with privacy guards
• Snippets, Notes, Calculator with live currency
• Screen recorder with system audio
• OCR with on-device text recognition
• Window snap, AltTab-style switcher, cut-paste files
• Storage overview, scan, clean, sweep
• 20+ tools total, each one hide-able in Customize.
```

## Screenshot guidance (you'll capture these once the app is signed)

Capture at 1280 × 800 (Retina) — App Store requires 2880 × 1800 for
Retina display class. Use ⌘⇧4 then space-bar to grab the window, or:

```
trove capture
```

Five recommended hero shots:

1. **Stage** — show 4–5 staged items (a screenshot, a code snippet, a PDF,
   an image) with the "Copy all (5)" button highlighted. Caption: "One
   paste. Multiple things."
2. **Calculator** — full tape with variables, units, and a currency
   conversion line. Caption: "Soulver-class smart tape, local-only."
3. **Snap + Switcher** — split-screen of the Snap pane on one side,
   Switcher overlay on the other. Caption: "Windows-refugee features that
   actually feel native."
4. **Storage Clean** — the Clean pane with sizes calculated, several
   categories selected. Caption: "Reclaim space without a separate $30
   app."
5. **Customize** — the Customize pane showing toggles for every tool.
   Caption: "Hide what you don't use. The app you built."

## Notes for the listing

- The "no analytics" / "no telemetry" angle is your strongest marketing
  differentiator vs. Setapp bundles. Lean into it.
- Price: a $25–$35 one-time purchase positions this against Bartender
  ($16), Magnet ($8), CleanShot X ($30), and is below the per-tool sum of
  what it replaces. "Replaces ~8 apps" is the marketing line.
- Mac App Store sandbox will disable about half the features (see
  SHIPPING.md). Direct Distribution + Gumroad is the recommended path.
