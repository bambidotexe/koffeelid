import Foundation

/// Appends timestamped lines to a log file shared between processes.
/// Serializes rotation + append with an exclusive `flock` on a sibling `.lock` file.
public final class DiagnosticFileWriter {
    public let url: URL
    public let lockURL: URL
    public let maxBytes: Int

    public init(url: URL, maxBytes: Int = 256 * 1024) {
        self.url = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent("diagnostics.lock")
        self.maxBytes = maxBytes
    }

    public var rotatedURL: URL { url.deletingLastPathComponent().appendingPathComponent("diagnostics.1.log") }

    /// Appends one already-rendered line (no trailing newline needed). Never throws; failures are dropped.
    public func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: url, to: rotatedURL)
        }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
