import Foundation
@preconcurrency import AVFoundation
import os

@MainActor
final class AudioPlayer {
    static let shared = AudioPlayer()

    private var players: [AVAudioPlayer] = []
    private var queue: [Data] = []
    private var isPlayingChunk: Bool = false
    private let sampleRate: Int
    var preferredOutputDeviceUID: String?

    var onPlaybackFinished: (() -> Void)?

    init(sampleRate: Int = 16000) {
        self.sampleRate = sampleRate
    }

    func start() {}

    func stop() {
        for p in players { p.stop() }
        players.removeAll()
        queue.removeAll()
        isPlayingChunk = false
    }

    func clearQueue() {
        for p in players { p.stop() }
        players.removeAll()
        queue.removeAll()
        isPlayingChunk = false
    }

    func enqueuePCM16(_ pcm: Data) {
        queue.append(pcm)
        playNextIfIdle()
    }

    private func playNextIfIdle() {
        guard !isPlayingChunk else { return }
        guard !queue.isEmpty else {
            onPlaybackFinished?()
            return
        }
        let pcm = queue.removeFirst()
        let wav = Self.wrapAsWAV(pcm, sampleRate: sampleRate, channels: 1)

        do {
            let player = try AVAudioPlayer(data: wav)
            if let uid = preferredOutputDeviceUID, !uid.isEmpty {
                player.currentDevice = uid
            }
            player.prepareToPlay()
            players.append(player)
            isPlayingChunk = true
            player.play()
            let duration = player.duration
            Log.voice.info("audio: playing \(pcm.count)B (\(String(format: "%.2f", duration))s), queue=\(self.queue.count)")
            Task { @MainActor [weak self, weak player] in
                try? await Task.sleep(nanoseconds: UInt64((duration + 0.05) * 1_000_000_000))
                guard let self else { return }
                if let idx = self.players.firstIndex(where: { $0 === player }) {
                    self.players.remove(at: idx)
                }
                self.isPlayingChunk = false
                self.playNextIfIdle()
            }
        } catch {
            Log.voice.error("AVAudioPlayer init failed: \(error.localizedDescription)")
            isPlayingChunk = false
            playNextIfIdle()
        }
    }

    static func wrapAsWAV(_ pcm: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = pcm.count
        let fileSize = dataSize + 36

        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(fileSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(channels).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(UInt16(blockAlign).littleEndianData)
        data.append(UInt16(bitsPerSample).littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataSize).littleEndianData)
        data.append(pcm)
        return data
    }
}

fileprivate extension FixedWidthInteger {
    var littleEndianData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: MemoryLayout<Self>.size)
    }
}
