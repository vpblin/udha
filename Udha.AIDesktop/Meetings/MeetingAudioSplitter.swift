import Foundation
@preconcurrency import AVFoundation

/// Trims a meeting's archived audio when the meeting is split. The m4a
/// archives hold active recording time only — the writers are fed by the
/// same capture pipeline the chunkers are, and both pause together — so a
/// transcript offset is the same offset into the audio.
///
/// Best effort, like everything else on the meeting path: a failed trim is
/// logged, the original keeps its full recording, and the new meeting simply
/// reports "transcript only".
enum MeetingAudioSplitter {
    static let streams = ["mic.m4a", "system.m4a"]

    /// Returns true when at least one stream landed in `to`.
    static func split(from: URL, to: URL, at offset: TimeInterval) async -> Bool {
        let fromDir = from.appendingPathComponent("audio", isDirectory: true)
        let toDir = to.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: toDir, withIntermediateDirectories: true)
        var landed = false
        for name in streams {
            let source = fromDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let asset = AVURLAsset(url: source)
            guard let duration = try? await asset.load(.duration).seconds, duration > offset else { continue }
            let cut = CMTime(seconds: offset, preferredTimescale: 16000)
            let end = CMTime(seconds: duration, preferredTimescale: 16000)

            // Second half first: if this fails nothing has been touched.
            let tail = toDir.appendingPathComponent(name)
            if await export(asset, range: CMTimeRange(start: cut, end: end), to: tail) {
                landed = true
            } else {
                continue
            }
            // Then the head, into a temp file swapped over the original.
            let temp = fromDir.appendingPathComponent(".\(name).head.m4a")
            try? FileManager.default.removeItem(at: temp)
            if await export(asset, range: CMTimeRange(start: .zero, end: cut), to: temp) {
                do {
                    _ = try FileManager.default.replaceItemAt(source, withItemAt: temp)
                } catch {
                    Log.meeting.error("MeetingAudioSplitter: cannot replace \(name): \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: temp)
                }
            }
        }
        return landed
    }

    private static func export(_ asset: AVAsset, range: CMTimeRange, to url: URL) async -> Bool {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            Log.meeting.error("MeetingAudioSplitter: no export session for \(url.lastPathComponent)")
            return false
        }
        try? FileManager.default.removeItem(at: url)
        session.timeRange = range
        if #available(macOS 15, *) {
            do {
                try await session.export(to: url, as: .m4a)
                return true
            } catch {
                Log.meeting.error("MeetingAudioSplitter: export failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        } else {
            session.outputURL = url
            session.outputFileType = .m4a
            await session.export()
            if session.status == .completed { return true }
            Log.meeting.error("MeetingAudioSplitter: export failed for \(url.lastPathComponent): \(session.error?.localizedDescription ?? "unknown")")
            return false
        }
    }
}
