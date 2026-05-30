# Changelog

All notable changes to Trove. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

Trove ships two release channels via the in-app updater:

- **Stable** (default) — only `vX.Y.Z` releases (no pre-release suffix).
- **Beta** (opt-in via Settings → Updates → Update channel) — receives `vX.Y.Z-beta.N` builds before they promote to Stable.

The in-app updater (Settings → Updates) reads the active channel from
`updater.includePrereleases` in UserDefaults. Switch any time; the next check
will surface whatever's newest on the chosen channel.

---

## [1.1.0-beta.10] — Unreleased

### Fixed

- **P1 — PDF Rotate preview clipped 90°/270° rotations.** `rotationEffect`
  rotates in place WITHOUT reflowing the container frame, so a portrait
  page rotated 90° was clipped to the original portrait frame. Switched
  each rotate cell to a square 108×108 container so any rotation angle
  fits without clipping. Added Reduce Motion respect to the rotation
  animation (other hover animations in the file already had it).
- **P1 — PDF Merge preview opened the source PDF twice per render.**
  `loadThumb(_:)` created a fresh `PDFOpsThumbRenderer` per call, so two
  copies of the same source in a merge list each held a separate
  `PDFDocument`. Added a per-URL renderer cache keyed by the source URL
  so the doc opens once even on redraws.
- **P1 — PDF Split + Rotate previews held an unbounded thumb cache.**
  `@State` `[Int: NSImage]` grew as the user scrolled a multi-hundred-page
  PDF — at ~33 KB per 80×104 ARGB bitmap, a 500-page doc pinned ~16 MB
  indefinitely. Cap at 120 entries (covers ~4 screens at typical density);
  FIFO-evict the lowest-index entries when over the cap.
- **P0 a11y sweep — 9 more `.headerText()` regressions reverted.** Sites
  that mutate dynamically (`Text(detail.comm)` in procs) or that are
  empty-state / error-state titles or TextField labels — not structural
  landmarks — should not pollute the VoiceOver heading rotor. Reverted:
  - `history.swift:717` — "No matches for X" empty-state
  - `notes.swift:1012` — "No matches for X" empty-state
  - `procs.swift:843` — "No processes match X" empty-state
  - `procs.swift:750` — `Text(detail.comm)` dynamic value
  - `network_monitor.swift:1131` — "No inbound/outbound traffic" empty-state
  - `network_monitor.swift:1152` — "No network traffic yet" empty-state
  - `network_monitor.swift:1220` — "Network monitoring unavailable" error
  - `text_transforms.swift:1784/1788/1792/1798/1802` — five form-field labels
    (Prefix / Suffix / Regex / Regex / Replacement) that sit above their
    bound TextField, not section headings

### Verified

`lint-trove`: clean. `test-trove`: 233/233 PASS.

---

## [1.1.0-beta.9] — Unreleased

### Fixed

