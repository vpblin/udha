import SwiftUI

/// Pure layout for the swimlane diagram: columns = roles, one step per row
/// (v1 — parallel branches share no rows, so cells never collide and every
/// forward arrow points down). Deterministic for a given model.
struct ProcessDiagramLayout {
    struct EdgePath: Identifiable {
        let edge: ProcessEdge
        let path: Path
        let isBack: Bool
        let labelPoint: CGPoint
        let arrowPoint: CGPoint
        let arrowAngle: CGFloat
        var id: String { edge.id }
    }

    let laneWidth: CGFloat
    let headerHeight: CGFloat = 36
    let rowHeight: CGFloat = 78
    let nodeHeight: CGFloat = 56
    var nodeWidth: CGFloat { laneWidth - 24 }

    private(set) var laneX: [String: CGFloat] = [:]      // roleID → lane min-x
    private(set) var nodeFrames: [String: CGRect] = [:]  // stepID → frame
    private(set) var edgePaths: [EdgePath] = []
    private(set) var size: CGSize = .zero

    init(model rawModel: ProcessModel, availableWidth: CGFloat) {
        let model = rawModel.sanitized()
        let roleCount = max(1, model.roles.count)
        self.laneWidth = max(170, min(280, availableWidth / CGFloat(roleCount)))

        var laneIndex: [String: Int] = [:]
        for (i, role) in model.roles.enumerated() {
            laneIndex[role.id] = i
            laneX[role.id] = CGFloat(i) * laneWidth
        }

        let rows = Self.rowAssignment(model: model)

        for step in model.steps {
            guard let lane = laneIndex[step.roleID], let row = rows[step.id] else { continue }
            let x = CGFloat(lane) * laneWidth + (laneWidth - nodeWidth) / 2
            let y = headerHeight + CGFloat(row) * rowHeight + (rowHeight - nodeHeight) / 2
            nodeFrames[step.id] = CGRect(x: x, y: y, width: nodeWidth, height: nodeHeight)
        }

        let contentRows = max(1, model.steps.count)
        let gutterWidth: CGFloat = 40
        size = CGSize(
            width: CGFloat(roleCount) * laneWidth + gutterWidth,
            height: headerHeight + CGFloat(contentRows) * rowHeight + 20
        )

        buildEdgePaths(model: model, rows: rows, laneIndex: laneIndex)
    }

    /// Kahn's topological sort, ties broken by position in model.steps (the
    /// LLM's process order). A stall means a cycle (rework loop): force-emit
    /// the smallest-index remaining step; edges that end up pointing upward
    /// are classified as back edges afterwards.
    private static func rowAssignment(model: ProcessModel) -> [String: Int] {
        let stepIndex = Dictionary(uniqueKeysWithValues: model.steps.enumerated().map { ($1.id, $0) })
        var successors: [String: [String]] = [:]
        var indegree: [String: Int] = [:]
        for step in model.steps { indegree[step.id] = 0 }
        for edge in model.edges {
            successors[edge.from, default: []].append(edge.to)
            indegree[edge.to, default: 0] += 1
        }

        var emitted: [String] = []
        var emittedSet = Set<String>()
        var ready = model.steps.map(\.id).filter { indegree[$0] == 0 }

        while emitted.count < model.steps.count {
            let next: String
            if let candidate = ready.min(by: { stepIndex[$0, default: 0] < stepIndex[$1, default: 0] }) {
                ready.removeAll { $0 == candidate }
                next = candidate
            } else {
                // Cycle stall — force the smallest-index remaining step.
                guard let forced = model.steps.map(\.id)
                    .filter({ !emittedSet.contains($0) })
                    .min(by: { stepIndex[$0, default: 0] < stepIndex[$1, default: 0] }) else { break }
                next = forced
            }
            emitted.append(next)
            emittedSet.insert(next)
            for succ in successors[next, default: []] where !emittedSet.contains(succ) {
                indegree[succ, default: 1] -= 1
                if indegree[succ] == 0 && !ready.contains(succ) {
                    ready.append(succ)
                }
            }
        }

        return Dictionary(uniqueKeysWithValues: emitted.enumerated().map { ($1, $0) })
    }

