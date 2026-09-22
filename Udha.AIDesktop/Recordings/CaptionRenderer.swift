import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Draws one caption cue into an image the compositor can stamp onto a frame.
///
/// Cached per (cue, highlighted word), because the image only changes when the
/// spoken word advances — typically two or three times a second, against 30
/// frames. Re-rasterising CoreText every frame would dominate the render.
///
/// The styling choices here are the difference between captions that look
/// authored and captions that look auto-generated:
/// - **Heavy weight, large size.** These are read on a phone, in a feed, at
///   arm's length, often before the viewer has decided to care.
/// - **A scrim behind the text**, not just a stroke. A screen recording is
///   mostly light UI, and white-on-light is unreadable no matter how thick the
///   outline.
/// - **Two lines maximum**, balanced. `CaptionTrackVTT.wrap` does the same
///   split so the burned-in text and the sidecar VTT never disagree.
/// - **The active word highlighted**, which is the convention every social
///   caption style now shares and the reason word-level timings are kept.
final class CaptionRenderer {
    private var cache: [String: CGImage] = [:]
    private let font: NSFont
    private let fontSize: CGFloat
    private let maxWidth: CGFloat

    /// Archivo is already registered with Core Text at launch by
    /// `UdhaTheme.bootstrap()`, so captions carry the same face as the app.
    /// Falls back to the system bold if the bundled face ever fails to load.
    init(fontSize: CGFloat, maxWidth: CGFloat) {
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.font = NSFont(name: "Archivo-ExtraBold", size: fontSize)
            ?? NSFont(name: "Archivo-Bold", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    }

    /// `activeWordIndex` is the word being spoken at the current frame time,
    /// or nil to render the cue with no highlight.
    func image(for cue: CaptionCue, activeWordIndex: Int?) -> CGImage? {
        let key = "\(cue.id.uuidString)#\(activeWordIndex ?? -1)"
        if let hit = cache[key] { return hit }
        guard let rendered = render(cue: cue, activeWordIndex: activeWordIndex) else { return nil }
        // One cue's worth of variants is small, but a long recording would
        // otherwise accumulate every frame variant for the whole video.
        if cache.count > 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = rendered
        return rendered
    }

    private func render(cue: CaptionCue, activeWordIndex: Int?) -> CGImage? {
        let words = cue.words.map(\.text)
        guard !words.isEmpty else { return nil }

        let lines = Self.split(words: words, font: font, maxWidth: maxWidth)
        guard !lines.isEmpty else { return nil }

        let lineHeight = fontSize * 1.24
        let padX = fontSize * 0.5
        let padY = fontSize * 0.34

        // Measure first so the scrim is exactly as wide as the text.
        var lineWidths: [CGFloat] = []
        for line in lines {
            let text = line.map { words[$0] }.joined(separator: " ")
            lineWidths.append(Self.measure(text, font: font))
        }
        let textWidth = min(maxWidth, lineWidths.max() ?? 0)
        let width = Int((textWidth + padX * 2).rounded(.up))
        let height = Int((CGFloat(lines.count) * lineHeight + padY * 2).rounded(.up))
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Scrim: near-black at high opacity, rounded. Deliberately opaque
        // enough to work over a white IDE, not a tasteful 40% wash.
        let scrimRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let radius = fontSize * 0.28
        ctx.setFillColor(CGColor(red: 0.06, green: 0.05, blue: 0.05, alpha: 0.82))
        ctx.addPath(CGPath(roundedRect: scrimRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        let paper = CGColor(red: 0.953, green: 0.949, blue: 0.949, alpha: 1)
        // The one accent in the design system, reused so captions look like
        // they came from the same place as the app.
        let accent = CGColor(red: 0.925, green: 0.188, blue: 0.075, alpha: 1)

        var wordIndex = 0
        for (lineNo, line) in lines.enumerated() {
            let text = line.map { words[$0] }.joined(separator: " ")
            let lineWidth = Self.measure(text, font: font)
            var x = (CGFloat(width) - lineWidth) / 2
            // CoreText draws from the baseline up, and the context is y-up, so
            // line 0 sits at the TOP — hence counting down from the last line.
            let y = padY + CGFloat(lines.count - 1 - lineNo) * lineHeight + fontSize * 0.24

            for idx in line {
                let word = words[idx]
                let isActive = activeWordIndex == wordIndex
                let color = isActive ? accent : paper
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let attributed = NSAttributedString(string: word, attributes: attrs)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(ctLine, ctx)
                x += Self.measure(word, font: font) + Self.measure(" ", font: font)
                wordIndex += 1
            }
        }
        return ctx.makeImage()
    }

    /// Greedy wrap into at most two lines, then balanced — the same shape the
    /// VTT writer produces.
    private static func split(words: [String], font: NSFont, maxWidth: CGFloat) -> [[Int]] {
        guard !words.isEmpty else { return [] }
        let full = words.joined(separator: " ")
        if measure(full, font: font) <= maxWidth {
            return [Array(words.indices)]
        }
        var bestSplit = 1
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for split in 1..<words.count {
            let a = measure(words[0..<split].joined(separator: " "), font: font)
            let b = measure(words[split...].joined(separator: " "), font: font)
            let delta = abs(a - b)
            if delta < bestDelta {
                bestDelta = delta
                bestSplit = split
            }
        }
        return [Array(0..<bestSplit), Array(bestSplit..<words.count)]
    }

    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
}