- **P0 — Menu bar dead routes.** All 9 menu-triggered notifications (added
  in beta.7's overhaul) silently no-opped because no view listened for
  them. Wired `.onReceive` for every one:
  - `troveSnippetsNewItem`        → SnippetsView opens new-snippet editor
  - `troveSnippetsImport`         → SnippetsView opens .fileImporter
  - `troveSnippetsExport`         → SnippetsView calls triggerExport()
  - `troveExportAllData`          → AccountView calls exportData()
  - `troveCaptureRegionToOCR`     → OCRView calls vm.capture() (guarded)
  - `troveCaptureRegionToSnip`    → SnipView calls engine.startSnip() (guarded)
  - `troveColorPickFromScreen`    → ColorToolView triggers NSColorSampler
  - `troveMirrorOpenFloating`     → MirrorView opens floating panel
  - `troveDiskSpeedRunNow`        → DiskSpeedView starts benchmark run (guarded)
- **P1 — Tools menu bypassed pane visibility.** `switchToPane(.X)` in
  Tools-menu items routed unconditionally, so clicking "PDF Tools" on a
  user who had hidden the PDF pane silently jumped to a blank sidebar
  slot. New `switchToPaneGuarded(_:)` helper does the same hidden-pane
  flash as the View menu's ⌘1–⌘4. All 30 Tools-menu calls swept to the
  guarded variant.
- **P1 — PDF Compress estimate ~15× too small.** `scheduleProbe()`
  rendered a 320 px thumbnail, JPEG-encoded that, and multiplied by
  pageCount — but the actual compress op rasterizes at ≈ 1240 px per
  page (150 DPI for A4). Bumped target to 1100 px so the projection sits
  in the right order of magnitude.
- **P1 — `parseRangeGroups` mis-parsed whitespace + leading minus.**
  `"10 - 20"` produced `["10 ", " 20"]` which `Int(_:)` rejected, so the
  range silently dropped. Trim each part; reject leading-minus tokens
  explicitly so `"-5"` doesn't masquerade as a range.
- **P1 — PDF Split / Rotate previews didn't explain zero-page sources.**
  Corrupt or image-only PDFs where `pageCount == 0` rendered a blank card
  with no explanation. Now surface a warning row: "Could not read pages
  from this PDF — it may be corrupt or password-protected."
- **P1 — QuickLook `.keyboardShortcut(.space)` scope bleed.** SwiftUI
  registers `.keyboardShortcut` on a context-menu Button as an app-wide
  accelerator for the surrounding scope, NOT only when the menu is open.
  Space-bar in Stage/Library/History panes would trigger Quick Look on
  every press, including inside any TextField. Switched to ⌘Y — the
  canonical macOS Quick Look chord (Finder + Files use it), no scope
  bleed, no future-TextField conflict.
- **P1 — QuickLook `.disabled(iniCloud)`.** QLPreviewPanel renders iCloud
  placeholders natively and triggers download via `NSFileCoordinator`.
  Disabling the button forced a manual "go to Finder, download, come
  back" round-trip that the system already handles. Removed.
- **P0 — A11y sweep regressions (round 2).** The `.headerText()` sweep
  branded three more sites with `.isHeader` traits they shouldn't carry:
  empty-state "No snippets yet" / "No files added yet" (informational
  copy, not landmarks) and the snip annotate dialog title (macOS focuses
  the sheet automatically — adding the header trait is redundant +
  pollutes the rotor). All reverted to literal `.font(.headline)`.
- **P2 — Menu naming + email consistency.** Help menu "What's New" now
  reads "What's New in Trove…" to match the App menu entry. Help menu
  "Send Feedback" address unified to the branded `hello@gettrove.vercel.app`
  to match the App menu's entry (Help previously routed to a personal
  Gmail).
- **P1 — Theme + Accent submenu lacked active-selection feedback.** Both
  submenus now prefix the active option with a `✓` glyph so the user can
  tell at a glance which theme / accent is on.

### Verified

`lint-trove`: clean. `swiftc -DTROVE_TESTING -parse-as-library`: clean.
`test-trove`: 233/233 PASS.

---

## [1.1.0-beta.8] — Unreleased

### Added

- **Pro-level customization surface — four new Settings cards** in
  `customization_settings.swift`:
  - **Accessibility** — single-click toggles for Reduce Motion, Reduce
    Transparency, Increase Contrast respect; VoiceOver state-change
    announcement opt-in; focus-ring style picker (Default / Bold accent
    / Subtle border); inline catalogue of the 15 most useful chords with
    keyboard navigation hints.
  - **Density & layout** — Compact / Default / Comfortable picker driving
    row spacing, card radius, padding via a single `TroveUIDensity` token;
    sidebar-width slider (180–320 pt); toast-lifetime slider (1.5–12 s);
    hover-reveal delay slider (0–600 ms); Compact list rows + double-click-
    activation toggles.
  - **Keyboard shortcuts** — comprehensive read-only catalogue grouped by
    surface (App / File / Edit / View / Per-pane), 50+ chords surfaced —
    no more "is there a shortcut for X" tab-hunting. Total-chord count
    badge in the header.
  - **Defaults** — per-pane default save folder picker for PDF / Image
    Tools / Recorder / Snip / OCR / QR / Color, plus a default Snippets
    sort + Calculator angle unit. Empty value falls back to per-session
    last-used (existing behaviour) — these defaults are upstream of the
    pane's own last-used persistence.

### Fixed

- **P0 PDF previews — duplicate `.task(id: url)` on
  `PDFOpsCompressPreview`.** Two separate `.task(id: url)` modifiers raced;
  the second's `scheduleProbe()` always read `renderer == nil` and silently
  no-opped because the first hadn't yet committed `renderer = r`. Merged
  into a single ordered task that builds the renderer → publishes
  pageCount → schedules the first probe.
