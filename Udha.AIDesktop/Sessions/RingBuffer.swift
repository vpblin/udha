import Foundation

final class RingBuffer: @unchecked Sendable {
    private var storage: [String] = []
    private let maxLines: Int
    private let lock = NSLock()
    private var partialLine: String = ""

    init(maxLines: Int = 2000) {
        self.maxLines = maxLines
    }

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        append(string: chunk)
    }

    func append(string: String) {
        lock.lock()
        defer { lock.unlock() }
        let combined = partialLine + string
        var lines = combined.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        // Cap partial line to last 4096 chars so we don't accumulate megabytes
        // of cursor-positioning noise (which happens with TUI apps).
        if partialLine.count > 4096 {
            partialLine = String(partialLine.suffix(4096))
        }
        for line in lines {
            let stripped = Self.stripANSI(line)
            storage.append(stripped)
            if storage.count > maxLines {
                storage.removeFirst(storage.count - maxLines)
            }
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func recent(lines: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(lines, storage.count)
        var result = Array(storage.suffix(n))
        if !partialLine.isEmpty {
            result.append(Self.stripANSI(partialLine))
        }
        return result
    }

    func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        partialLine = ""
    }

    static func stripANSI(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\u{1B}" {
                let next = s.index(after: i)
                guard next < s.endIndex else { break }
                let n = s[next]
                if n == "[" {
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        let ch = s[j]
                        if (ch >= "@" && ch <= "~") { j = s.index(after: j); break }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                } else if n == "]" {
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        if s[j] == "\u{07}" { j = s.index(after: j); break }
                        if s[j] == "\u{1B}" {
                            let k = s.index(after: j)
                            if k < s.endIndex, s[k] == "\\" { j = s.index(after: k); break }
                        }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    i = s.index(after: next)
                    continue
                }
            }
            if c == "\r" {
                i = s.index(after: i)
                continue
            }
            result.append(c)
            i = s.index(after: i)
        }
        return result
    }
}
