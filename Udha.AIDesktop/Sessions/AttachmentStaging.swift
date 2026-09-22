import Foundation

/// Where an image becomes a path a session can read, and how it gets to the
/// machine that session runs on.
///
/// Split out of `SessionAttachments` so the headless agent can stage too. That
/// file speaks AppKit — `NSItemProvider`, `NSImage` — because a drop on the Mac
/// arrives as pasteboard items; a phone sends bytes, and bytes need nothing but
/// Foundation. The agent symlinks this file and not that one, so a session on
/// a remote box can be handed a screenshot whether the phone is paired to the Mac
/// or straight to the box.
enum AttachmentStaging {

    /// Same `/tmp/udha` tree the logs and the status sidecar already use, and
    /// the same path on the box — so a remote session reads the file at the
    /// address the Mac staged it under.
    static let directory = "/tmp/udha/attachments"

    static var dirURL: URL { URL(fileURLWithPath: directory, isDirectory: true) }

    /// The biggest attachment a client may stage. A screenshot that has been
    /// downscaled and JPEG'd is a few hundred KB; anything past this is either
    /// a mistake or an original the sender forgot to shrink, and writing it
    /// costs the same `/tmp` a dozen sessions share.
    static let maximumBytes = 8 * 1024 * 1024

    // MARK: - Writing

    /// Write bytes into the staging directory and answer the file.
    ///
    /// The name is advisory: it survives only as the readable stem of a
    /// collision-proof filename, and its extension is only trusted when the
    /// declared type has none to offer.
    static func write(_ data: Data, name: String, mime: String?) throws -> URL {
        guard !data.isEmpty else {
            throw error("empty attachment")
        }
        guard data.count <= maximumBytes else {
            throw error("attachment is \(data.count / 1024) KB — the limit is \(maximumBytes / 1024) KB")
        }
        prune()
        let named = (name as NSString).lastPathComponent
        let stem = (named as NSString).deletingPathExtension
        let url = destination(for: stem.isEmpty ? "image" : stem,
                             ext: extensionFor(mime: mime, name: named))
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// A collision-proof name that still says what the file was. Kept free of
    /// spaces and quotes so the path can go into the prompt unquoted.
    static func destination(for name: String, ext: String) -> URL {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(40))
        let stem = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "image" : safe
        let salt = UUID().uuidString.prefix(6).lowercased()
        return dirURL.appendingPathComponent("\(stem)-\(salt).\(ext.lowercased())")
    }

    /// The declared type decides the extension, because that is the thing the
    /// sender actually encoded. A name's suffix is the fallback, and `png` is
    /// the fallback's fallback — it is what a screenshot is.
    static func extensionFor(mime: String?, name: String) -> String {
        switch (mime ?? "").lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png":              return "png"
        case "image/heic":             return "heic"
        case "image/gif":              return "gif"
        case "image/webp":             return "webp"
        case "image/tiff":             return "tiff"
        default: break
        }
        let suffix = (name as NSString).pathExtension.lowercased()
        let known = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "pdf"]
        return known.contains(suffix) ? suffix : "png"
    }

    /// Drop staged files older than a day. macOS prunes `/tmp` eventually, but
    /// not before a week of screenshots has piled up in there.
    static func prune() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: keys) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: - Getting it to the machine that will read it

    /// Put a staged file on `host` and answer with its path there.
    ///
    /// Batch mode and a short connect timeout on purpose: a box that is off, or
    /// an SSH that wants a passphrase, has to fail the chip in a few seconds
    /// rather than leave it saying "copying…" with Send disabled behind it.
    static func upload(_ url: URL, to host: String) async throws -> String {
        let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        _ = try await run("/usr/bin/ssh", ssh + [host, "mkdir", "-p", directory])
        let remote = "\(directory)/\(url.lastPathComponent)"
        _ = try await run("/usr/bin/scp", ssh + ["-q", url.path, "\(host):\(remote)"])
        return remote
    }

    // MARK: - Composing

    /// The single line handed to the session: the staged paths first — Claude
    /// reads a bare absolute path — then whatever was typed alongside them.
    static func compose(text: String, paths: [String]) -> String {
        (paths + [text])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Process helper

    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: o)
                } else {
                    let why = (e.isEmpty ? o : e).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: error(why.isEmpty ? "\(tool) failed" : why,
                                                code: Int(proc.terminationStatus)))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "AttachmentStaging", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
