import Foundation

public enum DiagnosticLine {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    public static func render(_ date: Date, _ message: String) -> String {
        "[\(formatter.string(from: date))] \(message)"
    }
}
