import Foundation

/// `put_attachment`: a screenshot taken on the phone, staged on the machine the
/// session runs on, answered with the path Claude can read.
///
/// The phone cannot hand bytes to a tmux pane any more than a drag can — the
/// desktop solved that by staging the file and sending its path, and this is the
/// same trick with a longer first hop. The bytes ride the relay as base64 in one
/// message; the client shrinks a screenshot before sending, so that message is
/// a few hundred KB rather than the several MB an untouched capture would be.
///
/// Compiled by the agent as well as the app, so it answers whether the phone is
/// paired to the Mac or straight to the box. The difference between the two is
/// one branch: a Mac staging for a session on a remote box has to copy the file over
/// before it answers, because the path it just wrote is meaningless there.
extension MobileBridge {

    func handlePutAttachment(_ payload: [String: Any], id: UUID?) {
        // Echoed back on the reply. The phone can have two screenshots in
        // flight for one session, and without this it could not tell which
        // chip a path belonged to.
        let token = (payload["token"] as? String) ?? ""

        guard let id, let snap = stateStore.snapshot(id: id) else {
            failAttachment(token: token, id: id, "unknown session")
            return
        }
        guard let encoded = payload["data"] as? String,
              // `.ignoreUnknownCharacters` because a base64 payload that picked
              // up a newline somewhere is still perfectly good bytes, and
              // refusing it would be a mystery on the phone.
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !data.isEmpty
        else {
            failAttachment(token: token, id: id, "attachment carried no readable data")
            return
        }

        let name = (payload["name"] as? String) ?? "image.png"
        let mime = payload["mime"] as? String
        let url: URL
        do {
            url = try AttachmentStaging.write(data, name: name, mime: mime)
        } catch {
            failAttachment(token: token, id: id, error.localizedDescription)
            return
        }
        Log.bridge.info("put_attachment: staged \(data.count) bytes at \(url.path)")

#if !UDHA_AGENT
        // A session on a box reads its own filesystem, so the file has to be
        // there — and Send stays off on the phone until this answers, which is
        // why the copy is awaited rather than fired off.
        if let host = snap.hostName {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let remote = try await AttachmentStaging.upload(url, to: host)
                    self.finishAttachment(token: token, id: id, path: remote, name: url.lastPathComponent)
                } catch {
                    self.failAttachment(token: token, id: id,
                                        "could not copy to \(host): \(error.localizedDescription)")
                }
            }
            return
        }
#endif
        finishAttachment(token: token, id: id, path: url.path, name: url.lastPathComponent)
    }

    private func finishAttachment(token: String, id: UUID, path: String, name: String) {
        logRemote("put_attachment", id: id, detail: name)
        relay.sendRelay([
            "type": "attachment_staged",
            "id": id.uuidString,
            "token": token,
            "path": path,
            "name": name,
        ])
    }

    private func failAttachment(token: String, id: UUID?, _ message: String) {
        Log.bridge.error("put_attachment failed: \(message)")
        var payload: [String: Any] = [
            "type": "attachment_staged",
            "token": token,
            "error": message,
        ]
        if let id { payload["id"] = id.uuidString }
        relay.sendRelay(payload)
    }
}
