import Foundation
@preconcurrency import AVFoundation

/// Concatenates the archived audio of several meetings into the first one's
/// — the inverse of `MeetingAudioSplitter`, for a call that was recorded in
/// pieces (stopped by mistake, restarted). The archives hold active time
/// only, so laying them end to end is the same timeline the joined
/// transcript is shifted onto.
///
/// A part that lacks one stream (a mic-only recording beside a full one)
/// contributes silence of its own length to that stream, so "Me" and "Them"
/// stay aligned across the seam. Best effort, like the splitter: nothing is
/// touched until every stream has exported to a temp file.
enum MeetingAudioJoiner {
    static let streams = MeetingAudioSplitter.streams

    /// Active recording length of a meeting folder, from its longest stream.
    /// nil when the folder has no audio.
    static func activeDuration(of folder: URL) async -> TimeInterval? {
        var longest: TimeInterval?
        for name in streams {
            let url = folder.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let d = try? await AVURLAsset(url: url).load(.duration).seconds else { continue }
            longest = max(longest ?? 0, d)
        }
        return longest
    }

    /// Joins `parts` (already in order, the first being the destination) into
    /// the first folder's streams. `lengths[i]` is the active length each part
    /// occupies on the joined timeline — the transcript offsets — so a part
    /// missing a stream is padded to exactly that. Returns true when every
    /// stream present in any part landed in the first folder.
    static func join(parts: [URL], lengths: [TimeInterval]) async -> Bool {
        guard parts.count >= 2, parts.count == lengths.count else { return false }
        let destDir = parts[0].appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var exported: [(final: URL, temp: URL)] = []
        for name in streams {
            let sources = parts.map { $0.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(name) }
            guard sources.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return false
            }
            var cursor = CMTime.zero
            for (source, length) in zip(sources, lengths) {
                let span = CMTime(seconds: length, preferredTimescale: 16000)
                if FileManager.default.fileExists(atPath: source.path),
                   let asset = Optional(AVURLAsset(url: source)),
                   let audio = try? await asset.loadTracks(withMediaType: .audio).first,
                   let duration = try? await asset.load(.duration) {
                    let take = CMTimeMinimum(duration, span)
                    do {
                        try track.insertTimeRange(CMTimeRange(start: .zero, duration: take), of: audio, at: cursor)
                    } catch {
                        Log.meeting.error("MeetingAudioJoiner: cannot append \(source.lastPathComponent): \(error.localizedDescription)")
                        cleanUp(exported)
                        return false
                    }
                    if take < span { track.insertEmptyTimeRange(CMTimeRange(start: cursor + take, duration: span - take)) }
                } else {
                    track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: span))
                }
                cursor = cursor + span
            }
            let temp = destDir.appendingPathComponent(".\(name).joined.m4a")
            guard await export(composition, to: temp) else { cleanUp(exported); return false }
            exported.append((destDir.appendingPathComponent(name), temp))
        }
        guard !exported.isEmpty else { return false }
        for (final, temp) in exported {
            do {
                if FileManager.default.fileExists(atPath: final.path) {
                    _ = try FileManager.default.replaceItemAt(final, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: final)
                }
            } catch {
                Log.meeting.error("MeetingAudioJoiner: cannot place \(final.lastPathComponent): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: temp)
                return false
            }
        }
        return true
    }

    private static func cleanUp(_ exported: [(final: URL, temp: URL)]) {
        for (_, temp) in exported { try? FileManager.default.removeItem(at: temp) }
    }

    private static func export(_ composition: AVMutableComposition, to url: URL) async -> Bool {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            Log.meeting.error("MeetingAudioJoiner: no export session for \(url.lastPathComponent)")
            return false
        }
        try? FileManager.default.removeItem(at: url)
        if #available(macOS 15, *) {
            do {
                try await session.export(to: url, as: .m4a)
                return true
            } catch {
                Log.meeting.error("MeetingAudioJoiner: export failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        } else {
            session.outputURL = url
            session.outputFileType = .m4a
            await session.export()
            if session.status == .completed { return true }
            Log.meeting.error("MeetingAudioJoiner: export failed for \(url.lastPathComponent): \(session.error?.localizedDescription ?? "unknown")")
            return false
        }
    }
}
