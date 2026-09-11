/// Orders `DesktopCapture.start()` against `stop()`. A start takes a token before its first await, and
/// the stream it produces is installed only while that token is still current, so a stop (or a newer
/// start) that landed anywhere in between wins, the shareable-content await included.
struct CaptureStartGate {
    private(set) var generation = 0

    mutating func beginStart() -> Int { generation += 1; return generation }
    mutating func stop() { generation += 1 }
    func isCurrent(_ token: Int) -> Bool { token == generation }
}
