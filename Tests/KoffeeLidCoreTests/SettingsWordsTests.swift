import XCTest

/// Every sentence the Settings window shows, in both languages, against the window's rules for words: each
/// `L("…")` key of the window's files (`Settings…swift`, and the Health page's `Health…swift`) is in the string
/// catalog with its French, neither language writes a long dash, and a key is its symbol then its name at
/// every mention.
///
/// The words live in the app target, which has no tests of its own, so this reads the sources and the
/// catalog as files. It is the Settings window's share of what the other apps of the family call
/// `LocalizationTests`.
final class SettingsWordsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The window and its pages. The onboarding, the menu and the notifications keep their own words.
    private static var windowFiles: [URL] {
        let folder = root.appendingPathComponent("App/Sources/UI")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { ($0.hasPrefix("Settings") || $0.hasPrefix("Health")) && $0.hasSuffix(".swift") }.sorted()
            .map { folder.appendingPathComponent($0) }
    }

    private static func keys(in file: URL) throws -> Set<String> {
        let source = try String(contentsOf: file, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"L\("((?:[^"\\]|\\.)+)"\)"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]).replacingOccurrences(of: #"\""#, with: "\"") }
        })
    }

    /// The catalog's French for every key it holds.
    private static func french() throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        var french: [String: String] = [:]
        for (key, value) in strings {
            let unit = ((value as? [String: Any])?["localizations"] as? [String: Any])?["fr"] as? [String: Any]
            let stringUnit = unit?["stringUnit"] as? [String: Any]
            if stringUnit?["state"] as? String == "translated", let text = stringUnit?["value"] as? String {
                french[key] = text
            }
        }
        return french
    }

    private func everyKey() throws -> Set<String> {
        let files = Self.windowFiles
        XCTAssertTrue(files.contains { $0.lastPathComponent == "SettingsHealthPage.swift" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "HealthWords.swift" })
        return try files.reduce(into: Set<String>()) { $0.formUnion(try Self.keys(in: $1)) }
    }

    func testEverySentenceOfTheWindowIsInTheCatalogInFrench() throws {
        let french = try Self.french()
        let keys = try everyKey()
        XCTAssertGreaterThan(keys.count, 100)
        for key in keys.sorted() {
            XCTAssertNotNil(french[key], "no French for “\(key)”")
        }
    }

    func testNoLongDashInEitherLanguage() throws {
        let french = try Self.french()
        let dashes = CharacterSet(charactersIn: "—–‒―‐‑−")
        for key in try everyKey() {
            XCTAssertNil(key.rangeOfCharacter(from: dashes), "long dash in “\(key)”")
            if let text = french[key] { XCTAssertNil(text.rangeOfCharacter(from: dashes), "long dash in “\(text)”") }
        }
    }

    func testAKeyIsItsSymbolThenItsName() throws {
        let french = try Self.french()
        let symbols = ["Fn": "🌐", "Option": "⌥", "Command": "⌘", "Commande": "⌘", "Control": "⌃",
                       "Contrôle": "⌃", "Shift": "⇧", "Majuscule": "⇧"]
        for key in try everyKey() {
            for text in [key, french[key]].compactMap({ $0 }) {
                for (name, symbol) in symbols {
                    let pattern = try NSRegularExpression(pattern: "\\b\(name)\\b")
                    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                        guard let range = Range(match.range, in: text) else { continue }
                        XCTAssertTrue(text[..<range.lowerBound].hasSuffix(symbol + " "),
                                      "“\(name)” without \(symbol) before it in “\(text)”")
                    }
                }
            }
        }
    }
}
