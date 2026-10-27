import Foundation

/// Accumulates one stream's PCM16 mono 16k audio and cuts it into AudioChunks
/// for STT. Offsets are pure sample math (drift-free within a stream): a
/// chunk's start = baseOffset + samples already emitted / 16000.
///
/// Cut policy: hard cut at `chunkSeconds`; early cut once `minChunkSeconds` is
/// buffered and the trailing ~0.7s is silent, so sentences don't straddle
/// chunk boundaries.
@MainActor
final class AudioChunker {
    private let source: TranscriptSource
    private let sampleRate = 16000
    private let chunkSamples: Int
    private let minChunkSamples: Int
    private let silenceRMSPercent: Double
    private let trailingWindowSamples = 11_200  // ~0.7s

    private var buffer = Data()
    private var baseOffset: TimeInterval = 0
    private var samplesEmitted: Int = 0
    private var peakRMSPercent: Double = 0
    /// (sampleCount, rmsPercent) per appended block, newest last — enough to
    /// evaluate the trailing silence window without rescanning the buffer.
    private var recentBlocks: [(samples: Int, rms: Double)] = []

    var onChunk: ((AudioChunk) -> Void)?

    init(source: TranscriptSource, config: MeetingsConfig) {
        self.source = source
        self.chunkSamples = max(5, config.sttChunkSeconds) * sampleRate
        self.minChunkSamples = max(2, config.sttMinChunkSeconds) * sampleRate
        self.silenceRMSPercent = config.sttSilenceRMSPercent
    }

    /// Re-anchor the stream at a meeting-relative time (start, resume, rebuild).
    func setBaseOffset(_ t: TimeInterval) {
        baseOffset = t
        samplesEmitted = 0
    }

    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        let rms = Self.rmsPercent(pcm)
        peakRMSPercent = max(peakRMSPercent, rms)
        recentBlocks.append((pcm.count / 2, rms))
        buffer.append(pcm)

        let buffered = buffer.count / 2
        if buffered >= chunkSamples {
            cut()
        } else if buffered >= minChunkSamples, trailingWindowIsSilent() {
            cut()
        }
    }

    /// Emit whatever is buffered (pause/stop/stream rebuild). Sub-second
    /// remainders are dropped — nothing intelligible fits in them.
    func flush() {
        if buffer.count / 2 >= sampleRate {
            cut()
        } else {
            samplesEmitted += buffer.count / 2
            buffer = Data()
            peakRMSPercent = 0
            recentBlocks = []
        }
    }

    private func cut() {
        let samples = buffer.count / 2
        guard samples > 0 else { return }
        let chunk = AudioChunk(
            source: source,
            startOffset: baseOffset + Double(samplesEmitted) / Double(sampleRate),
            duration: Double(samples) / Double(sampleRate),
            pcm: buffer,
            peakRMSPercent: peakRMSPercent
        )
        samplesEmitted += samples
        buffer = Data()
        peakRMSPercent = 0
        recentBlocks = []
        onChunk?(chunk)
    }

    private func trailingWindowIsSilent() -> Bool {
        var counted = 0
        var i = recentBlocks.count - 1
        while i >= 0 && counted < trailingWindowSamples {
            if recentBlocks[i].rms > silenceRMSPercent { return false }
            counted += recentBlocks[i].samples
            i -= 1
        }
        return counted >= trailingWindowSamples
    }

    /// RMS of a PCM16 LE block as % of full scale.
    static func rmsPercent(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let v = Double(s)
                sum += v * v
            }
        }
        return (sum / Double(count)).squareRoot() / 32767.0 * 100.0
    }
}
