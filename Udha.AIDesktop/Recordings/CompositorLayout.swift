import Foundation
import CoreGraphics

/// Where every element lands in one output frame.
///
/// Split out from the compositor so the geometry is testable on its own and so
/// the two orientations differ in *data* rather than in branching render code.
///
/// All rects are in Core Image's coordinate space — origin bottom-left, y up —
/// because that is what the render pass works in. Getting this backwards puts
/// the camera bubble in the wrong corner and the captions off the top of the
/// frame, which is exactly the kind of bug that only shows up in the output
/// file.
struct CompositorLayout {
    var outputSize: CGSize
    /// The box the screen recording fills. Empty for a camera-only take, where
    /// there is no screen and the camera has the whole frame. Aspect-**fill**, not fit: the
    /// screen is cropped to this shape rather than floated inside it with mats
    /// around it, so the frame carries picture edge to edge. What that costs is
    /// real — on a 32:9 display most of the width falls outside — which is why
    /// the same rectangle is drawn on the desktop while you record.
    var screenRect: CGRect
    /// Aspect-fill box for the camera. `nil` when there is no camera track.
    var cameraRect: CGRect?
    /// Corner radius applied to the camera panel. Zero for the band layouts —
    /// kept so a rounded variant needs no change here.
    var cameraCornerRadius: CGFloat
    /// Horizontal room captions may occupy.
    var captionMaxWidth: CGFloat
    /// Where the caption block is centred horizontally. Not always the middle
    /// of the frame: in landscape the left third is the camera panel, and a
    /// frame-centred caption would sit half across the presenter's face.
    var captionCenterX: CGFloat
    /// Bottom edge of the caption block, measured up from the frame bottom.
    var captionBottomInset: CGFloat
    /// Cap height for caption glyphs.
    var captionFontSize: CGFloat

    static func make(
        for orientation: RecordingOrientation,
        screenPixelSize: CGSize,
        hasCamera: Bool,
        hasScreen: Bool = true,
        config: RecordingsConfig
    ) -> CompositorLayout {
        let (w, h) = orientation.renderSize
        let output = CGSize(width: w, height: h)
        let shortEdge = min(output.width, output.height)

        // TikTok and Reels paint their own UI over roughly the bottom 15% and
        // the right edge. Captions sit above that band — centred low, but never
        // flush with the bottom, or half of them are hidden behind a caption
        // field and a row of action buttons.
        let captionBottomInset = output.height * config.captionSafeAreaFraction
        let captionFontSize = shortEdge * 0.055

        // The camera takes a full band of the frame — the left third in
        // landscape, the top third in portrait — rather than floating over the
        // screen as a Loom-style bubble. Two consequences worth stating: the
        // screen is fitted into the *remaining* two thirds (never behind the
        // camera, so nothing is ever obscured), and the camera is aspect-filled
        // into a band far narrower than 16:9, which crops hard to the centre.
        let band = max(0.05, min(0.6, config.cameraBandFraction))

        // Camera only: the presenter has the frame. Filled, so a 16:9 camera
        // crops to the middle of itself for the vertical master rather than
        // sitting in two bars of mat — the same trade the screen makes.
        if !hasScreen {
            return CompositorLayout(
                outputSize: output,
                screenRect: .zero,
                cameraRect: hasCamera ? CGRect(origin: .zero, size: output) : nil,
                cameraCornerRadius: 0,
                captionMaxWidth: output.width * 0.86,
                captionCenterX: output.width / 2,
                captionBottomInset: captionBottomInset,
                captionFontSize: captionFontSize
            )
        }

        guard hasCamera else {
            // No camera: the screen simply gets the whole frame.
            return CompositorLayout(
                outputSize: output,
                screenRect: CGRect(origin: .zero, size: output),
                cameraRect: nil,
                cameraCornerRadius: 0,
                captionMaxWidth: output.width * 0.86,
                captionCenterX: output.width / 2,
                captionBottomInset: captionBottomInset,
                captionFontSize: captionFontSize
            )
        }

        switch orientation {
        case .landscape:
            let cameraWidth = (output.width * band).rounded()
            let cameraRect = CGRect(x: 0, y: 0, width: cameraWidth, height: output.height)
            let screenBox = CGRect(
                x: cameraWidth, y: 0,
                width: output.width - cameraWidth, height: output.height
            )
            return CompositorLayout(
                outputSize: output,
                screenRect: screenBox,
                cameraRect: cameraRect,
                // Square corners: this is a panel in a two-column frame, not a
                // bubble sitting on top of one.
                cameraCornerRadius: 0,
                // Centred on the *frame*, not on the screen panel. Aligning
                // them with the screen column looked correct in the layout and
                // wrong in the video: a caption sitting right of centre reads
                // as a mistake, however well it lines up with the thing above
                // it. Width is held back from the camera column so the text
                // still never runs across the presenter.
                captionMaxWidth: min(output.width * 0.86, screenBox.width * 1.05),
                captionCenterX: output.width / 2,
                captionBottomInset: captionBottomInset,
                captionFontSize: captionFontSize
            )

        case .portrait:
            let cameraHeight = (output.height * band).rounded()
            let cameraRect = CGRect(
                x: 0, y: output.height - cameraHeight,
                width: output.width, height: cameraHeight
            )
            let screenBox = CGRect(
                x: 0, y: 0,
                width: output.width, height: output.height - cameraHeight
            )
            return CompositorLayout(
                outputSize: output,
                screenRect: screenBox,
                cameraRect: cameraRect,
                cameraCornerRadius: 0,
                captionMaxWidth: output.width * 0.86,
                captionCenterX: output.width / 2,
                captionBottomInset: captionBottomInset,
                captionFontSize: captionFontSize
            )
        }
    }