- **P1 Compress preview cross-file contamination.** `scheduleProbe()`
  previously captured `pageCount` BEFORE the 180 ms debounce sleep, so a
  source-switch during the debounce multiplied per-page bytes by the OLD
  doc's page count. Now captures the renderer ref before the sleep and
  re-reads pageCount AFTER the await on MainActor.
- **P0 QuickLook — responder-chain bypass.** `TroveQuickLook` hard-wired
  `panel.dataSource = self` / `panel.delegate = self` directly and never
  cleared `urls` — the singleton retained whatever URL was last previewed
  across the entire app session, particularly bad for Stage temp PNGs.
  Hooks `NSWindow.willCloseNotification` on the QL panel and releases
  URLs + nils data source/delegate on close. Also drops the synchronous
  `fileExists` pre-filter (QL renders a clean "file not found" placeholder
  for missing URLs — the previous silent guard-return was a UX bug).
- **P0 PDF "Continue with…" — three latent corruption paths.**
  `ingestPDFReopenPayload` now (a) validates the op key explicitly and
  surfaces a `kind: .error` toast on unknown keys instead of silently
  falling back to `.merge`; (b) calls `m.cancel()` if a job is in flight
  before `m.clear()`, preventing a mid-pipeline source-wipe-under-worker;
  (c) flashes a heads-up when there are unsaved outputs (still findable in
  Library + recents) instead of silently dropping them; (d) checks
  `fileExists` on the URL before clearing prior state, so a swept temp
  file doesn't wipe state for nothing.
- **P1 PDF "Continue with…" — missing `Unlock` entry.** The submenu had
  11 op routes but `unlock` was absent — a user who just Protected a PDF
  had no one-click path to reverse it. Added.
- **P0 Menu bar — `⌘⇧N` registered twice.** Both Edit > Capture
  Screenshot and Tools > Capture > Screenshot to Stage bound `⌘⇧N`,
  making the responder chain pick non-deterministically. Dropped the
  Tools shortcut; Edit owns the chord.
- **P0 Menu bar — `⌘.` triple-collision.** "Release Assertion" in Keep
  Awake clashed with the Recorder's stop-recording shortcut AND the
  universal macOS Cancel chord; releasing the assertion mid-recording was
  an unrecoverable surprise. Removed the menu shortcut; the action stays
  one click away in the pane.
- **P0 A11y sweep regression — Welcome CTA marked as a heading.** The
  `.headerText()` coherence sweep accidentally branded "Start using Trove"
  with `.isHeader`, polluting VoiceOver's heading rotor with a button label.
  Reverted to literal `.font(.headline)`.
- **P1 A11y sweep regression — live status strings marked as headings.**
  Recorder "Paused / Recording" and Disk Speed "Running / Ready" are
  mutating runtime state, not section landmarks. The heading rotor jumped
  to them and announced different values seconds later, which is
  disorienting. Both reverted to `.font(.headline)`.
- **P2 A11y sweep miss — `theming.swift:319` had the manual inline
  `.font(.headline).accessibilityAddTraits(.isHeader)` pattern** that the
  regex didn't catch (trailing trait broke the modifier-chain match).
  Collapsed to `.headerText()` for consistency.

### Verified

`lint-trove`: clean. `swiftc -DTROVE_TESTING -parse-as-library`: clean.
`test-trove`: 233/233 PASS.

---

## [1.1.0-beta.7] — Unreleased

### Added

- **Comprehensive menu-bar overhaul** — went from 5 minimal items to a full
  professional macOS menu surface:
  - **Trove** menu now includes "What's New", "Trove Website", "Privacy
    Policy", "Send Feedback…" alongside About + Check for Updates.
  - **File** menu got real content: New Snippet (⌘N), Open Files into Stage…
    (⌘O), Import / Export Snippets…, Export My Trove Data….
  - **Edit** menu extends the Stage cluster with "Copy All Staged as Text"
    (⌘⇧⌥C), "Capture Region → OCR" (⌘⌥4), "Capture Region → Snip" (⌘⌥5)
    alongside the existing Paste-into-Stage / Copy-as-Files / Screenshot
    / Clear-Stage bindings.
  - **View** menu gains a **Theme** submenu (Dark / Light / System / Linear
    / Cron / Custom) and an **Accent** submenu (Neutral / Magenta / Sky /
    Warm) so the user never has to dig into Settings for either.
  - **NEW Tools menu** — first-class power-user surface with submenus for
    Stage, Capture, Quick… (all 8 utility tools as one-click jumps),
    System (all 10 system panes), Storage (Overview / Scan / Clean /
    Sweep / Library), and **Keep Awake** (1 hour / 4 hours / Until Quit /
    Release Assertion ⌘.).
  - **Help** menu keeps its Keyboard Shortcuts (⌘/) + What's New + Report
    an Issue (prefilled with `Trove vX.Y.Z`) + Website surface.