    private mutating func buildEdgePaths(model: ProcessModel, rows: [String: Int], laneIndex: [String: Int]) {
        let rightmost = nodeFrames.values.map(\.maxX).max() ?? size.width
        let gutterX = rightmost + 16

        for edge in model.edges {
            guard let from = nodeFrames[edge.from], let to = nodeFrames[edge.to],
                  let rowFrom = rows[edge.from], let rowTo = rows[edge.to] else { continue }

            if rowFrom < rowTo {
                // Forward: bottom-center(A) → top-center(B), pointing down.
                let start = CGPoint(x: from.midX, y: from.maxY)
                let end = CGPoint(x: to.midX, y: to.minY)
                let gap = end.y - start.y
                var path = Path()
                path.move(to: start)
                if abs(start.x - end.x) < 1 && rowTo == rowFrom + 1 {
                    path.addLine(to: end)
                } else if abs(start.x - end.x) < 1 {
                    // Same lane, skip-row: detour sideways so the curve
                    // doesn't run through intermediate same-lane nodes.
                    let detourX = from.maxX + 18
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: detourX, y: start.y + gap * 0.3),
                        control2: CGPoint(x: detourX, y: end.y - gap * 0.3)
                    )
                } else {
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: start.y + gap * 0.5),
                        control2: CGPoint(x: end.x, y: end.y - gap * 0.5)
                    )
                }
                edgePaths.append(EdgePath(
                    edge: edge, path: path, isBack: false,
                    labelPoint: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
                    arrowPoint: end, arrowAngle: .pi / 2
                ))
            } else {
                // Back edge (rework loop): out the right side, up the gutter,
                // into the right side of the target. Drawn dashed.
                let start = CGPoint(x: from.maxX, y: from.midY)
                let end = CGPoint(x: to.maxX, y: to.midY)
                var path = Path()
                path.move(to: start)
                path.addLine(to: CGPoint(x: gutterX, y: start.y))
                path.addLine(to: CGPoint(x: gutterX, y: end.y))
                path.addLine(to: end)
                edgePaths.append(EdgePath(
                    edge: edge, path: path, isBack: true,
                    labelPoint: CGPoint(x: gutterX, y: (start.y + end.y) / 2),
                    arrowPoint: end, arrowAngle: .pi
                ))
            }
        }
    }
}

/// Native swimlane rendering: lane tints + pinned headers, a Canvas for the
/// edges, and positioned node views. Stable ids mean revisions animate
/// (grow/correct) instead of rebuilding.
struct ProcessDiagramView: View {
    let model: ProcessModel

    var body: some View {
        if model.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("The diagram builds itself as the process is discussed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    diagram(availableWidth: geo.size.width)
                        .animation(.spring(duration: 0.45), value: model)
                }
            }
        }
    }

    private func diagram(availableWidth: CGFloat) -> some View {
        let layout = ProcessDiagramLayout(model: model, availableWidth: availableWidth)
        return ZStack(alignment: .topLeading) {
            lanes(layout: layout)
            Canvas { context, _ in
                for edgePath in layout.edgePaths {
                    let style = StrokeStyle(
                        lineWidth: 1.5,
                        dash: edgePath.isBack ? [5, 4] : []
                    )
                    context.stroke(edgePath.path, with: .color(.secondary), style: style)
                    context.fill(
                        Self.arrowhead(at: edgePath.arrowPoint, angle: edgePath.arrowAngle),
                        with: .color(.secondary)
                    )
                    if let label = edgePath.edge.label, !label.isEmpty {
                        context.draw(
                            Text(label).font(.caption2).foregroundStyle(.secondary),
                            at: edgePath.labelPoint
                        )
                    }
                }
            }
            ForEach(model.sanitized().steps) { step in
                if let frame = layout.nodeFrames[step.id] {
                    nodeView(step)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func lanes(layout: ProcessDiagramLayout) -> some View {
        ForEach(Array(model.roles.enumerated()), id: \.element.id) { index, role in
            VStack(spacing: 0) {
                Text(role.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: layout.laneWidth, height: layout.headerHeight)
                Rectangle()
                    .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.03) : Color.primary.opacity(0.06))
                    .frame(width: layout.laneWidth, height: layout.size.height - layout.headerHeight)
            }
            .offset(x: CGFloat(index) * layout.laneWidth)
        }
    }

    private func nodeView(_ step: ProcessStep) -> some View {
        Text(step.title)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .help(step.detail ?? step.title)
    }

    private static func arrowhead(at point: CGPoint, angle: CGFloat) -> Path {
        // 7pt filled triangle whose tip sits on `point`, oriented along the
        // path tangent (angle = direction of travel at entry).
        var path = Path()
        let size: CGFloat = 7
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: -size, y: -size * 0.55))
        path.addLine(to: CGPoint(x: -size, y: size * 0.55))
        path.closeSubpath()
        return path.applying(
            CGAffineTransform(translationX: point.x, y: point.y).rotated(by: angle)
        )
    }
}
