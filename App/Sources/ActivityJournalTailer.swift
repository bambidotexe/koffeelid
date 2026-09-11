// App/Sources/ActivityJournalTailer.swift
import Foundation
import KoffeeLidCore

/// Tails the activity journal with a vnode DispatchSource. `start()` drains what is already on disk (the
/// replay), then live appends arrive within milliseconds. A rename or delete (rotation) is followed by
/// draining the old inode and re-arming on the recreated path.
final class ActivityJournalTailer {
    var onEvents: (([ActivityEvent]) -> Void)?
    private let url: URL
    private let queue = DispatchQueue(label: "dev.rubens.koffeelid.activity.tailer")
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var remainder = Data()
    private var stopped = false
    private var startOffset: UInt64 = 0

    init(url: URL) { self.url = url }

    func start(fromOffset offset: UInt64 = 0) { queue.sync { startOffset = offset; openAndArm(); drain() } }
    func stop() { queue.sync { stopped = true; onEvents = nil; source?.cancel(); source = nil } }

    private func openAndArm() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_CREAT without O_TRUNC: opens the existing inode untouched or creates an empty one atomically.
        // fileExists + createFile would race a hook's own O_CREAT and truncate its line away.
        let fd = open(url.path, O_RDONLY | O_CREAT, 0o644)
        guard fd >= 0 else { self.fd = -1; scheduleReopen(); return }
        self.fd = fd
        if startOffset > 0 {
            var st = stat()
            if fstat(fd, &st) == 0 { let size = UInt64(max(0, st.st_size)); _ = lseek(fd, off_t(min(startOffset, size)), SEEK_SET) }
            startOffset = 0
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let flags = source.data
            self.drain()
            if flags.contains(.rename) || flags.contains(.delete) {
                self.source?.cancel(); self.source = nil; self.remainder.removeAll()
                self.openAndArm(); self.drain()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
    private func scheduleReopen() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped, self.source == nil else { return }
            self.openAndArm(); self.drain()
        }
    }
    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            remainder.append(contentsOf: buffer[0..<n])
        }
        var events: [ActivityEvent] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            let line = remainder.subdata(in: remainder.startIndex..<newline)
            remainder.removeSubrange(remainder.startIndex...newline)
            if !line.isEmpty, let e = ActivityCodec.decodeLine(line) { events.append(e) }
        }
        if !events.isEmpty { onEvents?(events) }
    }
}
