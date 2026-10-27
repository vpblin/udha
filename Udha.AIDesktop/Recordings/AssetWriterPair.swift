import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// One output file carrying a video track and an audio track, fed by
/// `CMSampleBuffer`s arriving on whatever queue its capture source uses.
///
/// Both capture sources (screen and camera) write through this, so the two
/// files share their timing discipline exactly — which is the whole reason the
/// compositor can later lay them over each other with no alignment pass:
///
/// - **One session start for both writers.** The engine picks a single
///   `CMTime` on the host clock once both sources are actually running and
///   hands the same value to both. Samples older than it are dropped rather
///   than clamped — clamping would pile several frames onto one timestamp and
///   stall the encoder. Two files whose t=0 is the same wall-clock instant
///   need no offset later.
/// - **Pauses are excised, not gapped.** Every sample's presentation stamp has
///   the accumulated paused duration subtracted from it, so a resumed
///   recording is continuous rather than carrying a frozen stretch. Mirrors
///   the meeting recorder's "times are active recording time" rule.
/// - **`movieFragmentInterval` is set.** Without it an .mov that never gets
///   `finishWriting()` has no moov atom and is unrecoverable garbage — exactly
///   what a crash or force-quit mid-demo leaves behind. With it the file stays
///   playable up to the last flushed fragment, which is what gives
///   `RecordingStore.sweepCrashedRecordings` something to recover.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`, because
/// sample callbacks land on the capture source's queue while the engine drives
/// start/pause/finish from the main actor.
final class AssetWriterPair: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private let writer: AVAssetWriter
    /// Optional because this also backs the mic-only file produced when a
    /// recording has narration but no camera.
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var startTime: CMTime?
    /// Shared with the other writer so both files call the same instant t=0.
    private var sessionStart: SharedSessionStart?
    /// True for the screen writer, whose first frame opens the session. See
    /// `SharedSessionStart` for why the screen and not the camera.
    private var isPrimary = false
    private var pauseOffset: CMTime = .zero
    private var pausedAt: CMTime?
    private var finished = false
    private var sawVideo = false
    private var sawAudio = false
    /// So a wedged writer logs once rather than once per frame.
    private var loggedFailure = false

    var hasVideo: Bool { lock.withLock { sawVideo } }
    var hasAudio: Bool { lock.withLock { sawAudio } }

    private init(label: String, writer: AVAssetWriter, videoInput: AVAssetWriterInput?, audioInput: AVAssetWriterInput?) {
        self.label = label
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    /// A factory rather than a failable `init`, so the error paths can bail
    /// without every `let` already being assigned.
    static func make(url: URL, width: Int, height: Int, includeVideo: Bool, includeAudio: Bool, label: String) -> AssetWriterPair? {
        guard includeVideo || includeAudio else { return nil }
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            Log.recording.error("AssetWriterPair[\(label)]: cannot open \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        // Five seconds of loss on a hard crash, in exchange for the file being
        // playable at all. See the note above.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        var videoInput: AVAssetWriterInput?
        if includeVideo {
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // This is raw capture, not a deliverable — the compositor
                    // re-encodes it. Generous, so the master isn't rendered
                    // from mush.
                    // Capped: at native 32:9 the old formula alone asked for
                    // 44 Mbit/s, which the hardware encoder will do but which
                    // buys nothing on a file that exists to be re-encoded.
                    AVVideoAverageBitRateKey: min(width * height * 6, 40_000_000),
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                Log.recording.error("AssetWriterPair[\(label)]: writer rejected the video input")
                return nil
            }
            writer.add(input)
            videoInput = input
        }

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                // Losing audio is survivable; losing the take is not.
                Log.recording.error("AssetWriterPair[\(label)]: writer rejected the audio input — continuing video-only")
            }
        }

        guard writer.startWriting() else {
            Log.recording.error("AssetWriterPair[\(label)]: startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
            return nil
        }
        return AssetWriterPair(label: label, writer: writer, videoInput: videoInput, audioInput: audioInput)
    }

    // MARK: - Session control

    /// Hands this writer the shared clock. `primary` marks the writer whose
    /// first sample is allowed to open it.
    func useSessionStart(_ shared: SharedSessionStart, primary: Bool) {
        lock.withLock {
            sessionStart = shared
            isPrimary = primary
        }
    }

    func beginSession(at time: CMTime) {
        lock.withLock {
            guard !sessionStarted else { return }
            writer.startSession(atSourceTime: time)
            startTime = time
            sessionStarted = true
        }
    }

    func pause(at time: CMTime) {
        lock.withLock {
            guard pausedAt == nil else { return }
            pausedAt = time
        }
    }

    func resume(at time: CMTime) {
        lock.withLock {
            guard let pausedAt else { return }
            pauseOffset = CMTimeAdd(pauseOffset, CMTimeSubtract(time, pausedAt))
            self.pausedAt = nil
        }
    }

    // MARK: - Feeding

    /// Safe to call from any queue, and safe to call before the session opens
    /// or while paused — it drops.
    func append(_ sample: CMSampleBuffer, isVideo: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var failureToLog: String?
        let snapshot: (start: CMTime, offset: CMTime)? = lock.withLock {
            guard !finished, pausedAt == nil else { return nil }
            guard writer.status != .failed else {
                if !loggedFailure {
                    loggedFailure = true
                    failureToLog = writer.error?.localizedDescription ?? "unknown"
                }
                return nil
            }

            // Open the session lazily, from inside the sample callback, so the
            // frame that opens it is also the frame that gets written. The
            // primary (screen, video only) claims t=0; everyone else waits for
            // it and then starts at the same instant.
            if !sessionStarted {
                guard let shared = sessionStart else { return nil }
                if isPrimary && isVideo {
                    let start = shared.open(at: pts)
                    writer.startSession(atSourceTime: start)
                    startTime = start
                    sessionStarted = true
                } else if let start = shared.value {
                    writer.startSession(atSourceTime: start)
                    startTime = start
                    sessionStarted = true
                } else {
                    return nil
                }
            }
            guard let startTime else { return nil }
            return (startTime, pauseOffset)
        }
        if let failureToLog {
            Log.recording.error("AssetWriterPair[\(label)]: writer failed — \(failureToLog)")
        }
        guard let snapshot else { return }
        guard CMTimeCompare(pts, snapshot.start) >= 0 else { return }

        guard let input = isVideo ? videoInput : audioInput, input.isReadyForMoreMediaData else { return }

        let toAppend: CMSampleBuffer
        if CMTimeCompare(snapshot.offset, .zero) == 0 {
            toAppend = sample
        } else if let shifted = Self.retimed(sample, subtracting: snapshot.offset) {
            toAppend = shifted
        } else {
            return
        }

        if input.append(toAppend) {
            lock.withLock {
                if isVideo { sawVideo = true } else { sawAudio = true }
            }
        }
    }

    // MARK: - Teardown

    /// Finalizes the container. Must be awaited before the file is read — an
    /// unfinished writer leaves the tail fragment unflushed.
    func finish() async {
        let shouldFinish: Bool = lock.withLock {
            guard !finished, sessionStarted else {
                finished = true
                return false
            }
            finished = true
            return true
        }
        guard shouldFinish else {
            // Nothing was ever written; cancel so no zero-byte file is left.
            writer.cancelWriting()
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            Log.recording.error("AssetWriterPair[\(label)]: finishWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Synchronous best-effort teardown for the app-quit path. The fragments
    /// already on disk keep the file playable even though the moov atom never
    /// lands, so this deliberately does not block on `finishWriting()`.
    func abort() {
        let alreadyDone: Bool = lock.withLock {
            defer { finished = true }
            return finished
        }
        guard !alreadyDone else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
    }

    // MARK: - Retiming

    /// Shifts every timing entry back by `offset`.
    ///
    /// Per-entry rather than handing `CMSampleBufferCreateCopyWithNewTiming` a
    /// single entry: an audio buffer carries many samples, and collapsing them
    /// onto one timing entry silently resamples the track.
    private static func retimed(_ sample: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: Int(count)
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil
        ) == noErr else { return nil }

        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }

        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &out
        ) == noErr else { return nil }
        return out
    }
}
