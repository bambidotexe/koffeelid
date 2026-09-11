import Foundation

public enum ActivityJournalWriter {
    /// One open + one write(2) on an O_APPEND descriptor. Lines are capped upstream, so concurrent hook
    /// processes append atomically in practice. O_CREAT means rotation needs no coordination.
    @discardableResult
    public static func append(_ line: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = line; data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return write(fd, base, buf.count)
        }
        return written == data.count
    }

    public static func readAll(url: URL) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { ActivityCodec.decodeLine(Data($0)) }
    }
}