    /// One crop shape, named after the master it feeds.
    struct CropGuide: Equatable {
        /// Width ÷ height of the region the screen is cropped to.
        var aspect: CGFloat
        /// What the guide is for, in the words the picker uses.
        var label: String
    }

    /// The shapes the screen gets cropped to, widest first — one per master
    /// being rendered. Drawn on the desktop as guides while recording, so the
    /// crop is something you compose for rather than discover afterwards.
    ///
    /// The screen boxes do not depend on the source at all, so any placeholder
    /// size answers the question.
    static func screenCropGuides(config: RecordingsConfig, hasCamera: Bool) -> [CropGuide] {
        var orientations: [RecordingOrientation] = []
        if config.renderLandscape { orientations.append(.landscape) }
        if config.renderPortrait { orientations.append(.portrait) }
        return orientations.map { orientation in
            let layout = make(
                for: orientation,
                screenPixelSize: CGSize(width: 1600, height: 900),
                hasCamera: hasCamera,
                config: config
            )
            let box = layout.screenRect
            return CropGuide(
                aspect: box.height > 0 ? box.width / box.height : 1,
                label: orientation == .landscape ? "WIDE 16:9" : "VERTICAL 9:16"
            )
        }
        .sorted { $0.aspect > $1.aspect }
    }

    /// The shapes the *camera* gets cropped to, widest first — one per master.
    ///
    /// Worth drawing over the self-view, because these crop harder than the
    /// screen ones and in the opposite direction: the wide master's camera
    /// column is a tall narrow slot that keeps about a third of a 16:9 frame's
    /// width, so "am I still in shot" is a real question while recording.
    static func cameraCropGuides(config: RecordingsConfig, hasScreen: Bool = true) -> [CropGuide] {
        var orientations: [RecordingOrientation] = []
        if config.renderLandscape { orientations.append(.landscape) }
        if config.renderPortrait { orientations.append(.portrait) }
        return orientations.compactMap { orientation in
            let layout = make(
                for: orientation,
                screenPixelSize: CGSize(width: 1600, height: 900),
                hasCamera: true,
                hasScreen: hasScreen,
                config: config
            )
            guard let box = layout.cameraRect, box.height > 0 else { return nil }
            return CropGuide(
                aspect: box.width / box.height,
                label: orientation == .landscape ? "WIDE 16:9" : "VERTICAL 9:16"
            )
        }
        .sorted { $0.aspect > $1.aspect }
    }

    /// The part of `rect` that survives an aspect-fill into a box of `aspect`
    /// (width ÷ height) — the region that actually reaches the master.
    ///
    /// `centre` is normalised across `rect` (0…1) and clamped so the region
    /// always stays inside: dragging the guides moves this, and a crop that
    /// wandered off the edge of the source would render as a band of mat.
    static func cropRegion(
        of rect: CGRect, aspect: CGFloat,
        centre: CGPoint = CGPoint(x: 0.5, y: 0.5), scale: CGFloat = 1
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0, aspect > 0 else { return rect }
        let current = rect.width / rect.height
        let full = current > aspect
            ? CGSize(width: rect.height * aspect, height: rect.height)
            : CGSize(width: rect.width, height: rect.width / aspect)
        let k = min(1, max(minimumCropScale, scale))
        let size = CGSize(width: full.width * k, height: full.height * k)
        let x = rect.minX + CGFloat(centre.x) * rect.width - size.width / 2
        let y = rect.minY + CGFloat(centre.y) * rect.height - size.height / 2
        return CGRect(
            x: min(max(x, rect.minX), rect.maxX - size.width),
            y: min(max(y, rect.minY), rect.maxY - size.height),
            width: size.width, height: size.height
        )
    }

    /// Floor on the crop scale. Past this the source is being blown up so far
    /// that a screen recording stops being readable — the capture is already
    /// downscaled to fit the encoder, and every further zoom spends that
    /// resolution again.
    static let minimumCropScale: CGFloat = 0.35

    /// Largest rect with `size`'s aspect ratio that fits inside `box`, centred.
    static func aspectFit(_ size: CGSize, into box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(
            x: box.midX - w / 2,
            y: box.midY - h / 2,
            width: w,
            height: h
        )
    }

    /// Smallest rect with `size`'s aspect ratio that covers `box`, centred —
    /// the camera is cropped rather than letterboxed, so the bubble is never
    /// a face floating in two bars of black.
    static func aspectFill(_ size: CGSize, into box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = max(box.width / size.width, box.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(
            x: box.midX - w / 2,
            y: box.midY - h / 2,
            width: w,
            height: h
        )
    }
}
