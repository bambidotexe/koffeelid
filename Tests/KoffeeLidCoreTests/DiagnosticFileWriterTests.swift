import XCTest
import KoffeeLidCore

final class DiagnosticFileWriterTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dfw-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func testAppendsLinesAndCreatesLockFile() throws {
        let dir = tempDir()
        let w = DiagnosticFileWriter(url: dir.appendingPathComponent("diagnostics.log"))
        w.append("one"); w.append("two")
        XCTAssertEqual(try String(contentsOf: w.url, encoding: .utf8), "one\ntwo\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.lockURL.path))
    }
    func testRotatesWhenOverMaxBytes() throws {
        let dir = tempDir()
        let w = DiagnosticFileWriter(url: dir.appendingPathComponent("diagnostics.log"), maxBytes: 10)
        w.append("0123456789ab")           // 13 bytes with newline → next append rotates
        w.append("new")
        XCTAssertEqual(try String(contentsOf: w.rotatedURL, encoding: .utf8), "0123456789ab\n")
        XCTAssertEqual(try String(contentsOf: w.url, encoding: .utf8), "new\n")
    }
    func testConcurrentAppendsFromManyThreadsLoseNothing() throws {
        let dir = tempDir()
        let w = DiagnosticFileWriter(url: dir.appendingPathComponent("diagnostics.log"))
        DispatchQueue.concurrentPerform(iterations: 200) { i in w.append("line \(i)") }
        let lines = try String(contentsOf: w.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        XCTAssertEqual(Set(lines).count, 200)
    }
}
