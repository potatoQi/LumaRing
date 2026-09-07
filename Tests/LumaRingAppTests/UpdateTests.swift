import XCTest
import Sparkle
@testable import LumaRing

final class UpdateTests: XCTestCase {
    func configuration(_ url: String, key: String = Data(repeating: 7, count: 32).base64EncodedString()) -> [String: Any] {
        ["SUFeedURL": url, "SUPublicEDKey": key]
    }
    func testConfiguredGitHubFeedRequiresValidPublicKeyAndHTTPS() {
        let url = "https://github.com/potatoQi/LumaRing/releases/latest/download/appcast.xml"
        XCTAssertNotNil(UpdateConfiguration(info: configuration(url)))
        XCTAssertNil(UpdateConfiguration(info: configuration(url, key: "not a public key")))
        XCTAssertNil(UpdateConfiguration(info: configuration(url, key: Data(repeating: 7, count: 31).base64EncodedString())))
        for rejected in [url.replacingOccurrences(of: "https:", with: "http:"),
                         url.replacingOccurrences(of: "github.com", with: "github.com.example.org"),
                         url.replacingOccurrences(of: "https://", with: "https://user:password@"),
                         url + "?token=example", url + "#fragment", "https://github.com/potatoQi/LumaRing"] {
            XCTAssertNil(UpdateConfiguration(info: configuration(rejected)), rejected)
        }
    }
    func testVersionComparisonUsesNumericOwnerSelectedVersions() {
        let comparator = SUStandardVersionComparator.default
        XCTAssertEqual(comparator.compareVersion("0.1.0", toVersion: "0.1.0"), .orderedSame)
        XCTAssertEqual(comparator.compareVersion("0.1.0", toVersion: "0.2.0"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("0.9.0", toVersion: "0.10.0"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("0.2.0", toVersion: "0.1.9"), .orderedDescending)
    }
    @MainActor func testDevelopmentTestBundleDoesNotStartMisconfiguredUpdater() async {
        let updates = UpdateService()
        updates.start()
        XCTAssertFalse(updates.canCheck)
        XCTAssertNotNil(updates.configurationMessage)
    }
}
