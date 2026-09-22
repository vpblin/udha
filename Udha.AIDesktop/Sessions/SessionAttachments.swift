import AppKit
import UniformTypeIdentifiers

/// One file staged for the next message to a session.
///
/// Claude Code has no way to receive bytes through tmux, so a file reaches a
/// session the same way it would if you dragged it into the terminal yourself:
/// as a path it can read. Udha copies the dropped file somewhere stable first,
/// because the original may be a screenshot on the Desktop that gets renamed,
/// moved or deleted long before Claude gets around to reading it.
struct SessionAttachment: Identifiable, Equatable {
    let id = UUID()
    /// The staged copy on this Mac — also what the chip's thumbnail draws.
    let localURL: URL
    /// The machine the session runs on, when it is not this Mac.
    let host: String?
    /// The copy on that machine. Nil while the transfer is still in flight.
    var remotePath: String?
    /// Set when the copy to `host` failed; the chip says so and Send stays off.
    var failure: String?
    /// Small preview, decoded once at staging time.
    let preview: NSImage?

    /// The path the session's own machine can open.
    var path: String { remotePath ?? localURL.path }
    var name: String { localURL.lastPathComponent }
    /// A remote attachment is only sendable once its copy has landed.
    var isReady: Bool { failure == nil && (host == nil || remotePath != nil) }
}

/// Staging for files dropped onto a session: copy in, copy over, compose.
enum SessionAttachments {

    /// The staging tree and everything that does not need AppKit live in
    /// `AttachmentStaging`, which the headless agent compiles too — a phone
    /// paired straight to the box stages through the same directory this does.
    static let directory = AttachmentStaging.directory

    private static var dirURL: URL { AttachmentStaging.dirURL }

    // MARK: - Drop

    /// Whether a drop carries anything we could stage. Answered synchronously,
    /// because `onDrop` has to accept or refuse before the mouse comes up.
    static func canHandle(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { p in
            p.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }

    /// Copy every file in a drop into the staging directory. Returns one
    /// attachment per file; a folder in the same drop is skipped. The
    /// remote copy is *not* done here — see `upload` — so the chips appear
    /// the moment the file is on disk rather than after an SSH round trip.
    static func stage(_ providers: [NSItemProvider], host: String?) async -> [SessionAttachment] {
        prune()
        var out: [SessionAttachment] = []
        for provider in providers {
            guard let url = await staged(from: provider) else { continue }
            out.append(SessionAttachment(localURL: url,
                                         host: host,
                                         preview: preview(for: url)))
        }
        return out
    }

    /// Put a staged file on `host` and answer with its path there.
    ///
    /// Batch mode and a short connect timeout on purpose: a box that is off, or
    /// an SSH that wants a passphrase, has to fail the chip in a few seconds
    /// rather than leave it saying "copying…" with Send disabled behind it.
    static func upload(_ url: URL, to host: String) async throws -> String {
        try await AttachmentStaging.upload(url, to: host)
    }

    /// The single line handed to the session: the staged paths first — Claude
    /// reads a bare absolute path — then whatever was typed alongside them.
    static func compose(text: String, attachments: [SessionAttachment]) -> String {
        AttachmentStaging.compose(text: text, paths: attachments.map(\.path))
    }

    // MARK: - Staging one item

    private static func staged(from provider: NSItemProvider) async -> URL? {
        // A file dragged from Finder — a screenshot, a deck, a PDF, a CSV:
        // anything Claude can open by path. Only a directory (or a bundle,
        // which is one) is declined, since a path to it says nothing useful.
        if let url = await fileURL(from: provider), isRegularFile(url) {
            let dest = destination(for: url.deletingPathExtension().lastPathComponent,
                                   ext: url.pathExtension.isEmpty ? "png" : url.pathExtension)
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: dest)
                return dest
            } catch {
                Log.app.error("attachment: copying \(url.path) failed: \(error.localizedDescription)")
                return nil
            }
        }
        // Raw pixels — an image dragged straight out of a browser or Preview,
        // which arrives as data with no file behind it.
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier), type.conforms(to: .image),
                  let ext = type.preferredFilenameExtension,
                  let data = await data(from: provider, identifier: identifier) else { continue }
            let dest = destination(for: "dropped", ext: ext)
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: dest)
                return dest
            } catch {
                Log.app.error("attachment: writing dropped image failed: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                // Cocoa hands this back as an NSURL or as the url's bytes,
                // depending on where the drag started.
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data {
                    cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func data(from provider: NSItemProvider, identifier: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// The chip's thumbnail: the picture for an image, the Finder icon for
    /// anything else — a deck looks like a deck, a PDF like a PDF.
    static func preview(for url: URL) -> NSImage? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func destination(for name: String, ext: String) -> URL {
        AttachmentStaging.destination(for: name, ext: ext)
    }

    private static func prune() { AttachmentStaging.prune() }

}
