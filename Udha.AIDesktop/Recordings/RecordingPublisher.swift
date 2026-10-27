import Foundation

/// Uploads a finished recording's masters to a video host and registers the
/// share link with your own share API (`recordings.shareAPIBaseURL`). No share
/// backend ships with this app and there is no default — publishing is off
/// until you point it at one you run.
///
/// The contract that backend has to satisfy is three routes, all bearing the
/// bridge's Auth0 access token:
///   POST   {base}/api/videos/upload-url  → { upload_url, uid }   (one slot per
///          master; `size_bytes` in the body asks for a resumable tus slot)
///   POST   {base}/api/videos             → { slug, url }         (register)
///   PATCH  {base}/api/videos/{slug}      → 2xx                   (retitle)
///
/// **Never put a storage or CDN credential in this app.** The flow is
/// deliberately three-legged: ask *your* API (authenticated with the Auth0
/// access token the bridge already holds) for a one-time direct-upload URL,
/// push the bytes straight to the video host with it, then tell your API what
/// was uploaded. Video bytes never transit the API, and no long-lived upload
/// token ever ships inside a desktop binary — where it would be readable by
/// anyone who downloads the app, and unrevocable without shipping a new build.
/// A repository's history is just as public: a secret committed once stays
/// recoverable forever, so rotate anything that has ever been committed rather
/// than merely deleting it.
///
/// Uploads stream from disk — a half-hour demo is never held in memory to be
/// sent. Masters go up over tus, one PATCH per chunk: Cloudflare's plain
/// multipart endpoint is capped at 200 MB and rejects anything bigger with an
/// nginx 413 at the edge, which a recording passes after ~5 minutes even at the
/// compositor's HEVC bitrate. The multipart path is kept only for a share
/// service that does not offer tus.
actor RecordingPublisher {
    private let auth0: Auth0Client
    private let config: ConfigStore
    private let session: URLSession

    init(auth0: Auth0Client, config: ConfigStore) {
        self.auth0 = auth0
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        // Generous: this is the ceiling for pushing a whole master to
        // Cloudflare over whatever connection the user happens to be on.
        cfg.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: cfg)
    }

    enum PublishError: LocalizedError {
        case notSignedIn
        case notConfigured
        case noMasters
        case http(Int, String, step: String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in to the mobile bridge first — publishing uses the same account."
            case .notConfigured:
                return "No share backend is set — enter one under Settings → Advanced → Video share backend."
            case .noMasters:
                return "This recording has no rendered video to publish."
            case .http(let code, let body, let step):
                return "\(step) failed with \(code). \(body.prefix(200))"
            case .malformedResponse(let what):
                return "Unexpected response from the share service (\(what))."
            }
        }
    }

    struct Published: Sendable {
        var slug: String
        var url: URL
    }

    // MARK: - Publish

    /// Uploads every rendered master, then registers the share.
    /// `onProgress` reports 0…1 across the whole operation.
    func publish(
        recording: Recording,
        masters: [RecordingOrientation: URL],
        captionsVTT: String?,
        password: String?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Published {
        guard !masters.isEmpty else { throw PublishError.noMasters }

        let token: String
        do {
            token = try await auth0.getValidAccessToken()
        } catch {
            throw PublishError.notSignedIn
        }

        let base = await MainActor.run { config.config.recordings.shareAPIBaseURL }
        guard !base.isEmpty else { throw PublishError.notConfigured }
        let isProtected = !(password ?? "").isEmpty

        // Upload each master. The share is registered only after every byte is
        // in, so a failed upload leaves no half-published link behind.
        var uids: [RecordingOrientation: String] = [:]
        let total = Double(masters.count)
        for (index, orientation) in masters.keys.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            guard let fileURL = masters[orientation] else { continue }
            let size = try Self.fileSize(of: fileURL)
            let ticket = try await requestUploadURL(
                base: base, token: token, orientation: orientation,
                isProtected: isProtected, sizeBytes: size
            )
            try await upload(fileURL: fileURL, size: size, using: ticket) { fraction in
                onProgress?((Double(index) + fraction) / (total + 1))
            }
            uids[orientation] = ticket.uid
            Log.recording.info("RecordingPublisher: uploaded \(orientation.rawValue) as \(ticket.uid)")
        }

        onProgress?(total / (total + 1))
        let published = try await register(
            base: base, token: token, recording: recording,
            uids: uids, captionsVTT: captionsVTT, password: password
        )
        onProgress?(1)
        Log.recording.info("RecordingPublisher: published \(recording.folderName) → \(published.url.absoluteString)")
        return published
    }

    // MARK: - Rename

    /// Pushes a new title to the share service, so the public page and its
    /// unfurl card match what the recording is called in the app.
    func rename(slug: String, title: String) async throws {
        let token: String
        do {
            token = try await auth0.getValidAccessToken()
        } catch {
            throw PublishError.notSignedIn
        }

        let base = await MainActor.run { config.config.recordings.shareAPIBaseURL }
        guard !base.isEmpty else { throw PublishError.notConfigured }
        var request = URLRequest(url: URL(string: "\(base)/api/videos/\(slug)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])

        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data, step: "Renaming the share")
    }

    // MARK: - Steps

    private struct UploadTicket { var uploadURL: URL; var uid: String; var isResumable: Bool }

    /// tus wants every chunk but the last to be a multiple of 256 KiB, no
    /// smaller than 5 MiB and no larger than 200 MiB. 32 MiB keeps peak memory
    /// bounded while still being few enough round trips for a 600 MB master.
    private static let tusChunkSize = 32 * 1024 * 1024
    private static let tusVersion = "1.0.0"
    private static let tusMaxRetries = 4

    private func requestUploadURL(
        base: String, token: String, orientation: RecordingOrientation,
        isProtected: Bool, sizeBytes: Int64
    ) async throws -> UploadTicket {
        var request = URLRequest(url: URL(string: "\(base)/api/videos/upload-url")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "orientation": orientation.rawValue,
            "protected": isProtected,
            // Its presence is what asks for a resumable slot; tus needs the
            // length up front, before a single byte moves.
            "size_bytes": sizeBytes,
        ])

        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data, step: "Asking the share service for an upload slot")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = object["upload_url"] as? String,
              let uploadURL = URL(string: urlString),
              let uid = object["uid"] as? String else {
            throw PublishError.malformedResponse("upload-url")
        }
        return UploadTicket(
            uploadURL: uploadURL, uid: uid,
            isResumable: (object["protocol"] as? String) == "tus"
        )
    }

    private func upload(
        fileURL: URL, size: Int64, using ticket: UploadTicket,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if ticket.isResumable {
            try await uploadResumable(fileURL: fileURL, to: ticket.uploadURL, size: size, onProgress: onProgress)
        } else {
            try await uploadMultipart(fileURL: fileURL, to: ticket.uploadURL, onProgress: onProgress)
        }
    }

    /// Pushes the file as a tus upload: a PATCH per chunk, each acknowledged
    /// with the new offset. Cloudflare's offset is authoritative, so a dropped
    /// connection is survivable — ask where it actually got to and carry on
    /// from there rather than assuming the failed chunk landed.
    private func uploadResumable(
        fileURL: URL, to uploadURL: URL, size: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var attempts = 0
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: Self.tusChunkSize), !chunk.isEmpty else { break }

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PATCH"
            request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")
            request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")

            do {
                let sent = Double(offset)
                let span = Double(chunk.count)
                let delegate = UploadProgressDelegate { fraction in
                    onProgress(min(1, (sent + fraction * span) / Double(size)))
                }
                let (data, response) = try await session.upload(for: request, from: chunk, delegate: delegate)
                try Self.checkStatus(response, data, step: "Uploading the video")
                guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Upload-Offset"),
                      let next = Int64(header), next > offset else {
                    // An offset that does not advance would re-send the same
                    // chunk forever; fail loudly instead of spinning.
                    throw PublishError.malformedResponse("tus offset")
                }
                offset = next
                attempts = 0
                onProgress(Double(offset) / Double(size))
            } catch {
                attempts += 1
                guard attempts <= Self.tusMaxRetries else { throw error }
                offset = try await resumeOffset(of: uploadURL)
                Log.recording.info("RecordingPublisher: retrying upload from offset \(offset)/\(size)")
            }
        }
    }

    /// tus HEAD — how many bytes Cloudflare actually holds.
    private func resumeOffset(of uploadURL: URL) async throws -> Int64 {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "HEAD"
        request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")

        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data, step: "Resuming the upload")
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int64(header) else {
            throw PublishError.malformedResponse("tus offset")
        }
        return offset
    }

    /// Cloudflare's direct-upload endpoint takes a multipart POST with the file
    /// under the field name `file`. Capped at 200 MB — see `uploadResumable`.
    private func uploadMultipart(fileURL: URL, to uploadURL: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let boundary = "udha-\(UUID().uuidString)"
        let bodyURL = try Self.makeMultipartFile(fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: delegate)
        try Self.checkStatus(response, data, step: "Uploading the video")
    }

    private func register(
        base: String, token: String, recording: Recording,
        uids: [RecordingOrientation: String], captionsVTT: String?, password: String?
    ) async throws -> Published {
        var payload: [String: Any] = [
            "title": recording.title,
            "duration_seconds": recording.durationSeconds,
            "recording_id": recording.id.uuidString,
        ]
        if let landscape = uids[.landscape] { payload["stream_uid_landscape"] = landscape }
        if let portrait = uids[.portrait] { payload["stream_uid_portrait"] = portrait }
        if let captionsVTT, !captionsVTT.isEmpty { payload["captions_vtt"] = captionsVTT }
        if let password, !password.isEmpty { payload["password"] = password }

        var request = URLRequest(url: URL(string: "\(base)/api/videos")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data, step: "Registering the share link")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slug = object["slug"] as? String,
              let urlString = object["url"] as? String,
              let url = URL(string: urlString) else {
            throw PublishError.malformedResponse("publish")
        }
        return Published(slug: slug, url: url)
    }

    // MARK: - Helpers

    private static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data, step: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw PublishError.http(status, String(data: data, encoding: .utf8) ?? "", step: step)
        }
    }

    /// Builds `<prefix><file bytes><suffix>` on disk so the upload streams
    /// rather than materialising the whole master in memory.
    private static func makeMultipartFile(fileURL: URL, boundary: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("udha-upload-\(UUID().uuidString).tmp")

        // Assembled by hand rather than as a multi-line literal. That literal
        // dropped the newline after its last line, so the blank line separating
        // the part headers from the body arrived as a bare CR — and Cloudflare
        // rejected every upload with "a portion of the request could be not
        // decoded". Multipart framing is exact; write the CRLFs explicitly.
        let prefix = Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
            + "Content-Type: video/mp4\r\n"
            + "\r\n"
        ).utf8)
        let suffix = Data("\r\n--\(boundary)--\r\n".utf8)

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: prefix)

        let source = try FileHandle(forReadingFrom: fileURL)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: suffix)
        return tempURL
    }
}

/// Reports upload progress. `URLSession`'s async `upload(for:fromFile:)` accepts
/// a per-task delegate, which is the only way to see byte progress without
/// dropping back to the completion-handler API.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
