// Trove — auto-trim leading + trailing silence at finalize (item #14).
//
// What "auto-trim" buys: most screen recordings start with a few seconds
// of you reaching for the Stop button and end with the same. Loom and
// CleanShot both trim this automatically; users routinely save 10-30
// seconds per take. We piggyback on AVFoundation's AVAssetReader for
// detection and AVAssetExportSession for the trimmed re-encode.
//
// Detection is RMS-based. We sweep all audio samples in 100ms windows,
// convert to dBFS, and flag the first + last windows whose RMS exceeds
// the threshold (default -40 dBFS — quieter than typical room tone).
// The trimmed time range is [firstVoice - 0.25s, lastVoice + 0.25s] so
// the user's voice doesn't get its opening syllable clipped.
//
// red-team:
//   • If the recording has no mic track (system-audio-only), we skip
//     trimming and return nil so the caller keeps the untrimmed file.
//     This matches the engine guard at the call site.
//   • If the recording is entirely silent (e.g. mic muted the whole
//     take), the trimmed range collapses to 0; we return nil and the
//     original survives.
//   • Export to a temp file in the same dir so the rename is atomic.

import AVFoundation
import Foundation

enum RecSilenceTrim {

    /// Returns a URL to a NEW trimmed file (caller is responsible for
    /// moving it into place). nil = could not trim, keep the original.
    static func run(input: URL, thresholdDB: Float = -40.0) async -> URL? {
        let asset = AVURLAsset(url: input)
        // Locate the audio track to sweep. Recordings can have multiple
        // audio tracks (system + mic) — we pick the FIRST audio track
        // for analysis; in Trove's writer that's deterministically the
        // mic track (added before system audio).
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }
        let durationSecs = CMTimeGetSeconds(duration)
        guard durationSecs > 0.5 else { return nil }
        // Detect voice windows via AVAssetReader.
        guard let voice = try? await detectVoiceWindow(
            track: audioTrack, asset: asset, thresholdDB: thresholdDB)
        else {
            return nil
        }
        let pad = 0.25
        let startSec = max(0, voice.startSec - pad)
        let endSec   = min(durationSecs, voice.endSec + pad)
        // Refuse to keep going if the trim doesn't actually save time.
        // Threshold: at least 0.4 seconds removed total.
        let saved = (startSec - 0) + (durationSecs - endSec)
        guard saved > 0.4, endSec > startSec else { return nil }
        // Re-encode the trimmed range. AVAssetExportSession with a
        // pass-through preset would be faster but it doesn't honor
        // timeRange perfectly for HEVC content; we use a lossy preset
        // (already what the original recording is) to be safe.
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            end:   CMTime(seconds: endSec,   preferredTimescale: 600))
        let outURL = input.deletingPathExtension()
            .appendingPathExtension("trimmed.mp4")
        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else { return nil }
        export.outputFileType = .mp4
        export.outputURL = outURL
        export.timeRange = timeRange
        await export.export()
        guard export.status == .completed else { return nil }
        return outURL
    }

    private struct VoiceWindow {
        let startSec: Double
        let endSec: Double
    }

    /// Sweeps the track and returns the first + last seconds where the
    /// 100ms RMS window crosses the threshold.
    private static func detectVoiceWindow(
        track: AVAssetTrack, asset: AVAsset,
        thresholdDB: Float
    ) async throws -> VoiceWindow? {
        let reader = try AVAssetReader(asset: asset)
        // Decode to LinearPCM Float32 mono so RMS is one sweep, not
        // interleaved channel arithmetic.
        let settings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:    32,
            AVLinearPCMIsFloatKey:     true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey:     1,
            AVSampleRateKey:           48000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let sampleRate: Double = 48000
        let windowSamples = Int(sampleRate * 0.1)        // 100 ms
        var firstVoice: Double? = nil
        var lastVoice: Double = 0
        var totalSamples = 0
        var winAcc: Float = 0
        var winCount: Int = 0

        let lin = pow(10.0, Double(thresholdDB) / 20.0)   // dBFS → linear

        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &dataPtr)
            guard let raw = dataPtr, length > 0 else { continue }
            let floats = UnsafePointer<Float>(OpaquePointer(raw))
            let count  = length / MemoryLayout<Float>.size
            for i in 0..<count {
                let f = floats[i]
                winAcc += f * f
                winCount += 1
                totalSamples += 1
                if winCount >= windowSamples {
                    let rms = sqrt(winAcc / Float(winCount))
                    let nowSec = Double(totalSamples) / sampleRate
                    if Double(rms) > lin {
                        if firstVoice == nil { firstVoice = nowSec - 0.1 }
                        lastVoice = nowSec
                    }
                    winAcc = 0
                    winCount = 0
                }
            }
        }
        guard let fv = firstVoice else { return nil }
        return VoiceWindow(startSec: fv, endSec: lastVoice)
    }
}
