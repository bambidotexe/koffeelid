import Foundation

/// French elides "que" into "qu’" before a word that starts with a vowel sound: "tant que une commande"
/// is never written that way. The menu's auto-arm line is built from four French templates whose `%@` can
/// hold either kind of word ("Codex", "une commande", "OpenCode"), so the elision is applied to the built
/// line rather than baked into the templates. Pure text transform; the caller decides when French applies.
public enum FrenchElision {
    /// a e i o u y, upper or lower case, and their accented forms — the vowels that trigger elision.
    private static let vowels: Set<Character> = Set("aeiouyAEIOUYàâäéèêëïîôöùûüÿÀÂÄÉÈÊËÏÎÔÖÙÛÜŸ")
    /// The same apostrophe the catalog's other elisions use ("n’ont", "l’écran": U+2019, not the straight `'`).
    private static let apostrophe = "\u{2019}"
    /// The whole word "que" only: never a longer word that merely ends in "que" ("bibliothèque").
    private static let regex = try! NSRegularExpression(pattern: "\\bque \\b")

    /// `text` with every standalone "que " immediately followed by a vowel-initial word turned into "qu’".
    public static func elideQue(in text: String) -> String {
        var result = ""
        var searchStart = text.startIndex
        while let match = regex.firstMatch(in: text, range: NSRange(searchStart..<text.endIndex, in: text)),
              let matchRange = Range(match.range, in: text) {
            result += text[searchStart..<matchRange.lowerBound]
            let after = text[matchRange.upperBound...]
            if let first = after.first, vowels.contains(first) {
                result += "qu" + apostrophe
            } else {
                result += text[matchRange]
            }
            searchStart = matchRange.upperBound
        }
        result += text[searchStart...]
        return result
    }
}
