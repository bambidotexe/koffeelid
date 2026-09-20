import XCTest
import KoffeeLidCore

final class UpdateCheckTests: XCTestCase {
    // MARK: ReleaseVersion parsing

    func testParsesVersionWithoutV() {
        XCTAssertEqual(ReleaseVersion(string: "1.0.5"), ReleaseVersion(1, 0, 5))
    }
    func testParsesVersionWithV() {
        XCTAssertEqual(ReleaseVersion(string: "v1.0.5"), ReleaseVersion(1, 0, 5))
    }
    func testRejectsNonNumeric() {
        XCTAssertNil(ReleaseVersion(string: "abc"))
    }
    func testRejectsEmpty() {
        XCTAssertNil(ReleaseVersion(string: ""))
    }
    func testMissingTrailingComponentsCountAsZero() {
        XCTAssertEqual(ReleaseVersion(string: "1.1"), ReleaseVersion(string: "1.1.0"))
    }
    func testNumericComparisonPerComponent() {
        XCTAssertTrue(ReleaseVersion(string: "1.0.10")! > ReleaseVersion(string: "1.0.9")!)
    }
    func testDisplayStringRoundTrips() {
        XCTAssertEqual(ReleaseVersion(string: "v1.0.5")!.displayString, "1.0.5")
    }

    // MARK: UpdateCheck.decide

    func testDecideUpToDateWhenEqual() {
        let latest = LatestRelease(version: ReleaseVersion(1, 0, 4), dmgURL: URL(string: "https://example.com/KoffeeLid-1.0.4.dmg")!)
        XCTAssertEqual(UpdateCheck.decide(current: "1.0.4", latest: latest), .upToDate)
    }
    func testDecideAvailableWhenNewer() {
        let latest = LatestRelease(version: ReleaseVersion(1, 0, 5), dmgURL: URL(string: "https://example.com/KoffeeLid-1.0.5.dmg")!)
        XCTAssertEqual(UpdateCheck.decide(current: "1.0.4", latest: latest), .available(latest))
    }
    func testDecideUpToDateWhenCurrentIsNewer() {
        let latest = LatestRelease(version: ReleaseVersion(1, 0, 3), dmgURL: URL(string: "https://example.com/KoffeeLid-1.0.3.dmg")!)
        XCTAssertEqual(UpdateCheck.decide(current: "1.0.4", latest: latest), .upToDate)
    }
    func testDecideUpToDateWhenCurrentIsUnparsable() {
        let latest = LatestRelease(version: ReleaseVersion(1, 0, 5), dmgURL: URL(string: "https://example.com/KoffeeLid-1.0.5.dmg")!)
        XCTAssertEqual(UpdateCheck.decide(current: "not-a-version", latest: latest), .upToDate)
    }

    // MARK: LatestRelease.parse

    func testParsePicksTheDmgAssetAndIgnoresOthers() {
        let json = """
        {
          "tag_name": "v1.0.5",
          "assets": [
            { "name": "KoffeeLid-1.0.5.zip", "browser_download_url": "https://example.com/KoffeeLid-1.0.5.zip" },
            { "name": "KoffeeLid-1.0.5.dmg", "browser_download_url": "https://example.com/KoffeeLid-1.0.5.dmg" }
          ]
        }
        """.data(using: .utf8)!
        let release = LatestRelease.parse(json)
        XCTAssertEqual(release?.version, ReleaseVersion(1, 0, 5))
        XCTAssertEqual(release?.dmgURL, URL(string: "https://example.com/KoffeeLid-1.0.5.dmg")!)
    }
    func testParseNilOnMalformedJSON() {
        let json = "not json".data(using: .utf8)!
        XCTAssertNil(LatestRelease.parse(json))
    }
    func testParseNilWhenNoDmgAsset() {
        let json = """
        {
          "tag_name": "v1.0.5",
          "assets": [
            { "name": "KoffeeLid-1.0.5.zip", "browser_download_url": "https://example.com/KoffeeLid-1.0.5.zip" }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertNil(LatestRelease.parse(json))
    }
    func testParseNilWhenTagNameMissing() {
        let json = """
        {
          "assets": [
            { "name": "KoffeeLid-1.0.5.dmg", "browser_download_url": "https://example.com/KoffeeLid-1.0.5.dmg" }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertNil(LatestRelease.parse(json))
    }
    func testParseReadsTheAssetsSizeAndDigest() {
        let json = """
        {
          "tag_name": "v1.0.5",
          "assets": [
            { "name": "KoffeeLid-1.0.5.dmg", "browser_download_url": "https://example.com/KoffeeLid-1.0.5.dmg",
              "size": 2777987, "digest": "sha256:287255244B42ed6affc836ae329832962e69a902a385f75e93a7450800e6b3db" }
          ]
        }
        """.data(using: .utf8)!
        let release = LatestRelease.parse(json)
        XCTAssertEqual(release?.dmgSize, 2_777_987)
        XCTAssertEqual(release?.dmgSHA256, "287255244b42ed6affc836ae329832962e69a902a385f75e93a7450800e6b3db")
    }
    func testParseLeavesSizeAndDigestOutWhenGitHubDoesNotStateThem() {
        let json = """
        { "tag_name": "v1.0.5", "assets": [ { "name": "K.dmg", "browser_download_url": "https://example.com/K.dmg" } ] }
        """.data(using: .utf8)!
        let release = LatestRelease.parse(json)
        XCTAssertNotNil(release)
        XCTAssertNil(release?.dmgSize)
        XCTAssertNil(release?.dmgSHA256)
    }
    func testParseIgnoresADigestThatIsNotSHA256() {
        let json = """
        { "tag_name": "v1.0.5", "assets": [ { "name": "K.dmg", "browser_download_url": "https://example.com/K.dmg",
          "digest": "md5:0123456789abcdef0123456789abcdef" } ] }
        """.data(using: .utf8)!
        XCTAssertNil(LatestRelease.parse(json)?.dmgSHA256)
    }
}