- **Inline "Continue with…" submenu on every PDF output row.** When you
  finish merging two PDFs, the output row now exposes "Merge with another
  PDF" / "Split into pages" / "Organize / rearrange" / "Compress further" /
  "Rotate pages" / "Add page numbers" / "Watermark" / "Crop" /
  "Password-protect" / "OCR text layer" / "Re-save via PDFKit" as one-click
  continuations. Posts the same `.troveOpenInPDFTool` payload the existing
  Library reEditMenu uses, so the PDFView listener auto-switches the op +
  loads the URL as a source. No more "save → close → re-drop → pick op
  again" friction; you can chain a 6-step pipeline without leaving the pane.
- **Routing notification names** declared centrally so any future feature
  (or pane) can listen for the same menu-driven actions:
  `troveSnippetsNewItem`, `troveSnippetsImport`, `troveSnippetsExport`,
  `troveExportAllData`, `troveCaptureRegionToOCR`, `troveCaptureRegionToSnip`,
  `troveColorPickFromScreen`, `troveMirrorOpenFloating`, `troveDiskSpeedRunNow`.

### Changed

- The previously-minimal File menu (collapsed to just Close) now carries
  real content. macOS users expect a File menu to do something.
- The Edit menu's Stage cluster moved its capture shortcuts up so all three
  capture destinations (Stage / OCR / Snip) sit next to each other.

---

## [1.1.0-beta.6] — Unreleased

### Added

- **Native macOS QuickLook for Stage / Library / History items.**
  Press Space (or pick "Quick Look" from the context menu) on any image or
  file item to open the macOS-native preview panel — same surface Finder
  uses. Renders images, PDFs, source code, audio, video, archives, plain
  text — whatever the system supports. No app-switching, no opening Preview.
  A single `TroveQuickLook` singleton (`@MainActor`, `QLPreviewPanelDataSource`)
  holds the URL list so the panel sees stable indices across arrow-key
  navigation; future multi-select adoption in Stage / Library can pass a
  whole array via `show([URL], start:)`.

### Changed

- **`.headerText()` coherence sweep — 87 call sites across 25 files.**
  Every section / card title that previously used raw `.font(.headline)` now
  uses the existing `.headerText()` modifier, which combines headline font +
  `accessibilityAddTraits(.isHeader)`. VoiceOver's Headings rotor now
  navigates to every section title in every pane (Stage / Calc / Color /
  QR / OCR / Image Tools / PDF / Hash / Rename / Recorder / Snip / Snap /
  AltTab / Finder / Procs / Awake / Permissions / Log / GPU / Network /
  Disk Speed / Account / Updater / Mirror / History). Mechanically
  scripted; one self-recursion in the `headerText()` definition itself was
  swept and immediately reverted to the literal `.font(.headline)` body.
- macOS Finder had created `" 2.swift"` duplicate copies of nine files
  during the concurrent-edit window; removed (zero unique content vs the
  originals).

---

## [1.1.0-beta.5] — Unreleased

### Added

- **Live previews for every PDF op** (no run/save needed to see the result):
  - **Merge** — horizontal strip of first-page thumbnails in the current
    source order, each with index badge + filename + page count. Reorder
    in the source list above and the strip reflects it instantly. Total
    output page count shown in the header.
  - **Split** — full thumbnail grid of the source PDF with per-page badges
    showing which output (`p3 → #1`) each page lands in. Pages outside any
    range are dimmed + tagged "dropped" so the user can spot off-by-one
    range mistakes before running. Reuses the actor-serialized
    `PDFOpsThumbRenderer` so opening a 500-page doc still feels snappy.
  - **Rotate** — thumbnail grid with the rotation applied per cell via
    `.rotationEffect`. Animated transition so picking 90° CW → 180° → 90°
    CCW is immediately legible. Honors the "Apply to all pages" toggle +
    range field; un-affected pages render un-rotated.
  - **Compress** — sample page rendered at the chosen quality + projected
    output size estimate (per-page JPEG re-encode × page count). Updates
    on a 180 ms debounce as the slider drags so heavy re-encodes don't pin
    the slider. Header turns success-green when the projected reduction
    crosses 30%.
