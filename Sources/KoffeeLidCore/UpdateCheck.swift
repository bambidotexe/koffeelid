import Foundation

/// A dotted version ("1.0.5", optionally "v1.0.5"), compared numerically per component. A missing trailing
/// component counts as 0, so "1.1" == "1.1.0"; "1.0.10" > "1.0.9".
public struct ReleaseVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    public init(_ major: Int, _ minor: Int, _ patch: Int) { components = [major, minor, patch] }

    /// nil for an empty string or one with a non-numeric component.
    public init?(string: String) {
        var s = Substring(string)
        if s.first == "v" { s = s.dropFirst() }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            parsed.append(n)
        }
        components = parsed
    }

    /// "1.0.5", as parsed (no "v", not padded).
    public var displayString: String { components.map(String.init).joined(separator: ".") }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.padded(to: max(lhs.components.count, rhs.components.count)) == rhs.padded(to: max(lhs.components.count, rhs.components.count))
    }
    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }
    private func padded(to count: Int) -> [Int] { components + Array(repeating: 0, count: max(0, count - components.count)) }
}

/// The GitHub `/releases/latest` response, reduced to what the app needs. The asset's length and SHA-256 are
/// GitHub's own statement about the file it serves: the length sizes the progress bar when the download's
/// response carries none, and the digest is what a finished download is held against.
public struct LatestRelease: Equatable, Sendable {
    public let version: ReleaseVersion
    public let dmgURL: URL
    public let dmgSize: Int64?
    /// 64 lowercase hex digits, or nil when GitHub states no SHA-256 for the asset.
    public let dmgSHA256: String?

    public init(version: ReleaseVersion, dmgURL: URL, dmgSize: Int64? = nil, dmgSHA256: String? = nil) {
        self.version = version; self.dmgURL = dmgURL; self.dmgSize = dmgSize; self.dmgSHA256 = dmgSHA256
    }

    private struct DTO: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64?; let digest: String? }
        let tag_name: String?
        let assets: [Asset]?
    }

    /// nil on malformed JSON, a missing `tag_name`, an unparsable tag, or no asset ending in ".dmg".
    public static func parse(_ data: Data) -> LatestRelease? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let tag = dto.tag_name, let version = ReleaseVersion(string: tag),
              let dmg = dto.assets?.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: dmg.browser_download_url)
        else { return nil }
        return LatestRelease(version: version, dmgURL: url, dmgSize: dmg.size.flatMap { $0 > 0 ? $0 : nil }, dmgSHA256: sha256(in: dmg.digest))
    }

    /// GitHub writes an asset's digest as "sha256:<hex>".
    private static func sha256(in digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(LatestRelease)
}

public enum UpdateCheck {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/bambidotexe/koffeelid/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/bambidotexe/koffeelid/releases/latest")!

    /// `available` only when `latest` is strictly newer than `current`; an unparsable `current` (or an equal
    /// or older release) is `upToDate`.
    public static func decide(current: String, latest: LatestRelease) -> UpdateDecision {
        guard let currentVersion = ReleaseVersion(string: current), latest.version > currentVersion else { return .upToDate }
        return .available(latest)
    }
}
