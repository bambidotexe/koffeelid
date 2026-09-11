import Foundation

public final class RelaunchHistoryStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [Date] {
        guard let data = try? Data(contentsOf: url),
              let secs = try? JSONDecoder().decode([Double].self, from: data) else { return [] }
        return secs.map { Date(timeIntervalSince1970: $0) }
    }

    public func save(_ dates: [Date]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(dates.map { $0.timeIntervalSince1970 })
        try data.write(to: url, options: .atomic)
    }
}
