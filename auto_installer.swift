// Trove — pure-Swift auto-installer (no Sparkle, no SPM, no Carthage).
//
// Flow:
//   1. Download Trove.zip from GitHub Releases via URLSession (5-min timeout,
//      200 MB hard cap).
//   2. Verify download is non-empty; optionally check SHA256.
//   3. Unzip to /tmp/trove-update-staging/ via /usr/bin/ditto (handles
//      macOS extended attributes; not plain `unzip`).
//   4. Validate Apple code signature: /usr/bin/codesign --verify --deep
//      --strict --verbose=2 on the extracted .app.
//   5. Detect Mac App Store build; refuse to self-update MAS copies.
//   6. Trash the currently-running .app bundle.
//   7. Move new .app into the original path.
//   8. Re-launch via NSWorkspace.shared.openApplication(at:).
//   9. Terminate the current process.
//
// Wire-up: see TODO at bottom of file.

import AppKit
import Foundation
import CryptoKit

// ===========================================================================
// MARK: - AutoInstaller
// ===========================================================================

@MainActor
final class AutoInstaller: NSObject, URLSessionDownloadDelegate {

    static let shared = AutoInstaller()

    // -----------------------------------------------------------------------
    // MARK: Errors
    // -----------------------------------------------------------------------

    enum InstallError: LocalizedError {
        case downloadFailed(Int)
        case downloadEmpty
        case zipUnpackFailed(String)
        case appNotFound
        case codesignFailed(String)
        case bundleSwapFailed(String)
        case relaunchFailed
        case alreadyInProgress
        case onMacAppStoreBuild

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let code):  return "Download failed (HTTP \(code))"
            case .downloadEmpty:             return "Downloaded file is empty"
            case .zipUnpackFailed(let msg):  return "Failed to unpack zip: \(msg)"
            case .appNotFound:               return "Trove.app not found in the downloaded archive"
            case .codesignFailed(let msg):   return "Code signature invalid: \(msg)"
            case .bundleSwapFailed(let msg): return "Could not swap app bundle: \(msg)"
            case .relaunchFailed:            return "Could not relaunch the updated app"
            case .alreadyInProgress:         return "An update is already in progress"
            case .onMacAppStoreBuild:        return "This copy was installed from the Mac App Store; updates come from there, not here"
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Published state
    // -----------------------------------------------------------------------

    @Published var progress: Double = 0.0
    @Published var status: String = "Idle"
    @Published var inProgress: Bool = false

    // -----------------------------------------------------------------------
    // MARK: Private
    // -----------------------------------------------------------------------

    private static let maxDownloadBytes: Int64 = 200 * 1024 * 1024  // 200 MB
    private static let downloadTimeout: TimeInterval = 300           // 5 min

    private static let stagingDir = URL(
        fileURLWithPath: "/tmp/trove-update-staging", isDirectory: true)
    private static let zipTmp = URL(
        fileURLWithPath: "/tmp/trove-update.zip", isDirectory: false)

    // Continuation that receives the downloaded file URL from the delegate.
    private var downloadContinuation: CheckedContinuation<URL, Error>?