- All four previews live in `pdf.swift` as `fileprivate` SwiftUI structs
  (`PDFOpsMergePreview` / `PDFOpsSplitPreview` / `PDFOpsRotatePreview` /
  `PDFOpsCompressPreview`) and reuse the existing `PDFOpsThumbRenderer`
  actor for off-main PDFKit access. No new threading hazards introduced.

### Changed

- `PDFOpsDetailView.body` now inserts the live preview between `parameters`
  and `runRow`, so the visual feedback sits where the user's eye is already
  tracking after tweaking inputs.

---

## [1.1.0-beta.4] — Unreleased

### Fixed

- **Version auto-update across rebuilds.** Two bugs were keeping the sidebar
  footer showing `v1.0.4-dev` after the source version bumped to `1.1.0-beta.3`:
  - `~/bin/build-macapp` defaulted to baking `"1.0"` whenever `BUILD_VERSION`
    env was unset. Now it reads the project's `VERSION` file as fallback, so
    every plain `build-macapp` rebuild picks up the bumped semver without env
    juggling. Stripping CR/LF prevents an editor's trailing newline from
    silently breaking the GitHub-Releases comparator.
  - `UpdateChecker.currentVersion()` only fell back to the source-tracked
    `fallbackVersion` when the bundle was the exact placeholder `"1.0"`. A
    binary built once with `BUILD_VERSION=1.0.4-dev` therefore kept showing
    `1.0.4-dev` forever. Now any of: missing key, empty key, `"1.0"`, contains
    `-dev`, or strictly-older-than-fallback per semver hands off to the source
    version. Notarized releases (≥ fallback, no `-dev`) still show their own
    real version string.

---

## [1.1.0-beta.3] — Unreleased

### Fixed

- **P0 visual: giant vertical-capsule toast blob** on the right side of any
  pane (most visible on Keep Awake). Root cause: `ToastCapsule` used
  `Capsule(.continuous)` for its background fill — `Capsule` adapts to bounds
  with hemispherical ends, so when a parent overlay gave it taller bounds the
  toast morphed into a giant vertical pill that ate the right half of the
  window. Switched the background + overlay to `RoundedRectangle(cornerRadius: 18)`
  so the shape can never stretch into a vertical-pill; capped the toast's
  outer frame with `maxHeight: 96` + `.fixedSize(horizontal:false, vertical:true)`
  so even if a future parent layout misbehaves, the toast stays toast-sized;
  height-capped the leading kind-tint stripe so it can't stretch the inner
  HStack vertically either.

---

## [1.1.0-beta.2] — Unreleased

Round-two audit-driven hardening. All 18 items on the carry-over list landed.
Tests: 233/233 pass.

### Added

- **`SnippetLoadOutcome`** — explicit result type for the off-main snippet
  loader (.ok / .empty / .corrupt(msg) / .noFile), so the @StateObject init
  can return synchronously while the actual disk I/O happens off-main.
- **`AutoInstaller.posixSingleQuote`** — POSIX-safe shell-argument quoter so
  the codesign verification can no longer be tricked into evaluating `$` /
  backtick on an adversarial app-bundle path.

### Fixed (P0 / P1)

- **`NoteStore.init` / `ClipHistory.init` / `SnippetStore.init`** were three
  AccountView-class SIGTRAP-risk paths — each ran `boundedRead` (up to 16 MB)
  + `JSONDecoder.decode` synchronously on the main thread inside the
  `@StateObject` default expression. On a slow / cold disk this pushed past
  the AttributeGraph 50 ms watchdog and could SIGTRAP. All three now seed
  empty + load off-main + publish back on @MainActor.
- **`AltTabView` `screenRecordingAllowed` `@State` default** ran
  `CGPreflightScreenCaptureAccess()` synchronously on main during view init
  (50–200 ms TCC read on a cold `tccd`). Seeded `false`; refreshes via
  `.task` and `didBecomeActive` (both already wired).
- **`OverviewView` Full-Disk-Access priming card** was shown eagerly on every
  first launch — telling brand-new users they had a problem before they had
  one. Now gated on actually-observed permission denials during Refresh
  (probes `Downloads`/`Desktop`/`Documents` in the off-main hop).
- **`WelcomeSheet` Escape** was bound to BOTH the "Start using Trove" CTA
  AND the sheet's dismiss action — a user pressing Escape to back out
  permanently committed `hasSeenWelcome = true`. Escape now ONLY dismisses
  (welcome re-shows next launch); Return commits the CTA.
