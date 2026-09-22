import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Concatenates finished recordings into one file.
///
/// **Why this works on the rendered masters and not the raw capture files.**
/// By the time a recording is `.ready`, the camera has been composited in, the
/// crop has been applied and the captions are burned into the frames. All of
/// that is per-recording work that a join has no reason to redo — and redoing
/// it would mean a second transcription, since the caption track is what the
/// compositor draws from. Concatenating the masters instead makes a join one
/// export, and the caption *tracks* are merged by arithmetic rather than by
/// asking ElevenLabs the same question twice.
///
/// The sources are read and never written, which is what lets the recording
/// store keep them: undoing a join is a delete, not a restore.
///
/// A class rather than an actor, for the same reason as `RecordingCompositor`:
/// everything here lives for exactly one join and AVFoundation's callbacks
/// arrive on their own queues anyway.
final class RecordingJoiner: @unchecked Sendable {

    /// One source master, plus the title used in error messages — a failure
    /// should name the video that caused it, not a path under Application
    /// Support.
    struct Clip: Sendable {
        let title: String
        let url: URL
    }

    enum JoinError: LocalizedError {
        case notEnoughClips
        case missingMaster(String)
        case unreadable(String)
        case compositionFailed
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .notEnoughClips:
                return "A join needs at least two videos."
            case .missingMaster(let title):
                return "“\(title)” has no rendered master to join — render it first."
            case .unreadable(let title):
                return "“\(title)” could not be read. Its master may be damaged; re-render it and try again."
            case .compositionFailed:
                return "Could not build the joined timeline."
            case .exportFailed(let why):
                return "Joining failed: \(why)"
            }
        }
    }

    // MARK: - Join

    /// Writes `clips`, in order, end to end into `outputURL`.
    ///
    /// `onProgress` is called with 0…1 a couple of times a second.
    func join(
        clips: [Clip],
        orientation: RecordingOrientation,
        outputURL: URL,
        frameRate: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard clips.count >= 2 else { throw JoinError.notEnoughClips }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw JoinError.compositionFailed }

        let (targetW, targetH) = orientation.renderSize
        let target = CGSize(width: CGFloat(targetW), height: CGFloat(targetH))

        var cursor = CMTime.zero
        var segments: [(range: CMTimeRange, transform: CGAffineTransform)] = []
        var sourceSizes: [CGSize] = []
        var anyAudio = false

        for clip in clips {
            guard FileManager.default.fileExists(atPath: clip.url.path) else {
                throw JoinError.missingMaster(clip.title)
            }
            let asset = AVURLAsset(url: clip.url)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  duration.seconds > 0
            else { throw JoinError.unreadable(clip.title) }

            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            } catch {
                throw JoinError.unreadable(clip.title)
            }

            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               (try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)) != nil {
                anyAudio = true
            } else {
                // A silent clip still has to occupy its slice of the audio
                // timeline. Skipping it would slide every later clip's sound
                // forward by this clip's length — the picture would be right
                // and the voice would be minutes early.
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
            }

            let natural = (try? await sourceVideo.load(.naturalSize)) ?? target
            let preferred = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            sourceSizes.append(Self.orientedSize(natural: natural, preferred: preferred))
            segments.append((
                range: CMTimeRange(start: cursor, duration: duration),
                transform: Self.fitTransform(natural: natural, preferred: preferred, into: target)
            ))
            cursor = cursor + duration
        }

        if !anyAudio { composition.removeTrack(audioTrack) }
        try? FileManager.default.removeItem(at: outputURL)

        // Every Udha master of a given orientation is rendered at exactly the
        // orientation's size, so in the ordinary case nothing needs scaling and
        // the encoded frames can be copied straight across. That turns a join
        // of two four-minute videos from a minute of transcoding into a couple
        // of seconds. The re-encode below is the fallback for a master that
        // came out of an older build at some other size.
        if sourceSizes.allSatisfy({ $0 == target }) {
            do {
                try await export(composition, videoComposition: nil,
                                 preset: AVAssetExportPresetPassthrough,
                                 to: outputURL, onProgress: onProgress)
                return
            } catch {
                Log.recording.error("RecordingJoiner: passthrough failed (\(error.localizedDescription)) — re-encoding")
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = target
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        videoComposition.instructions = segments.map { segment in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = segment.range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(segment.transform, at: segment.range.start)
            instruction.layerInstructions = [layer]
            return instruction
        }

        // HEVC to match the compositor. The plain `HighestQuality` preset
        // encodes H.264, so a join that had to rescale would have quietly
        // handed back a master several times the size of the ones it was
        // built from — the passthrough case above keeps whatever the
        // compositor wrote, and this path has to agree with it.
        try await export(composition, videoComposition: videoComposition,
                         preset: AVAssetExportPresetHEVCHighestQuality,
                         to: outputURL, onProgress: onProgress)
    }

    private func export(
        _ asset: AVAsset,
        videoComposition: AVMutableVideoComposition?,
        preset: String,
        to outputURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw JoinError.exportFailed("no exporter available for \(preset)")
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        // Unstructured rather than a task group: the state sequence and the
        // export are not peers — one is the work, the other is commentary on
        // it, and the commentary is cancelled the moment the work returns.
        let watcher = Task {
            for await state in session.states(updateInterval: 0.4) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }

        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            throw JoinError.exportFailed(error.localizedDescription)
        }
        onProgress(1)
    }

    // MARK: - Geometry

    /// What a track actually looks like once its `preferredTransform` is
    /// applied — a 90°-rotated portrait clip reports a landscape `naturalSize`.
    static func orientedSize(natural: CGSize, preferred: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Aspect-fits a source into the output frame and centres it. Letterboxes
    /// rather than crops: a joined video is a sequence of takes the user
    /// already framed, and silently cutting the edges off one of them would
    /// undo that framing.
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, into target: CGSize) -> CGAffineTransform {
        let oriented = orientedSize(natural: natural, preferred: preferred)
        guard oriented.width > 0, oriented.height > 0 else { return preferred }
        let scale = min(target.width / oriented.width, target.height / oriented.height)
        let dx = (target.width - oriented.width * scale) / 2
        let dy = (target.height - oriented.height * scale) / 2
        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    // MARK: - Timeline

    /// How long each master actually is, in order.
    ///
    /// Not `Recording.durationSeconds`: that is capture time with pauses
    /// excised, which is close to the rendered length but not equal to it. The
    /// caption offsets have to agree with the file the player scrubs, so they
    /// are measured from the file. An unreadable master contributes 0 rather
    /// than throwing — by the time this runs the join has already succeeded,
    /// and losing the caption track would be a worse outcome than one clip's
    /// captions landing early.
    static func durations(of urls: [URL]) async -> [TimeInterval] {
        var lengths: [TimeInterval] = []
        for url in urls {
            let duration = try? await AVURLAsset(url: url).load(.duration)
            lengths.append(max(0, duration?.seconds ?? 0))
        }
        return lengths
    }

    /// Running start time of each clip in the joined timeline.
    static func offsets(from durations: [TimeInterval]) -> [TimeInterval] {
        var cursor: TimeInterval = 0
        return durations.map { length in
            defer { cursor += length }
            return cursor
        }
    }

    /// Lays the sources' caption tracks end to end, each shifted by where its
    /// picture starts in the joined video.
    ///
    /// This is the whole reason a join does not re-transcribe: the words and
    /// their word-level timings already exist, and moving them is addition.
    static func mergeCaptions(_ tracks: [CaptionTrack?], offsets: [TimeInterval]) -> CaptionTrack {
        var merged = CaptionTrack()
        merged.languageCode = tracks.compactMap { $0 }.first?.languageCode ?? "en"
        for (index, track) in tracks.enumerated() {
            guard let track else { continue }
            let offset = index < offsets.count ? offsets[index] : 0
            for cue in track.cues {
                var words: [CaptionWord] = []
                words.reserveCapacity(cue.words.count)
                for word in cue.words {
                    let start: TimeInterval = word.start + offset
                    let end: TimeInterval = word.end + offset
                    words.append(CaptionWord(text: word.text, start: start, end: end))
                }
                let start: TimeInterval = cue.start + offset
                let end: TimeInterval = cue.end + offset
                merged.cues.append(CaptionCue(start: start, end: end, words: words))
            }
        }
        merged.cues.sort { $0.start < $1.start }
        return merged
    }

    // MARK: - Estimate

    /// What the sheet promises before you commit. Deliberately rough and shown
    /// with a "~": the passthrough path is seconds regardless of length, and
    /// the re-encode path runs at several times real time on Apple silicon.
    static func renderEstimate(seconds: TimeInterval, orientations: Int) -> Int {
        max(5, Int((seconds * 0.14 * Double(max(1, orientations))).rounded()))
    }
}
