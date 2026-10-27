import AppKit

/// Restarts Udha as a fresh process.
///
/// The replacement must not boot while this one is still alive: two instances
/// fight over the same config file and the same tmux sessions, which shows up
/// as new sessions dying instantly and config entries vanishing. `open -n`
/// would do exactly that, so instead a detached shell polls for our pid to
/// disappear and only then re-opens the bundle. Spawned children are reparented
/// to launchd when we exit, so the helper outlives us.
@MainActor
enum AppRelaunch {
    enum Failure: LocalizedError {
        case bundleMissing(String)
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundleMissing(let path):
                // The Debug build lives under /private/tmp, which macOS prunes.
                return "The app bundle is no longer at \(path) — rebuild before restarting."
            case .spawnFailed(let reason):
                return "Could not start the relaunch helper: \(reason)"
            }
        }
    }

    /// Spawns the helper, then terminates. Throws (without quitting) if the
    /// helper could not be started — quitting then would leave nothing to come
    /// back, so a failure here is strictly better than a one-way trip.
    static func restart() throws {
        let bundlePath = Bundle.main.bundleURL.path
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw Failure.bundleMissing(bundlePath)
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        // The wait is bounded so a quit vetoed by some other part of the app
        // can't strand the helper spinning forever. Falling through early is
        // harmless: `open` without `-n` activates the running instance rather
        // than starting a second one.
        let script = """
        i=0
        while [ $i -lt 100 ] && /bin/kill -0 \(pid) 2>/dev/null; do
            /bin/sleep 0.2
            i=$((i+1))
        done
        /usr/bin/open "$1"
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Passing the path as $1 rather than interpolating it into the script
        // keeps shell quoting out of the picture entirely.
        p.arguments = ["-c", script, "udha-relaunch", bundlePath]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            throw Failure.spawnFailed(error.localizedDescription)
        }

        Log.app.info("relaunch: helper spawned for pid \(pid), terminating")
        NSApp.terminate(nil)
    }
}