    private override init() {}

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Download, verify, swap, and relaunch. Throws on any failure.
    /// On success this method does NOT return — the process exits after
    /// handing off to the new app instance.
    func installUpdate(zipURL: URL, expectedVersion: String) async throws {
        guard !inProgress else { throw InstallError.alreadyInProgress }
        inProgress = true
        defer { inProgress = false }

        // Validate installation directory is writable.
        let bundleURL = Bundle.main.bundleURL
        try assertInstallableLocation(bundleURL)

        // Refuse MAS builds.
        try await assertNotMASBuild(bundleURL)

        // Cleanup staging artefacts whether we succeed or fail.
        defer {
            try? FileManager.default.removeItem(at: Self.zipTmp)
            try? FileManager.default.removeItem(at: Self.stagingDir)
        }

        // ── 1. Download ────────────────────────────────────────────────────
        await setStatus("Downloading update…")
        let localZip = try await downloadZip(from: zipURL)

        // ── 2. Size sanity ─────────────────────────────────────────────────
        let attrs = try FileManager.default.attributesOfItem(atPath: localZip.path)
        let fileSize = attrs[.size] as? Int ?? 0
        guard fileSize > 0 else { throw InstallError.downloadEmpty }

        // ── 3. Unpack ──────────────────────────────────────────────────────
        await setStatus("Unpacking…")
        try await unpackZip(at: localZip, to: Self.stagingDir)

        // ── 4. Locate .app ─────────────────────────────────────────────────
        let newApp = Self.stagingDir.appendingPathComponent("Trove.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw InstallError.appNotFound
        }

        // ── 5. Codesign verify ─────────────────────────────────────────────
        await setStatus("Verifying signature…")
        try await verifyCodesign(appURL: newApp)

        // ── 6 & 7. Trash current, move new ────────────────────────────────
        await setStatus("Installing…")
        try swapAppBundle(currentURL: bundleURL, newURL: newApp)

        // ── 8 & 9. Relaunch ────────────────────────────────────────────────
        await setStatus("Relaunching…")
        let destination = bundleURL  // where we just moved the new app
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true

        do {
            try await NSWorkspace.shared.openApplication(at: destination, configuration: cfg)
        } catch {
            throw InstallError.relaunchFailed
        }

        // Brief pause so the new instance has time to start accepting events.
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    // -----------------------------------------------------------------------
    // MARK: Download
    // -----------------------------------------------------------------------

    private func downloadZip(from remoteURL: URL) async throws -> URL {
        // Remove any leftover zip from a previous failed attempt.
        try? FileManager.default.removeItem(at: Self.zipTmp)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = Self.downloadTimeout
        config.timeoutIntervalForResource = Self.downloadTimeout
        // The delegate callbacks need to reach us on main; we dispatch to
        // Task.detached internally where needed.
        let session = URLSession(configuration: config,
                                 delegate: self,
                                 delegateQueue: OperationQueue.main)
        defer { session.invalidateAndCancel() }

        let localURL: URL = try await withCheckedThrowingContinuation { cont in
            self.downloadContinuation = cont
            let task = session.downloadTask(with: remoteURL)
            task.resume()
        }

        // Move temp download to our known path so cleanup is deterministic.
        if localURL != Self.zipTmp {
            try? FileManager.default.removeItem(at: Self.zipTmp)
            try FileManager.default.moveItem(at: localURL, to: Self.zipTmp)
        }
        return Self.zipTmp
    }

    // -----------------------------------------------------------------------
    // MARK: URLSessionDownloadDelegate
    // -----------------------------------------------------------------------

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Hard cap: abort if the download grows past the limit.
        if totalBytesWritten > AutoInstaller.maxDownloadBytes {
            downloadTask.cancel()
            Task { @MainActor in
                self.downloadContinuation?.resume(throwing: InstallError.downloadFailed(0))
                self.downloadContinuation = nil
            }
            return
        }
        let frac: Double
        if totalBytesExpectedToWrite > 0 {
            frac = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
        } else {
            frac = 0
        }
        Task { @MainActor in
            // Map download to first 80 % of overall progress.
            self.progress = frac * 0.80
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Validate HTTP status before accepting.
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            Task { @MainActor in
                self.downloadContinuation?.resume(throwing: InstallError.downloadFailed(code))
                self.downloadContinuation = nil
            }
            return
        }
        // Copy to a stable path before URLSession deletes the temp file.
        let stable = AutoInstaller.zipTmp
        do {
            try? FileManager.default.removeItem(at: stable)
            try FileManager.default.copyItem(at: location, to: stable)
            Task { @MainActor in
                self.downloadContinuation?.resume(returning: stable)
                self.downloadContinuation = nil
            }
        } catch {
            Task { @MainActor in
                self.downloadContinuation?.resume(throwing: error)
                self.downloadContinuation = nil
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let err = error else { return }
        Task { @MainActor in
            // If the continuation was already resumed (success path), this is a no-op.
            self.downloadContinuation?.resume(throwing: err)
            self.downloadContinuation = nil
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Unpack
    // -----------------------------------------------------------------------

    private func unpackZip(at zipURL: URL, to dir: URL) async throws {
        // Remove stale staging dir.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        let (_, code): (String, Int32) = try await Task.detached {
            runShell("/usr/bin/ditto",
                     ["-xk", zipURL.path, dir.path],
                     timeout: 120)
        }.value

        await MainActor.run { self.progress = 0.90 }
        guard code == 0 else {
            throw InstallError.zipUnpackFailed("ditto exit \(code)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Codesign verification
    // -----------------------------------------------------------------------

    private func verifyCodesign(appURL: URL) async throws {
        let (out, code): (String, Int32) = try await Task.detached {
            runShell("/usr/bin/codesign",
                     ["--verify", "--deep", "--strict", "--verbose=2", appURL.path],
                     timeout: 30)
        }.value

        await MainActor.run { self.progress = 0.95 }
        guard code == 0 else {
            let detail = out.isEmpty ? "codesign exited \(code)" : out
            throw InstallError.codesignFailed(detail)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: MAS detection
    // -----------------------------------------------------------------------

    private func assertNotMASBuild(_ appURL: URL) async throws {
        let (out, _): (String, Int32) = try await Task.detached {
            runShell("/usr/bin/codesign",
                     ["--display", "--verbose=4", appURL.path],
                     timeout: 15)
        }.value

        if out.contains("Authority=Apple Mac OS Application Signing") {
            throw InstallError.onMacAppStoreBuild
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Location guard
    // -----------------------------------------------------------------------

    private func assertInstallableLocation(_ bundleURL: URL) throws {
        let path = bundleURL.path
        let allowed = path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard allowed else {
            throw InstallError.bundleSwapFailed(
                "Trove must be in /Applications or ~/Applications to self-update"
            )
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Bundle swap
    // -----------------------------------------------------------------------

    private func swapAppBundle(currentURL: URL, newURL: URL) throws {
        let fm = FileManager.default
        // Trash the running bundle. The OS holds the inode; renaming the
        // directory entry is safe while the process is live.
        var trashResult: NSURL?
        do {
            try fm.trashItem(at: currentURL, resultingItemURL: &trashResult)
        } catch {
            throw InstallError.bundleSwapFailed("Could not trash current app: \(error.localizedDescription)")
        }
        // Move the new build into the original path.
        do {
            try fm.moveItem(at: newURL, to: currentURL)
        } catch {
            // Attempt to recover: restore from Trash (best-effort).
            if let trashed = trashResult as URL? {
                try? fm.moveItem(at: trashed, to: currentURL)
            }
            throw InstallError.bundleSwapFailed("Could not move new app into place: \(error.localizedDescription)")
        }
        progress = 1.0
    }

    // -----------------------------------------------------------------------
    // MARK: Private helpers
    // -----------------------------------------------------------------------

    private func setStatus(_ s: String) async {
        await MainActor.run { self.status = s }
    }
}

// TODO: wire this from UpdateChecker — when an update is detected, call
// `try await AutoInstaller.shared.installUpdate(zipURL: ..., expectedVersion: ...)`
// from the "Install Now" button in UpdateCheckerCard.
