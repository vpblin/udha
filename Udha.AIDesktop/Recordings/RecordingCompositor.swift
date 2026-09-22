import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

/// Renders the two raw capture files into one deliverable master, with the
/// camera composited in and captions burned into the frames.
///
/// **Why a hand-driven render loop** rather than `AVMutableVideoComposition`
/// with layer instructions: the screen track has deliberately irregular
/// timing. ScreenCaptureKit only emits a frame when the screen actually
/// changes, so a minute of someone reading a static page contains almost no
/// frames. A fixed-rate output timeline with explicit hold-last-frame
/// semantics handles that exactly; a compositor fed by track timing produces
/// stutter around the gaps. The loop also makes the circular camera mask and
/// the per-word caption highlight straightforward, neither of which layer
/// instructions can express.
///
/// Renders are run one orientation at a time. Both masters come from the same
/// raw files, so a re-render with different layout never needs a re-record.
///
/// Deliberately a class rather than an actor. Everything stateful here lives
/// for exactly one render and is touched from exactly one dispatch queue;
/// `CIContext` is documented thread-safe. Making it an actor bought no safety
/// and meant every AVFoundation callback — which arrive on their own queues —
/// was reaching across an isolation boundary for no reason.
final class RecordingCompositor: @unchecked Sendable {

    struct Progress: Sendable {
        var orientation: RecordingOrientation
        var fraction: Double
    }

