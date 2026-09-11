// App/Sources/ActivityProcessWatcher.swift
import Foundation

/// kqueue EVFILT_PROC via DispatchSource: the instant a watched process exits, `onExit` fires on `queue`.
/// This is what removes a stuck session or job without waiting for an end event that may never come.
final class ActivityProcessWatcher {
    var onExit: ((Int32) -> Void)?
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let queue: DispatchQueue
    init(queue: DispatchQueue = .main) { self.queue = queue }

    func watch(pid: Int32) {
        queue.async { [self] in
            guard sources[pid] == nil else { return }
            guard kill(pid, 0) == 0 || errno == EPERM else { onExit?(pid); return }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.sources.removeValue(forKey: pid)?.cancel()
                self.onExit?(pid)
            }
            source.resume()
            sources[pid] = source
            // The pid may have died between the liveness check and resume(): the attach silently misses it.
            if kill(pid, 0) != 0 && errno != EPERM { sources.removeValue(forKey: pid)?.cancel(); onExit?(pid) }
        }
    }
    func unwatchAll(except keep: Set<Int32>) {
        queue.async { [self] in
            for (pid, source) in sources where !keep.contains(pid) { source.cancel(); sources.removeValue(forKey: pid) }
        }
    }
}
