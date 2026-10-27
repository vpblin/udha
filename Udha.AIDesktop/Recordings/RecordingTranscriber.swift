import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Turns a finished recording's audio into a caption track.
///
/// Reuses `ElevenLabsSTTClient` — the same Scribe path the meeting recorder
/// uses — but deliberately **not** `AudioChunker` or `TranscriptionEngine`.
/// Those two exist to solve a live problem: audio arriving in real time that
/// has to be cut on silence boundaries and dispatched with retry while capture
/// continues. A finished file has none of those constraints, so the whole
/// queueing apparatus would be ceremony around a single request.
///
/// The one thing that *is* borrowed is chunking, for a different reason: a long
/// recording is too big for one request and too big to hold in memory as PCM.
/// Audio is streamed out of the file in ~10 minute windows, each transcribed
/// and released before the next is read, with word timings offset back onto the
/// recording's timeline.
actor RecordingTranscriber {
    private let stt: ElevenLabsSTTClient
    private let config: ConfigStore

    /// 10 minutes of PCM16 mono @16k ≈ 19 MB — comfortably inside Scribe's
    /// request limits and bounded memory regardless of recording length.
    private let chunkSeconds: Double = 600
    private let sampleRate: Double = 16_000

    init(stt: ElevenLabsSTTClient, config: ConfigStore) {
        self.stt = stt
        self.config = config
    }

    enum TranscribeError: LocalizedError {
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This recording has no audio to transcribe."
            case .unreadable(let why): return "Could not read the recording's audio: \(why)"
            }
        }
    }

    /// `screenURL` carries system audio, `cameraURL` the mic. Either may be
    /// absent. Both share one timeline (see `AssetWriterPair`), so they mix by
    /// simple overlay with no alignment.
    func transcribe(
        screenURL: URL, cameraURL: URL, languageCode: String?,
        maxWords: Int, punctuation: CaptionPunctuation = .reduced
    ) async throws -> CaptionTrack {
        let composition = AVMutableComposition()
        var inserted = 0

        for url in [cameraURL, screenURL] where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: source, at: .zero
                )
                inserted += 1
            } catch {
                Log.recording.error("RecordingTranscriber: cannot insert audio from \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard inserted > 0 else { throw TranscribeError.noAudio }

        let words = try await transcribeChunked(composition: composition, languageCode: languageCode)
        var options = CaptionBuilder.Options()
        options.maxWords = max(2, maxWords)
        options.punctuation = punctuation
        let cues = CaptionBuilder.build(from: words, options: options)

        var track = CaptionTrack()
        track.cues = cues
        track.languageCode = languageCode?.isEmpty == false ? languageCode! : "en"
        Log.recording.info("RecordingTranscriber: \(words.count) words → \(cues.count) cues")
        return track
    }

    // MARK: - Reading + dispatch

    private func transcribeChunked(composition: AVMutableComposition, languageCode: String?) async throws -> [CaptionWord] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw TranscribeError.unreadable(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let tracks = composition.tracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw TranscribeError.unreadable("reader refused the mix output") }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscribeError.unreadable(reader.error?.localizedDescription ?? "startReading failed")
        }

        let bytesPerChunk = Int(chunkSeconds * sampleRate * 2)
        var pending = Data()
        var chunkStart: TimeInterval = 0
        var all: [CaptionWord] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let data = Self.pcmData(from: sampleBuffer) {
                pending.append(data)
            }
            if pending.count >= bytesPerChunk {
                let words = try await transcribeChunk(pending, offset: chunkStart, languageCode: languageCode)
                all.append(contentsOf: words)
                chunkStart += Double(pending.count) / (sampleRate * 2)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if reader.status == .failed {
            throw TranscribeError.unreadable(reader.error?.localizedDescription ?? "read failed")
        }
        if !pending.isEmpty {
            let words = try await transcribeChunk(pending, offset: chunkStart, languageCode: languageCode)
            all.append(contentsOf: words)
        }
        return all
    }

    /// One Scribe request. Diarization is off: a screen demo is one narrator,
    /// and captions carry no speaker labels anyway — asking for it would cost
    /// latency for a field nothing reads.
    private func transcribeChunk(_ pcm: Data, offset: TimeInterval, languageCode: String?) async throws -> [CaptionWord] {
        let wav = await MainActor.run { AudioPlayer.wrapAsWAV(pcm, sampleRate: Int(sampleRate), channels: 1) }
        let result = try await stt.transcribe(wav: wav, diarize: false, languageCode: languageCode)
        guard let words = result.words else { return [] }
        return words.compactMap { word in
            // Scribe interleaves "spacing" and "audio_event" entries between
            // real words; only the words carry usable timing.
            guard word.type == nil || word.type == "word" else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start = word.start, let end = word.end else { return nil }
            return CaptionWord(text: text, start: start + offset, end: max(end, start) + offset)
        }
    }

    /// Copies a sample buffer's PCM bytes out into `Data`.
    private static func pcmData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: base
            ) == kCMBlockBufferNoErr
        }
        return ok ? data : nil
    }
}
