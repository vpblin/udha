import SwiftUI

/// A flat, axis-less line of one measurement over time.
///
/// The design's chart: a line over a soft tinted area, no grid, no dots. It
/// scales to what it holds — an idle CPU that never leaves 3% still shows its
/// texture — with a little headroom above and below so the line never touches
/// its own frame. The line draws itself in over a second and a half the first
/// time it appears (the design's `dash` keyframe).
///
/// Colour carries the same meaning as everywhere else in the app: the accent
/// for a reading, amber when it is at a level that wants noticing, red when
/// it is at one that wants you.
struct Sparkline: View {
    var values: [Double]
    var color: Color = UdhaTheme.accent
    var lineWidth: CGFloat = 1.5
    /// Drawn under the line. Nil for a bare line.
    var fill: Color? = UdhaTheme.accentTint
    /// Drawn under the line, and on its own when there is nothing to draw.
    var baseline: Color = .clear

    @State private var drawn = false

    /// Fewer than two points is not a line; the pane shows the dashed baseline
    /// and says so in words rather than drawing a dot that reads as data.
    private var hasLine: Bool { values.count > 1 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if hasLine {
                GeometryReader { geo in
                    let points = normalized(in: geo.size)
                    if let fill {
                        Path { path in
                            guard let first = points.first, let last = points.last else { return }
                            path.move(to: CGPoint(x: first.x, y: geo.size.height))
                            path.addLine(to: first)
                            for point in points.dropFirst() { path.addLine(to: point) }
                            path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                            path.closeSubpath()
                        }
                        .fill(fill)
                    }
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .animation(.easeOut(duration: 1.5), value: drawn)
                }
            } else {
                Rectangle()
                    .fill(.clear)
                    .overlay(alignment: .bottom) {
                        Line().stroke(UdhaTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(height: 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if hasLine, baseline != .clear { Rectangle().fill(baseline).frame(height: 1) }
        }
        .onAppear { drawn = true }
    }

    /// The canvas's own mapping: 18% of the range as padding top and bottom,
    /// a flat series centred rather than smeared across the full height.
    private func normalized(in size: CGSize) -> [CGPoint] {
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        let pad = (high - low) * 0.18
        low -= pad
        high += pad
        if high - low < 1e-6 { low -= 1; high += 1 }

        let width = size.width
        let height = size.height
        return values.enumerated().map { index, value in
            let x = values.count == 1 ? width / 2 : (CGFloat(index) / CGFloat(values.count - 1)) * width
            let unit = (value - low) / (high - low)
            // A hairline centred on the frame edge is clipped in half, so keep
            // the line inside by the stroke's own width.
            let inset = lineWidth
            let y = height - inset - CGFloat(unit) * (height - inset * 2)
            return CGPoint(x: x, y: y)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
