import Foundation
@preconcurrency import AVFoundation

/// Archives one stream's raw audio as AAC (~15 MB/hour at 32 kbps) so a
/// meeting can be re-transcribed later even if STT failed live. Constructed
/// only when config.meetings.keepAudioRecordings is on.
///
/// Encoding is cheap but stays off the main actor: writes run on a private
/// serial queue. `close()` must be called to finalize the m4a's moov atom —
/// an unclosed file is unplayable.
final class MeetingAudioWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "udha.meeting.audiowriter")
    private let inputFormat: AVAudioFormat
    private var file: AVAudioFile?

    init?(url: URL) {
        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            self.file = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: .pcmFormatInt16, interleaved: true
            )
        } catch {
            Log.meeting.error("MeetingAudioWriter: cannot open \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// `pcm` is PCM16 LE mono @16k (the pipeline's wire format).
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            let frames = AVAudioFrameCount(pcm.count / 2)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                    memcpy(dst, base, pcm.count)
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                Log.meeting.error("MeetingAudioWriter: write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Releases the AVAudioFile (finalizing the container). Blocks until all
    /// queued writes are flushed — safe to call from the quit path.
    func close() {
        queue.sync { [weak self] in
            self?.file = nil
        }
    }
}
