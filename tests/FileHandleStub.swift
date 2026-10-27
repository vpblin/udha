import Foundation

// The real helper lives in Sessions/TmuxSession.swift, which the test build
// does not compile (it pulls in the whole session engine). ClaudeAccountPool
// and SystemStatsCollector call it, so the tests get this copy.
extension FileHandle {
    func readToEndRetryingInterrupts() -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n) }
            else if n < 0 && errno == EINTR { continue }
            else { return data }
        }
    }
}