    enum CompositeError: LocalizedError {
        case noScreenVideo
        case writerFailed(String)
        case readerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noScreenVideo: return "This recording has no screen video to render."
            case .writerFailed(let why): return "Rendering failed: \(why)"
            case .readerFailed(let why): return "Could not read the raw recording: \(why)"
            }
        }
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders one master. `onProgress` is called on the actor, roughly once a
    /// second of output.
    func render(
        screenURL: URL,
        cameraURL: URL,
        captions: CaptionTrack?,
        orientation: RecordingOrientation,
        outputURL: URL,
        config: RecordingsConfig,
        screenCrop: CGPoint = CGPoint(x: 0.5, y: 0.5),
        screenCropScale: CGFloat = 1,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // A camera-only take has no screen file at all. Everything the render
        // is clocked by — duration, frame count, the layout's source size —
        // then comes from the camera instead, which is the only reason this
        // reads as two cases rather than one.
        let screenAsset: AVURLAsset? = FileManager.default.fileExists(atPath: screenURL.path)
            ? AVURLAsset(url: screenURL) : nil
        let screenTrack = try await screenAsset?.loadTracks(withMediaType: .video).first

        let hasCameraFile = FileManager.default.fileExists(atPath: cameraURL.path)
        let cameraAsset = hasCameraFile ? AVURLAsset(url: cameraURL) : nil
        let cameraTrack = try await cameraAsset?.loadTracks(withMediaType: .video).first
        let cameraSize = try await cameraTrack?.load(.naturalSize)

        let clockAsset = screenAsset ?? cameraAsset
        guard let clockAsset, screenTrack != nil || cameraTrack != nil else {
            throw CompositeError.noScreenVideo
        }
        let screenSize = try await screenTrack?.load(.naturalSize) ?? cameraSize ?? .zero
        let totalDuration = try await clockAsset.load(.duration)
        guard totalDuration.seconds > 0 else { throw CompositeError.noScreenVideo }

        let layout = CompositorLayout.make(
            for: orientation,
            screenPixelSize: screenSize,
            hasCamera: cameraTrack != nil,
            hasScreen: screenTrack != nil,
            config: config
        )

        // MARK: Readers

        var screenSource: FrameSource?
        if let screenAsset, let screenTrack {
            screenSource = try FrameSource(asset: screenAsset, track: screenTrack)
        }
        var cameraSource: FrameSource?
        if let cameraAsset, let cameraTrack {
            cameraSource = try? FrameSource(asset: cameraAsset, track: cameraTrack)
        }

        // MARK: Writer

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw CompositeError.writerFailed(error.localizedDescription)
        }

        let (outW, outH) = orientation.renderSize
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                // Quality-based, not a bitrate target. Screen text is the
                // hardest thing a codec here has to carry, and the answer used
                // to be brute force: H.264 at ~12 Mbit/s. But an average-bitrate
                // encoder spends its whole budget even on frames where nothing
                // moved — most frames, for screen content — so a six-minute call
                // landed at 579 MB and blew past Cloudflare's upload ceiling.
                // HEVC at quality 0.75 measures SSIM 0.994 against that H.264
                // master, i.e. no visible difference including on text, for
                // ~5 Mbit/s. Being quality-based it now costs almost nothing
                // while the screen is still and spends where the camera moves.
                // Cloudflare Stream ingests HEVC and transcodes it normally —
                // worth stating because their docs only ever name H.264; this
                // was verified against the live account before switching.
                AVVideoQualityKey: 0.75,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw CompositeError.writerFailed("video input rejected") }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
            ]
        )

        // Audio is mixed from both raw files. Either may be missing.
        let audioMix = try await Self.audioComposition(screenURL: screenURL, cameraURL: cameraURL)
        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        if let audioMix {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                let reader = try AVAssetReader(asset: audioMix)
                let output = AVAssetReaderAudioMixOutput(
                    audioTracks: audioMix.tracks(withMediaType: .audio),
                    audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                )
                if reader.canAdd(output) {
                    reader.add(output)
                    reader.startReading()
                    audioReader = reader
                    audioOutput = output
                }
            }
        }

        guard writer.startWriting() else {
            throw CompositeError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Render

        let frameRate = max(1, config.frameRate)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let totalFrames = Int((totalDuration.seconds * Double(frameRate)).rounded(.down))
        let renderer = CaptionRenderer(fontSize: layout.captionFontSize, maxWidth: layout.captionMaxWidth)
        // A camera takes a moment to wake, and a Continuity Camera emits real,
        // fully black frames while it does. Since the session now opens on the
        // screen's first frame rather than waiting for the camera, those black
        // frames land at t=0 — which is exactly the frame used as the video's
        // poster. Suppress the bubble until the camera produces something, then
        // stop checking so a genuinely dark shot later still draws.
        let cameraWake = CameraWakeState()
        // Only when the panel actually has rounded corners — a mask over a
        // plain rectangle is a full-frame blend that buys nothing.
        let cameraMask: CIImage? = layout.cameraCornerRadius > 0
            ? layout.cameraRect.flatMap { Self.roundedMask(size: $0.size, cornerRadius: layout.cameraCornerRadius) }
            : nil ?? nil
        let burnCaptions = config.burnCaptions

        var lastReportedSecond = -1

        // Both inputs must be pumped CONCURRENTLY.
        //
        // AVAssetWriter interleaves its inputs as it writes, and to keep that
        // interleaving window bounded it stops reporting
        // `isReadyForMoreMediaData` on whichever input has run ahead of the
        // others. Draining video to completion first and only then starting
        // audio therefore deadlocks: video gets a little way in, the writer
        // holds it back waiting for audio that nothing is producing yet, and
        // the callback simply stops being invoked. It doesn't crash or error —
        // the render just stops, forever, with a zero-byte file on disk.
        let videoQueue = DispatchQueue(label: "udha.recording.compositor.video")
        let audioQueue = DispatchQueue(label: "udha.recording.compositor.audio")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()

            group.enter()
            var videoFinished = false
            var frameIndex = 0
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    guard frameIndex < totalFrames else {
                        if !videoFinished {
                            videoFinished = true
                            videoInput.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                    let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                    let seconds = time.seconds

                    let screenFrame = screenSource?.frame(at: time)
                    let cameraFrame = cameraSource?.frame(at: time)

                    guard let pool = adaptor.pixelBufferPool,
                          let buffer = Self.newBuffer(from: pool) else {
                        frameIndex += 1
                        continue
                    }

                    var usableCamera = cameraFrame
                    // The wake check exists to hide a webcam's black warm-up
                    // frames behind the screen. With no screen behind it there
                    // is nothing to fall back to, so dropping them would render
                    // an empty frame instead of a dark one.
                    if let frame = cameraFrame, !cameraWake.isAwake, screenSource != nil {
                        if Self.isEssentiallyBlack(frame) {
                            usableCamera = nil
                        } else {
                            cameraWake.markAwake()
                        }
                    }

                    let composited = self.composite(
                        screen: screenFrame,
                        camera: usableCamera,
                        cameraMask: cameraMask,
                        layout: layout,
                        captions: burnCaptions ? captions : nil,
                        renderer: renderer,
                        screenCrop: screenCrop,
                        screenCropScale: screenCropScale,
                        at: seconds
                    )
                    self.ciContext.render(
                        composited, to: buffer,
                        bounds: CGRect(origin: .zero, size: layout.outputSize),
                        colorSpace: CGColorSpaceCreateDeviceRGB()
                    )
                    adaptor.append(buffer, withPresentationTime: time)

                    let second = Int(seconds)
                    if second != lastReportedSecond {
                        lastReportedSecond = second
                        onProgress?(Double(frameIndex) / Double(max(1, totalFrames)))
                    }
                    frameIndex += 1
                }
            }

            if let audioInput, let audioOutput, let audioReader {
                group.enter()
                var audioFinished = false
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard audioReader.status == .reading,
                              let sample = audioOutput.copyNextSampleBuffer() else {
                            if !audioFinished {
                                audioFinished = true
                                audioInput.markAsFinished()
                                group.leave()
                            }
                            return
                        }
                        audioInput.append(sample)
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                cont.resume()
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw CompositeError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        Log.recording.info("RecordingCompositor: rendered \(orientation.rawValue) (\(outW)x\(outH), \(totalFrames) frames)")
    }

    // MARK: - Frame composition

    private func composite(
        screen: CVPixelBuffer?,
        camera: CVPixelBuffer?,
        cameraMask: CIImage?,
        layout: CompositorLayout,
        captions: CaptionTrack?,
        renderer: CaptionRenderer,
        screenCrop: CGPoint,
        screenCropScale: CGFloat,
        at seconds: TimeInterval
    ) -> CIImage {
        let frame = CGRect(origin: .zero, size: layout.outputSize)
        // Ink, matching the app's palette — letterboxing should read as a
        // deliberate mat, not as a rendering failure.
        var output = CIImage(color: CIColor(red: 0.125, green: 0.118, blue: 0.114))
            .cropped(to: frame)

        if let screen {
            // Filled and cropped, not fitted. Cropping before compositing
            // matters for the same reason it does for the camera: the overflow
            // from an aspect-fill would otherwise spill across the frame and
            // paint over the camera panel next door.
            var image = Self.place(
                CIImage(cvPixelBuffer: screen), into: layout.screenRect, mode: .fill,
                anchor: screenCrop, zoom: screenCropScale
            )
            image = image.cropped(to: layout.screenRect)
            output = image.composited(over: output)
        }

        if let camera, let cameraRect = layout.cameraRect {
            var image = Self.place(CIImage(cvPixelBuffer: camera), into: cameraRect, mode: .fill)
            // Crop the aspect-fill overflow away before masking, or the mask
            // lands on a larger image than the slot it is meant to shape.
            image = image.cropped(to: cameraRect)
            if let cameraMask {
                let positionedMask = cameraMask.transformed(
                    by: CGAffineTransform(translationX: cameraRect.minX, y: cameraRect.minY)
                )
                image = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: positionedMask,
                ])
            }
            output = image.composited(over: output)
        }

        if let captions, let cue = captions.cue(at: seconds) {
            let activeWord = cue.words.firstIndex { seconds >= $0.start && seconds < $0.end }
            if let cgImage = renderer.image(for: cue, activeWordIndex: activeWord) {
                let w = CGFloat(cgImage.width)
                let h = CGFloat(cgImage.height)
                let rect = CGRect(
                    x: layout.captionCenterX - w / 2,
                    y: layout.captionBottomInset,
                    width: w, height: h
                )
                let image = CIImage(cgImage: cgImage)
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                output = image.composited(over: output)
            }
        }
        return output.cropped(to: frame)
    }

    private enum PlaceMode { case fit, fill }

    /// Scales `image` into `rect` and translates it there.
    /// `anchor` picks which part of the source ends up in `rect` when the image
    /// overflows it — (0.5, 0.5) is the centred crop, and anything else slides
    /// the kept region without changing its size. Only meaningful for `.fill`;
    /// a fitted image has no overflow to choose from.
    private static func place(
        _ image: CIImage, into rect: CGRect, mode: PlaceMode,
        anchor: CGPoint = CGPoint(x: 0.5, y: 0.5), zoom: CGFloat = 1
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        var target = mode == .fit
            ? CompositorLayout.aspectFit(extent.size, into: rect)
            : CompositorLayout.aspectFill(extent.size, into: rect)
        if mode == .fill {
            // Keeping a *smaller* region of the source means drawing the source
            // *larger*: the guides' scale and the image's zoom are reciprocal.
            let k = min(1, max(CompositorLayout.minimumCropScale, zoom))
            target.size = CGSize(width: target.width / k, height: target.height / k)
            // Put the anchor point of the scaled image over the middle of the
            // box, then let the clamp below pull it back if that would expose
            // an edge.
            let x = rect.midX - CGFloat(anchor.x) * target.width
            let y = rect.midY - CGFloat(anchor.y) * target.height
            target.origin = CGPoint(
                x: min(rect.minX, max(rect.maxX - target.width, x)),
                y: min(rect.minY, max(rect.maxY - target.height, y))
            )
        }
        let scaleX = target.width / extent.width
        let scaleY = target.height / extent.height
        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: target.minX - extent.minX * scaleX,
                y: target.minY - extent.minY * scaleY
            ))
    }

    /// Opaque white rounded rect on a **transparent** ground, used as the
    /// camera's alpha mask. A corner radius of half the short edge gives the
    /// circular bubble.
    ///
    /// The transparency is the whole point, and getting it wrong is silent:
    /// `CIBlendWithAlphaMask` samples the mask's **alpha** channel, not its
    /// luminance. An earlier version drew white-on-black in a grayscale context
    /// with `CGImageAlphaInfo.none`, which has no alpha channel at all — so
    /// every pixel read as fully opaque, the mask did nothing, and the bubble
    /// rendered as a hard rectangle with no error anywhere.
    private static func roundedMask(size: CGSize, cornerRadius: CGFloat) -> CIImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.clear(bounds)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Cheap black test: samples a sparse grid rather than every pixel, and the
    /// threshold is low enough that a dim room still counts as awake.
    private static func isEssentiallyBlack(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 8, height > 8 else { return false }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var samples = 0
        for row in Swift.stride(from: height / 8, to: height, by: Swift.max(1, height / 8)) {
            for column in Swift.stride(from: width / 8, to: width, by: Swift.max(1, width / 8)) {
                let offset = row * stride + column * 4  // BGRA
                let b = Int(pointer[offset]), g = Int(pointer[offset + 1]), r = Int(pointer[offset + 2])
                total += (r + g + b) / 3
                samples += 1
            }
        }
        guard samples > 0 else { return false }
        return (total / samples) <= 3
    }

    private static func newBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    /// Both raw files' audio tracks laid over one another. They share a
    /// timeline, so no offset is needed.
    private static func audioComposition(screenURL: URL, cameraURL: URL) async throws -> AVMutableComposition? {
        let composition = AVMutableComposition()
        var inserted = 0
        for url in [cameraURL, screenURL] where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0,
                  let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            inserted += 1
        }
        return inserted > 0 ? composition : nil
    }
}