- **History `watching` default** flipped from `false` → `true` on first
  launch (key absent). Trove is a clipboard-first app; the empty pane on
  fresh install made users think the feature was broken. Privacy markers
  still filter the ingestion path.
- **OCR `translationTarget` / `wantsTranslation` / `recognitionLanguage`**
  persist across launches under `trove.ocr.*` keys. Users who returned to
  OCR with the same source/target language combo had to re-pick every time.
- **`auto_installer.swift:369,393` codesign verify shell escape** — the
  previous `\"\(path)\"` only escaped `"`. `$` and backticks remained live.
  Rewrote with POSIX single-quote (`'\''` close-reopen pattern) so arbitrary
  path content is rendered literally. Local threat model only (the path
  comes from `Bundle.main.bundleURL`), but the gap is closed.
- **`history.swift` three `NSImage(contentsOf:)` call sites** now probe file
  byte-size first (200 MB cap, matching the pasteboard ingestion ceiling).
  A tampered `clipboard_history.json` path pointing at a 1 GB sparse file or
  a FIFO would otherwise OOM the app.
- **`image_tools.swift:471` IUO `var resultURL: URL!`** replaced with optional
  + explicit `guard let`. The IUO path crashed if `doConvert` returned
  without assigning AND without throwing (latent in a future refactor).
- **Profile-sync `bundledDefaultsKeys` expanded from ~15 keys → 70+**, covering
  every settings audit catalogued key (Stage, History, Keep Awake, Recorder,
  Snip, Calc, QR, OCR, Image Tools, File Hash, Log, Rename, Snippets, GPU,
  App Launcher, Updater, PDF recents, Color history). Migrating to a new Mac
  via the profile bundle now preserves the user's settings instead of silently
  resetting most of them.

### Changed

- **`UpdateChecker.fallbackVersion`** bumped to `1.1.0-beta.2`. The in-app
  sidebar footer + Settings → About banner read this when
  `CFBundleShortVersionString` is the placeholder `1.0` (dev / ad-hoc builds).
- **`CutPaste.enabled`** documented in code as intentionally transient
  (not a persistence bug). Each session re-engaging the CGEventTap that
  intercepts ⌘X/⌘V is an explicit user opt-in — the security-by-default
  contract Trove ships with.

### Known gaps (carried to beta.3+)

- ~140 Sendable-closure-capture warnings (Swift 6 strict-concurrency mode previews).
- ~89 raw `.font(.headline)` calls that should be `.headerText()`.
- `TroveEmptyState` built but unadopted across 6+ panes.
- AI Bridge still entirely dead.

---

## [1.1.0-beta.1] — Unreleased

The big polish + robustness pass. Every pane audited from a power-daily-user
perspective and a security/correctness lens. Compile + lint + 218/218 tests pass.

### Added

- **Stage**: per-item Save…/Save to Downloads/Copy Path/Copy to Clipboard/drag-out
  context menu actions (DEVELOP_RULES §9).
- **Stage**: drag-reorder via `List.onMove` (persists with the rest of the items).
- **Stage**: persistence to `stage.json` (atomic, debounced + synchronous flush on
  `willTerminate`); items survive quits/relaunch.
- **Stage**: `StagedItem` made a `final class` so `ForEach` identity is stable
  across mutations — kills the O(n) thumbnail re-fetch on every change.
- **Stage**: `Open files…` CTA in the empty state.
- **Stage**: tolerant `Codable` decoder on `StagedItemRecord` so future schema
  additions can't silently empty the Stage on upgrade.
- **FloatingStage**: now reachable — View-menu command + toolbar `pip.enter`
  button wired to `FloatingStageController.shared.toggle()`. Previously dead.
- **AutoCompress**: wired live from `Stage.addFile/addImage/captureScreenshot`,
  plus a user-tunable quality slider (default 0.78, range 0.50–0.98) in
  Settings → Stage.
- **AltTab**: real window thumbnails via ScreenCaptureKit (was a permanent
  TODO before this release). Falls back to the app-icon overlay on permission
  denial; inline Screen Recording permission card.
- **Snap hotkeys**: now user-rebindable per-direction with conflict detection.
- **OCR**: language hint picker; `recognitionLanguage` flows into `VNRecognizeTextRequest`.
- **QR**: SVG vector export + custom foreground/background colors + persistent
  correction level + export size picker.
