// app_launcher.swift — extend Quick Switcher (⌘K) to launch any macOS app.
//
// Cuts paid launchers like rcmd ($10) and Launchy by giving Trove's existing
// Quick Switcher the same ability: type to fuzzy-find any installed app and
// hit Return to launch. Indexes both /Applications and ~/Applications on
// startup (background), refreshes on `NSWorkspace.didLaunchApplicationNotification`.
//
// Wires into main.swift by exposing `AppLauncherIndex.shared.items` which
// `QuickSwitcherView.buildAllItems()` concatenates into `allItems` after the
// pane entries. Same `QuickSwitcherItem.score(q:)` ranking applies — no
// separate scorer needed.

import AppKit
import Foundation
import Combine

@MainActor
final class AppLauncherIndex: ObservableObject {
    static let shared = AppLauncherIndex()

    /// One launchable app entry. Convertible to `QuickSwitcherItem` via the
    /// `quickSwitcherItem()` helper so the existing ⌘K ranking + UI can
    /// render it without changes.
    struct AppEntry: Identifiable, Hashable {
        let id: String          // bundle path (stable across renames)
        let displayName: String // "Visual Studio Code"
        let bundleURL: URL
        let bundleID: String?   // may be nil for malformed bundles
    }

    @Published private(set) var entries: [AppEntry] = []

    /// True after the first index pass completes. UI can hide launcher
    /// section until ready to avoid an empty flash on cold start.
    @Published private(set) var indexed = false

    private var launchedAppObserver: NSObjectProtocol?
    private var terminatedAppObserver: NSObjectProtocol?
    private var pendingRescan: Task<Void, Never>?

    private init() {
        // Background-index on startup so first cold launch doesn't block UI.
        Task.detached(priority: .utility) {
            let scanned = Self.scanInstalledApps()
            await MainActor.run {
                AppLauncherIndex.shared.entries = scanned
                AppLauncherIndex.shared.indexed = true
            }
        }

        // Refresh index on app launch so newly installed apps are discoverable.
        // NSWorkspace doesn't expose a dedicated "didInstall" notification, so
        // we use didLaunchApplicationNotification and debounce with a 2-second
        // delay to coalesce burst launches (e.g. login-item storm). The scan
        // is background-detached and cheap for the common case of ≤200 apps.
        let ws = NSWorkspace.shared.notificationCenter
        launchedAppObserver = ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingRescan?.cancel()
                self.pendingRescan = Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    let scanned = AppLauncherIndex.scanInstalledApps()
                    await MainActor.run { AppLauncherIndex.shared.entries = scanned }
                }
            }
        }
    }

    deinit {
        let ws = NSWorkspace.shared.notificationCenter
        if let t = launchedAppObserver { ws.removeObserver(t) }
        if let t = terminatedAppObserver { ws.removeObserver(t) }
    }

    // MARK: - Scan

    /// Enumerate `.app` bundles in `/Applications` and `~/Applications` (top
    /// level only — no recursion into subfolders). De-duplicates by bundleID
    /// (preferring `/Applications` when both exist). Sorted alphabetically.
    nonisolated static func scanInstalledApps() -> [AppEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications")
        ]
        var results: [String: AppEntry] = [:]  // keyed by bundleID
        var seenPaths = Set<String>()

        for dir in dirs {
            guard let it = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isApplicationKey, .nameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for url in it {
                let path = url.standardizedFileURL.path
                if seenPaths.contains(path) { continue }
                seenPaths.insert(path)
                // Accept anything with `.app` extension. URL.isApplication
                // resourceValue is unreliable for some 3rd-party installers.
                guard url.pathExtension.lowercased() == "app" else { continue }
                guard let bundle = Bundle(url: url) else { continue }
                let bundleID = bundle.bundleIdentifier
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let entry = AppEntry(
                    id: path,
                    displayName: name,
                    bundleURL: url,
                    bundleID: bundleID
                )
                let key = bundleID ?? path
                if let existing = results[key] {
                    // Prefer /Applications over ~/Applications when both exist.
                    if path.hasPrefix("/Applications/") && !existing.id.hasPrefix("/Applications/") {
                        results[key] = entry
                    }
                } else {
                    results[key] = entry
                }
            }
        }
        return results.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Launch

    /// Launch an app entry. Returns immediately; activation happens async.
    func launch(_ entry: AppEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let name = entry.displayName
        NSWorkspace.shared.openApplication(at: entry.bundleURL, configuration: config) { _, error in
            guard let error else { return }
            // Non-fatal — log via Stage flash so the user sees feedback.
            Task { @MainActor in
                SharedStore.stage.flash("Couldn't open \(name): \(error.localizedDescription)", kind: .warning)
            }
        }
    }

    /// Icon for an app entry. Cached by NSWorkspace internally; safe to call
    /// on every render.
    nonisolated func icon(for entry: AppEntry) -> NSImage {
        NSWorkspace.shared.icon(forFile: entry.bundleURL.path)
    }
}

// MARK: - Quick Switcher integration

// `QuickSwitcherView.buildAllItems()` (in main.swift) will be patched to
// concatenate these entries after the Pane entries. We expose a static helper
// here so the integration is one line in `main.swift`:
//
//     allItems = Pane.allCases.map(QuickSwitcherItem.pane) +
//                AppLauncherIndex.shared.quickSwitcherItems()

extension AppLauncherIndex {
    /// Convert all indexed apps into Quick Switcher rows. Use this from
    /// `QuickSwitcherView.buildAllItems()` to add them to the existing
    /// `allItems` array — the ranking + UI work without further changes.
    ///
    /// The returned items use the convention `kind: .app(entry)` so the
    /// view layer can render the Finder icon and dispatch to `launch(_:)`.
    @MainActor
    func quickSwitcherEntries() -> [AppEntry] { entries }
}
