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

    /// One launchable app entry.
    struct AppEntry: Identifiable, Hashable {
        let id: String          // bundle path (stable across renames)
        let displayName: String // "Visual Studio Code"
        let bundleURL: URL
        let bundleID: String?   // may be nil for malformed bundles
    }

    @Published private(set) var entries: [AppEntry] = []
    @Published private(set) var indexed = false

    // Persisted launch frequency: bundlePath → launch count.
    private static let freqKey = "appLauncher.frequency"
    private var frequency: [String: Int] = {
        UserDefaults.standard.dictionary(forKey: AppLauncherIndex.freqKey) as? [String: Int] ?? [:]
    }()

    // Icon cache (main-actor only).
    private var iconCache: [String: NSImage] = [:]

    private var launchedAppObserver: NSObjectProtocol?
    private var volumeMountObserver: NSObjectProtocol?
    private var pendingRescan: Task<Void, Never>?

    private init() {
        Task.detached(priority: .utility) {
            let scanned = Self.scanInstalledApps()
            await MainActor.run {
                AppLauncherIndex.shared.entries = scanned
                AppLauncherIndex.shared.indexed = true
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        // Refresh on app launch (debounced 2 s to coalesce login-item storms).
        launchedAppObserver = ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebouncedRescan() }
        }
        // Refresh when a new volume mounts (external drive / DMG with apps).
        volumeMountObserver = ws.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebouncedRescan() }
        }
    }

    deinit {
        let ws = NSWorkspace.shared.notificationCenter
        if let t = launchedAppObserver { ws.removeObserver(t) }
        if let t = volumeMountObserver  { ws.removeObserver(t) }
    }

    /// Trigger an immediate (non-debounced) rescan. Exposed for UI "Rescan" button.
    func rescan() {
        pendingRescan?.cancel()
        pendingRescan = Task.detached(priority: .utility) {
            let scanned = AppLauncherIndex.scanInstalledApps()
            await MainActor.run { AppLauncherIndex.shared.entries = scanned }
        }
    }

    private func scheduleDebouncedRescan() {
        pendingRescan?.cancel()
        pendingRescan = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let scanned = AppLauncherIndex.scanInstalledApps()
            await MainActor.run { AppLauncherIndex.shared.entries = scanned }
        }
    }

    // MARK: - Scan

    /// Enumerate `.app` bundles across all standard application directories,
    /// including /System/Applications, Xcode bundles, etc. Uses
    /// NSSearchPathForDirectoriesInDomains(.applicationDirectory, .allDomainsMask).
    nonisolated static func scanInstalledApps() -> [AppEntry] {
        let fm = FileManager.default
        // Collect all application directories from all domains.
        var dirs: [URL] = NSSearchPathForDirectoriesInDomains(
            .applicationDirectory, .allDomainsMask, true
        ).map { URL(fileURLWithPath: $0) }
        // Explicitly add /System/Applications (not always returned by NSSearchPath).
        dirs.append(URL(fileURLWithPath: "/System/Applications"))
        // De-duplicate.
        dirs = Array(Set(dirs.map { $0.standardizedFileURL.path }).map { URL(fileURLWithPath: $0) })

        var results: [String: AppEntry] = [:]  // keyed by bundleID or path
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
                guard url.pathExtension.lowercased() == "app" else { continue }
                guard let bundle = Bundle(url: url) else { continue }
                let bundleID = bundle.bundleIdentifier
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let entry = AppEntry(id: path, displayName: name, bundleURL: url, bundleID: bundleID)
                let key = bundleID ?? path
                if let existing = results[key] {
                    // Prefer /Applications over other dirs, /System/Applications last resort.
                    let prefersNew = path.hasPrefix("/Applications/")
                        && !existing.id.hasPrefix("/Applications/")
                    if prefersNew { results[key] = entry }
                } else {
                    results[key] = entry
                }
            }
        }
        return results.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Launch

    /// Launch an app entry. If it's already running, activate it instead
    /// of opening a new instance. Increments frequency counter for ranking.
    func launch(_ entry: AppEntry) {
        // Increment frequency counter for ranking.
        let count = (frequency[entry.id] ?? 0) + 1
        frequency[entry.id] = count
        UserDefaults.standard.set(frequency, forKey: Self.freqKey)

        // If the app is already running, activate it.
        if let bid = entry.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let name = entry.displayName
        NSWorkspace.shared.openApplication(at: entry.bundleURL, configuration: config) { _, error in
            guard let error else { return }
            Task { @MainActor in
                SharedStore.stage.flash("Couldn't open \(name): \(error.localizedDescription)", kind: .warning)
            }
        }
    }

    /// Returns entries sorted by frequency (most-launched first), then alphabetically.
    /// Used by Quick Switcher to surface recently-used apps higher.
    func rankedEntries() -> [AppEntry] {
        entries.sorted { a, b in
            let fa = frequency[a.id] ?? 0
            let fb = frequency[b.id] ?? 0
            if fa != fb { return fa > fb }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Icon for an app entry. @MainActor + cached to avoid hitting NSWorkspace
    /// per-render (which does disk I/O on first access per path).
    @MainActor
    func icon(for entry: AppEntry) -> NSImage {
        if let cached = iconCache[entry.id] { return cached }
        let img = NSWorkspace.shared.icon(forFile: entry.bundleURL.path)
        iconCache[entry.id] = img
        return img
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
    /// Returns entries sorted by launch frequency (most-launched first).
    /// The Quick Switcher's own score() ranking further re-ranks by query match.
    @MainActor
    func quickSwitcherEntries() -> [AppEntry] { rankedEntries() }
}