- **Mirror**: always-on-top floating panel + snapshot affordance
  (copy/save/Send to Stage).
- **Snip annotate**: redo stack parallel to undo; off-main render so committing
  a 4K annotation no longer freezes the UI.
- **Calculator**: `^` exponent operator; temperature / speed / area / energy
  units (incl. a custom `UnitEnergy.wattHours = 3600 J`); per-line "Copy
  expression + result" and "Send to Stage"; clear-confirm dialog.
- **Text Tools**: pipeline persistence (`xform-pipeline.json`, atomic); ReDoS
  guard catches `(a|a)+`-class patterns; off-main run with cancellation token;
  searchable add-transform menu.
- **Image Tools**: before/after preview before commit; per-source remove;
  settings persist; output thumbnails.
- **PDF**: image-watermark actually baked into the saved PDF (PDFKit's private
  `STAMP_IMAGE` key is dropped on serialization — fixed by rendering into the
  page's CGContext per page); freeform render DPI 72–600; live watermark
  preview; `PDFOpsRecentEntry` tolerant decoder.
- **File Hash**: SHA-512 (single-pass alongside MD5/SHA1/SHA256); opt-in
  auto-copy preference.
- **Rename**: off-main `apply()` with per-file rollback; settings persist;
  ReDoS guard before NSRegularExpression construction; preview rows show
  parent folder when the same filename appears in multiple dirs.
- **Recorder**: real region picker (multi-screen crosshair NSWindow — previous
  picker silently captured from `(0,0)` because it only read the PNG size); all
  settings persist (mic / sys audio / codec / fps / output folder / send-to-Stage);
  HEVC + 24/30/60 fps pickers; live capture preview while recording; bitrate
  cap (`200 Mbps`) so 5K Retina no longer overflows to ~59 Gbps; `isRecording`
  gate now taken synchronously before the first await so a double-tap during
  the 300 ms SCK content fetch can't build two writers; SCStream frame
  callback uses `[weak self]` (kills the per-frame `RecEngine` retain that
  piled up during `finishWriting`).
- **Big Scan**: proportional stacked-bar disk-usage breakdown; exclude list
  (defaults include `node_modules`/`.git`); sort/filter controls; stale-cache
  age infobar; trash off-main.
- **Library**: QuickLook thumbnails for image/PDF/video rows; `saveOne` is
  now atomic (tmp + `replaceItemAt`); `deleteAllLocalData` actually clears
  UserDefaults + Keychain (not just the App Support folder, despite what the
  confirmation alert promised).
- **Outputs Library**: tolerant `OutputEntry` decoder so adding new fields
  can't silently empty the recoverable cache on upgrade.
- **Account**: Export/backup data; Delete all local data (with confirmation).
- **Updater**: explicit Stable / Beta channel picker; in-app changelog renderer
  for current release (GitHub release body as Markdown).
- **Permissions**: refresh on pane reappear (debounced); generic description
  instead of the literal TCC.db path; correct `Privacy` deep link for the
  Network entry.
- **Customize sidebar**: now includes the `App` section so the Library pane
  can actually be hidden (`sectionOrder` was previously missing it).
- **Color tokens**: `Color.troveFg` (primary text), `Color.troveSuccess`,
  `Color.troveWarning`, `Color.troveError`.
- **Shared UI**: reusable `TroveEmptyState<CTA>` and `TroveInlineError` views.
- **Tolerant Codable decoders** added to `StagedItemRecord`, `OutputEntry`,
  `PDFOpsRecentEntry`, `TroveCustomTheme`, `HotkeyBinding` — five separate
  silent-on-upgrade data-loss vectors closed.

### Fixed

- **P0** `AltTab` window thumbnails were a permanent no-op (TODO since
  `CGWindowListCreateImage` was removed) — implemented via SCK.
- **P0** Recorder region picker captured `(0,0)`-relative every time —
  rewritten with a real crosshair overlay window per display.
- **P0** PDF image-watermark silently dropped from saved files (PDFKit
  `STAMP_IMAGE` private key never serializes).
- **P0** Clipboard history was fully ephemeral — now persists.
- **P0** Multiple panes had main-thread blocking work: GPU/network/log sampling,
  AX enumeration in WindowSnap, OCR `waitUntilExit`, big_scan walk, PDF document
  open, rename apply, snip annotate render, addImage tiff/PNG encode. All moved
  off-main with reentry guards.
- **P0** Pasteboard `strict:false` path skipped the size guard — a 500 MB
  clipboard image OOM-crashed the app on every explicit paste.
- **P0** `cutpaste.swift` performPaste moved symlinks (incl. symlinks pointing
  at `/dev/zero`) — now skipped.
- **P0** Auto-installer continuation race on double-clicking "Install Now" —
  protected with `os_unfair_lock`; UUID-namespaced staging dir.
- **P0** Log Viewer "Save All" loaded the entire `log show` output into a
  single Data — now streams line-by-line.
- **P0** Stage no longer drops mutations within 300ms of quit (force-flush on
  `troveWillTerminate`).
- **P0** Stage `writeToDisk` no longer silently discards `replaceItemAt`
  errors — falls back to `moveItem`.
- **P0** Recorder bitrate `pxW × pxH × 4` overflowed on 5K Retina to ~59 Gbps;
  capped to 200 Mbps.
- **P0** Recorder `isRecording = true` was set AFTER 300 ms of awaits in
  `start()` — a double-tap built two writers on the same path. Now set
  synchronously via an `isStarting` flag.
- **P0** Stage card title `.foregroundStyle(.white)` was invisible in the
  light theme (cardSolid #F1F0EB ≈ white). Switched to `Color.troveFg`.
- **P0** Toast appearance now fires `NSAccessibility.announcementRequested` —
  VoiceOver users were getting zero feedback for any action.
- **P1** Many destructive deletes were `removeItem` instead of `trashItem` —
  swept across Library, big_scan, etc.
- **P1** `Mirror` floating panel observer leaked one observer per open/close.
- **P1** `AutoCompress` had no symlink/regular-file guard; non-atomic write
  could leave a partial file and the `fileExists` guard then permanently
  blocked future passes for that source.
- **P1** Snip annotate `bounds.width == 0` produced `inf` scale on first
  layout pass; guarded.
- **P1** OCR `OCRTargetLanguage.smartDefault()` crashed if `all` were empty
  (`all[0]`); now a safe English fallback.
- **P1** Rename regex compiled with no ReDoS guard; now uses the same
  `rejectCatastrophicRegex` heuristic as text-transforms.
- **P1** Big Scan stale-result race: cancellable Task + generation counter
  prevents an older scan from overwriting a newer one when the root changes.
- **P1** Color picker history was in-memory only — now persists.
- **P1** Snip and QR settings persist across launches.
- **P1** `CustomizeView` had `App` missing from `sectionOrder` — Library could
  not be hidden.
- **P1** `deleteAllLocalData()` left UserDefaults and Keychain intact despite
  the confirmation alert promising a full reset.
- **P1** Numerous raw `Color.white.opacity(…)` / `.gray` / `.green` view tints
  swapped for palette tokens so the light theme reads correctly.

### Changed

- Default theme remains Dark with Light/System/Linear/Cron/Custom alternatives.
- `lint-trove` continues to ban `try!`, `as!`, `DispatchQueue.main.sync`, bare
  `.waitUntilExit()`, `.first!`/`.last!`, `fatalError`. All rules clean.

### Security

- Per `auto_installer.swift` audit: shell escape in the codesign verification
  path tracks `\` and `"` but not `$` / backtick. Local threat model only
  (the path is `Bundle.main.bundleURL.path`), but the planned mitigation is
  to drop `/bin/sh -c` entirely and call `/usr/bin/codesign` directly with
  a second `Pipe()` for stderr. Tracked for 1.1.0-beta.2.

### Known gaps (carried forward to beta.2+)

- AI Bridge (CommandX-replacement) is still entirely dead. Separate feature
  pass.
- ~140 Sendable-closure-capture warnings (Swift 6 mode previews). Doesn't
  ship a worse app today; Swift-6 strict-concurrency cleanup pass needed.
- `NoteStore` / `ClipHistory` / `SnippetStore` `@StateObject` default
  initializers do synchronous `boundedRead` + JSON decode on main —
  AttributeGraph SIGTRAP risk on slow/cold disks. Pattern-fix pending.
- ~89 raw `.font(.headline)` calls that should be `.headerText()` for
  VoiceOver heading-rotor coverage.
- The existing `TroveEmptyState` shared view is built but not yet adopted by
  the 6+ panes that each still roll their own empty state.

---

## [1.0.7] — 2026-05-17

Last public Stable release before the polish-and-robustness pass.
See <https://github.com/ArnavGoel03/trove/releases/tag/v1.0.7>.
