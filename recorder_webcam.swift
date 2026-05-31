// Trove — Webcam capture for the Recorder (power-user items #1 + #19).
//
// Two pro features sharing one capture class:
//
//   • #1  Webcam PIP — when enabled, the recorder runs a parallel
//         AVCaptureSession that writes the camera feed to
//         `<recording-stem>.webcam.mov` alongside the main screen
//         recording. The user gets two synchronized files; pulling
//         them into iMovie / DaVinci / Final Cut + dropping the
//         webcam on top with a corner crop is a 30-second composite.
//         A future batch can add an automatic AVMutableComposition
//         finalize step that bakes the PIP into a single MP4 (the
//         "Tier 1 headline" implementation). For now, side-by-side
//         shipping unlocks the workflow with substantially less risk.
//
//   • #19 Webcam-only mode — record JUST the camera, no screen. Same
//         AVCaptureMovieFileOutput, no SCStream involvement at all.
//         Useful for founder updates, Loom-style talking-head messages,
//         testimonial recordings — anything where the screen isn't the
//         subject. Source mode picker in the Recorder pane gets a new
//         `.webcam` case that flips the engine into this path.
//
// Both modes use a separate AVCaptureSession from the Mirror pane's,
// even when both are running. Sharing a session sounds tempting but
// AVCaptureMovieFileOutput conflicts with AVCaptureVideoPreviewLayer
// in awkward ways (the preview becomes "owned" by the writer and
// frames stutter on the Mirror pane). Two sessions cost a few MB of
// RAM, no perceptible CPU. The cleanliness is worth it.

import AppKit
import AVFoundation
import Combine

// =============================================================================
// MARK: - User preferences
// =============================================================================

enum RecWebcamCorner: String, CaseIterable, Identifiable, Codable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeading:     return "Top left"
        case .topTrailing:    return "Top right"
        case .bottomLeading:  return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }
}

enum RecWebcamSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
    /// Fraction of the parent video's short edge the PIP occupies.
    /// Tuned to look right at common screen sizes (1080p → 5.4 cm on
    /// the screen for `.medium`); pro users can rebake the composite
    /// at any size later.
    var fractionOfShortEdge: Double {
        switch self {
        case .small:  return 0.12
        case .medium: return 0.20
        case .large:  return 0.30
        }
    }
}

// =============================================================================
// MARK: - Capture class
// =============================================================================

@MainActor
final class RecWebcamCapture: NSObject {

    /// Latest output URL the writer landed on (`<stem>.webcam.mov`).
    /// Read by the recorder pane to surface the file in the last-
    /// recording row alongside the main screen recording.
    private(set) var lastOutputURL: URL?

    /// Last error from the writer. Surfaced as a toast and into the
    /// engine's `lastError` so the pane shows a banner.
    private(set) var lastError: Error?

    private let session = AVCaptureSession()
    private var fileOutput: AVCaptureMovieFileOutput?
    private var currentInput: AVCaptureDeviceInput?

    /// Used by the writer delegate to fire a completion handler back
    /// to the engine without holding a strong reference cycle.
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    /// Picks the FaceTime / built-in HD camera by default. Override
    /// via `setDevice(uid:)` to record an external webcam.
    private func defaultDevice() -> AVCaptureDevice? {
        if let front = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                for: .video, position: .front) {
            return front
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Reconfigure the session with `device`. Tears down any previous
    /// input and re-adds the new one inside a `beginConfiguration` /
    /// `commitConfiguration` block so frames don't drop mid-swap.
    private func install(device: AVCaptureDevice) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let prev = currentInput {
            session.removeInput(prev)
            currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            currentInput = input
        } catch {
            self.lastError = error
            return false
        }
        if fileOutput == nil {
            let out = AVCaptureMovieFileOutput()
            // Default codec — H.264 is the universally-supported choice
            // for downstream editing tools. HEVC would be smaller but
            // older versions of Premiere choke on it.
            if session.canAddOutput(out) {
                session.addOutput(out)
                fileOutput = out
            }
        }
        return true
    }

    /// Public API.
    ///
    /// Begins recording the webcam to `<destination>`. The session is
    /// configured + started if it isn't already running. Idempotent —
    /// calling start() while already recording is a no-op.
    func start(to destination: URL, deviceUID: String? = nil) {
        // If the user picked a non-default device, find it; otherwise
        // fall through to the default front camera selection.
        let device: AVCaptureDevice?
        if let uid = deviceUID {
            device = AVCaptureDevice(uniqueID: uid) ?? defaultDevice()
        } else {
            device = defaultDevice()
        }
        guard let device else {
            self.lastError = NSError(domain: "trove.rec.webcam", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "No camera available."])
            return
        }
        if !session.isRunning {
            guard install(device: device) else { return }
            session.startRunning()
        }
        guard let out = fileOutput, !out.isRecording else { return }
        // The MovieFileOutput needs a writable directory; create the
        // parent if it doesn't exist (matches the screen-recording
        // path so a fresh ~/Movies/Trove works on first launch).
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Refuse to clobber an existing file — bump a counter suffix
        // until we find a free name. Aligned with the main screen
        // recording's bump logic (see start() in RecEngine).
        var finalURL = destination
        var bump = 1
        while FileManager.default.fileExists(atPath: finalURL.path) {
            let stem = (destination.lastPathComponent as NSString).deletingPathExtension
            let ext  = destination.pathExtension
            let nm   = "\(stem)-\(bump).\(ext)"
            finalURL = destination.deletingLastPathComponent()
                .appendingPathComponent(nm)
            bump += 1
            if bump > 999 { break }
        }
        out.startRecording(to: finalURL, recordingDelegate: self)
    }

    /// Stop the writer. Returns the finalized output URL (or nil on
    /// failure). Idempotent — calling stop() when not recording
    /// immediately returns the last-known URL.
    func stop() async -> URL? {
        guard let out = fileOutput, out.isRecording else {
            return lastOutputURL
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            self.stopContinuation = cont
            out.stopRecording()
        }
    }

    /// Tear down. Called when the recorder pane disappears or the app
    /// is shutting down.
    func teardown() {
        if let out = fileOutput, out.isRecording { out.stopRecording() }
        if session.isRunning { session.stopRunning() }
        if let prev = currentInput {
            session.removeInput(prev)
            currentInput = nil
        }
        if let out = fileOutput {
            session.removeOutput(out)
            fileOutput = nil
        }
    }
}

// =============================================================================
// MARK: - AVCaptureFileOutputRecordingDelegate
// =============================================================================

extension RecWebcamCapture: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                 didFinishRecordingTo outputFileURL: URL,
                                 from connections: [AVCaptureConnection],
                                 error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.lastError = error
                self.lastOutputURL = nil
            } else {
                self.lastOutputURL = outputFileURL
            }
            self.stopContinuation?.resume(returning: self.lastOutputURL)
            self.stopContinuation = nil
        }
    }
}
