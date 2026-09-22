import SwiftUI
import AVFoundation
import AppKit

/// "Join N videos" — order, name, join.
///
/// One small sheet on purpose. Joining two takes is not editing: there is no
/// timeline, no trim handles and no transitions, because the two things you
/// actually need to decide are which one goes first and what the result is
/// called. Everything else the join already knows.
struct JoinVideosSheet: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    /// Local to the sheet: the order is committed by pressing Join, so backing
    /// out has to leave the sidebar's selection exactly as it was.
    @State private var order: [UUID] = []
    @State private var name: String = ""
    @State private var joining = false

    private var clips: [Recording] {
        order.compactMap { core.recordings.store.recording(withID: $0) }
    }

    private var totalDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.durationSeconds }
    }

    private var orientations: [RecordingOrientation] {
        core.recordings.joinableOrientations(for: clips)
    }

    /// How many caption lines carry over. Read from the sources' tracks rather
    /// than estimated — it is the number that makes "nothing is re-transcribed"
    /// a claim instead of a slogan.
    private var captionCount: Int {
        clips.reduce(0) { $0 + (core.recordings.store.loadCaptions(for: $1)?.cues.count ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            clipList
            nameField
            note
            footer
        }
        .frame(width: 452)
        .background(UdhaTheme.canvas)
        .task {
            // Seeded once. Re-seeding on every redraw would undo a swap the
            // moment anything else in the app changed.
            order = shell.joinOrder
            name = shell.joinName
        }
    }

    // MARK: - Head

    private var head: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Join \(clips.count) videos", tracking: 1.4)
            Text("One video, \(UdhaFormat.clock(totalDuration))")
                .font(UdhaTheme.text(20, .extraBold))
                .foregroundStyle(UdhaTheme.ink)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Order

    private var clipList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                clipRow(clip, index: index)
            }
            HStack(spacing: 6) {
                Spacer()
                if clips.count == 2 {
                    Button { order.reverse() } label: {
                        UdhaLabel(title: "Swap order", icon: "arrow.up.arrow.down")
                    }
                    .udhaButton(.ghost, height: 24, hPadding: 9)
                    .disabled(joining)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func clipRow(_ clip: Recording, index: Int) -> some View {
        HStack(spacing: 11) {
            Text("\(index + 1)")
                .font(UdhaTheme.mono(11, weight: .medium))
                .foregroundStyle(UdhaTheme.paper)
                .frame(width: 18, height: 18)
                .background(UdhaTheme.ink)
            ClipThumbnail(url: thumbnailURL(for: clip))
                .frame(width: 52, height: 30)
            Text(clip.title)
                .font(UdhaTheme.text(13, .semibold))
                .foregroundStyle(UdhaTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Mono(UdhaFormat.clock(clip.durationSeconds), size: 11)
            // Swap covers the two-clip case the design draws. Three or more
            // needs something that generalises, and nudging one row at a time
            // is the smallest thing that does.
            if clips.count > 2 {
                Button { move(index, by: -1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .udhaButton(.bare, height: 20, hPadding: 4)
                .disabled(joining || index == 0)
                Button { move(index, by: 1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .udhaButton(.bare, height: 20, hPadding: 4)
                .disabled(joining || index == clips.count - 1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .udhaCard(radius: 8)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    /// Whichever master this clip actually has — a wide-only take should still
    /// show a picture in the order list.
    private func thumbnailURL(for clip: Recording) -> URL? {
        guard let orientation = clip.renderedOrientations.first else { return nil }
        return core.recordings.store.masterURL(for: clip, orientation: orientation)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Name", tracking: 1.4)
            UdhaField(placeholder: RecordingCenter.defaultJoinTitle(for: clips), text: $name)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Note

    /// What the join is about to do, in the terms that matter: what carries
    /// over, what comes out, and what happens to the files you already have.
    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(carryOverNote)
                .font(UdhaTheme.text(12, .regular))
                .foregroundStyle(UdhaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if orientations.count < 2 {
                Text(orientations.isEmpty
                     ? "These videos have no rendered master in common, so there is nothing to join yet."
                     : "Only the \(orientations[0] == .landscape ? "wide" : "vertical") master will be produced — the other one isn't rendered for every clip.")
                    .font(UdhaTheme.text(12, .semibold))
                    .foregroundStyle(UdhaTheme.redInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var carryOverNote: String {
        let captions = captionCount > 0
            ? "Captions carry over — \(captionCount) lines, nothing re-transcribed. "
            : "Neither clip has captions, so the join won't have any either. "
        let masters = orientations.count == 2
            ? "Both wide and vertical masters are rendered, so your share link still adapts. "
            : ""
        return captions + masters + "Originals are kept."
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Cancel") { shell.joinSheetOpen = false }
                    .udhaButton(.bare, height: 30, hPadding: 10)
                    .disabled(joining)
                Spacer()
                Button { start() } label: {
                    UdhaLabel(title: joining ? "Joining…" : "Join videos", icon: "arrow.trianglehead.merge")
                }
                .udhaButton(.primary, height: 34, hPadding: 18)
                .disabled(joining || clips.count < 2 || orientations.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            HRule(color: UdhaTheme.ruleFaint)

            HStack {
                Mono("~\(RecordingJoiner.renderEstimate(seconds: totalDuration, orientations: orientations.count))s render",
                     size: 10, color: UdhaTheme.faint)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func start() {
        let picked = clips
        guard picked.count >= 2 else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        joining = true
        shell.joinSheetOpen = false
        shell.clearJoinSelection()
        shell.say("Joining \(picked.count) videos…")
        Task {
            let joined = await core.recordings.join(picked, title: title)
            joining = false
            guard let joined else {
                shell.say("Join failed")
                return
            }
            // Selecting it is the point: the result is a video, and the next
            // thing you want is to watch it or publish it.
            shell.select(recording: joined.id)
            shell.say(joined.stage == .failed
                      ? (joined.failureReason ?? "Join failed")
                      : "Joined · \(joined.title)")
        }
    }
}

// MARK: - Thumbnail

/// One frame from a master, so picking the order is a matter of looking rather
/// than of reading two similar filenames.
///
/// Renders as a plain black block until the frame arrives (and stays one if the
/// file can't be read) — the row's geometry must not move once the sheet is up.
struct ClipThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(UdhaTheme.ink)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        image = await Self.firstFrame(of: url)
    }

    /// A second in, not frame zero: a screen recording's first frame is often
    /// the desktop mid-redraw, and the camera may still be waking.
    private static func firstFrame(of url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let at = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: at).image else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
