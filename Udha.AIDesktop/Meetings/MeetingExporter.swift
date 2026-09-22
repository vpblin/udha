import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Export surfaces for a finished meeting: a self-contained Markdown file
/// (notes + action items + fenced mermaid diagram), a PNG of the swimlane
/// diagram (ImageRenderer, off the live view so scroll clipping can't bite),
/// and Mermaid text on the pasteboard.
@MainActor
enum MeetingExporter {

    static func notesMarkdown(meeting: Meeting, store: MeetingStore) -> String {
        var lines: [String] = ["# \(meeting.title)", ""]
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var metadata = df.string(from: meeting.createdAt)
        if let duration = meeting.durationSeconds {
            metadata += " · \(Int(duration / 60)) min"
        }
        lines.append(metadata)
        lines.append("")
        if !meeting.summary.isEmpty {
            lines.append("## Summary")
            lines.append(meeting.summary)
            lines.append("")
        }
        // Yours first: the export is the record of the meeting, and the write-up
        // is built around these rather than replacing them.
        let mine = store.loadUserNotes(for: meeting).trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty {
            lines.append("## Your notes")
            for note in mine.components(separatedBy: "\n")
            where !note.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("- \(note)")
            }
            lines.append("")
        }
        let notes = store.loadAINotes(for: meeting)
        if !notes.isEmpty {
            lines.append(notes)
            lines.append("")
        }
        if !meeting.actionItems.isEmpty {
            lines.append("## Action items")
            for item in meeting.actionItems {
                let box = item.done ? "[x]" : "[ ]"
                let owner = item.owner.map { " — \($0)" } ?? ""
                lines.append("- \(box) \(item.text)\(owner)")
            }
            lines.append("")
        }
        if let process = store.loadProcessModel(for: meeting), !process.isEmpty {
            lines.append("## Process map")
            lines.append("```mermaid")
            lines.append(process.mermaidText())
            lines.append("```")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func exportNotes(meeting: Meeting, store: MeetingStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(slug(meeting.title)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = notesMarkdown(meeting: meeting, store: store)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.meeting.error("MeetingExporter: notes export failed: \(error.localizedDescription)")
        }
    }

    static func copyNotes(meeting: Meeting, store: MeetingStore) {
        let markdown = notesMarkdown(meeting: meeting, store: store)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    static func copyMermaid(model: ProcessModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.mermaidText(), forType: .string)
    }

    static func exportDiagramPNG(model: ProcessModel, title: String) {
        guard let data = renderDiagramPNG(model: model) else {
            Log.meeting.error("MeetingExporter: diagram render failed")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(slug(title))-process.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            Log.meeting.error("MeetingExporter: diagram export failed: \(error.localizedDescription)")
        }
    }

    static func renderDiagramPNG(model: ProcessModel) -> Data? {
        let width = CGFloat(max(1, model.roles.count)) * 220
        let layout = ProcessDiagramLayout(model: model, availableWidth: width)
        // Render a non-scrolling copy at intrinsic size; the live view's
        // ScrollView would clip anything off-screen.
        let view = ProcessDiagramExportView(model: model)
            .frame(width: layout.size.width, height: layout.size.height)
            .background(Color(NSColor.windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "meeting" : collapsed
    }
}

/// The diagram body without the ScrollView wrapper, for ImageRenderer.
private struct ProcessDiagramExportView: View {
    let model: ProcessModel

    var body: some View {
        let width = CGFloat(max(1, model.roles.count)) * 220
        let layout = ProcessDiagramLayout(model: model, availableWidth: width)
        ZStack(alignment: .topLeading) {
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
            Canvas { context, _ in
                for edgePath in layout.edgePaths {
                    let style = StrokeStyle(lineWidth: 1.5, dash: edgePath.isBack ? [5, 4] : [])
                    context.stroke(edgePath.path, with: .color(.secondary), style: style)
                    var arrow = Path()
                    let size: CGFloat = 7
                    arrow.move(to: .zero)
                    arrow.addLine(to: CGPoint(x: -size, y: -size * 0.55))
                    arrow.addLine(to: CGPoint(x: -size, y: size * 0.55))
                    arrow.closeSubpath()
                    context.fill(
                        arrow.applying(
                            CGAffineTransform(translationX: edgePath.arrowPoint.x, y: edgePath.arrowPoint.y)
                                .rotated(by: edgePath.arrowAngle)
                        ),
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
                    Text(step.title)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .frame(width: frame.width, height: frame.height)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }
}