/// One flag, shared between the render loop and nothing else. A tiny class
/// rather than a captured `var` so it is not copied into the escaping
/// media-request closure, and per-render rather than a compositor field so one
/// render's state cannot leak into the next.
private final class CameraWakeState {
    private(set) var isAwake = false
    func markAwake() { isAwake = true }
}

// MARK: - Frame source

/// Pulls frames from one video track and answers "what should be on screen at
/// time t", holding the last frame until a newer one is due.
///
/// The hold is the important part. ScreenCaptureKit emits nothing while the
/// screen is unchanged, so a screen track legitimately contains long gaps —
/// treating a gap as "no image" would flash the background mat every time the
/// user stopped moving.
private final class FrameSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private var current: CVPixelBuffer?
    private var finished = false

    init(asset: AVAsset, track: AVAssetTrack) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw RecordingCompositor.CompositeError.readerFailed("track output rejected")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw RecordingCompositor.CompositeError.readerFailed(
                reader.error?.localizedDescription ?? "startReading failed"
            )
        }
    }

    func frame(at time: CMTime) -> CVPixelBuffer? {
        while !finished {
            if pending == nil {
                pending = output.copyNextSampleBuffer()
                if pending == nil { finished = true; break }
            }
            guard let next = pending else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(next)
            // Not due yet — keep showing what's already up.
            if CMTimeCompare(pts, time) > 0 { break }
            if let image = CMSampleBufferGetImageBuffer(next) {
                current = image
            }
            pending = nil
        }
        return current
    }
}
