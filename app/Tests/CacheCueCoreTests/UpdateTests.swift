import XCTest

@testable import CacheCueCore

final class UpdateTests: XCTestCase {
    func testVersions() {
        XCTAssertEqual(AppVersion("v1.0.3")?.parts, [1, 0, 3])
        XCTAssertEqual(AppVersion("1.0.3")?.description, "1.0.3")
        XCTAssertNil(AppVersion("dev"))
        XCTAssertNil(AppVersion("1.0.3-beta"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..3"))
        XCTAssertTrue(AppVersion("1.0.9")! < AppVersion("1.0.10")!)
        XCTAssertTrue(AppVersion("1.9.9")! < AppVersion("2.0.0")!)
        XCTAssertTrue(AppVersion("1.0")! < AppVersion("1.0.1")!)
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertFalse(AppVersion("1.0.3")! < AppVersion("1.0.3")!)
    }

    func release(_ tag: String, url: String = "https://github.com/MinLi999/CacheCue/releases/tag/v1.0.4") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url, "name": "x", "draft": false])
    }

    func testTellsOfANewerReleaseOnly() {
        XCTAssertEqual(UpdateCheck.update(from: release("v1.0.4"), running: "1.0.3")?.version.description, "1.0.4")
        XCTAssertEqual(
            UpdateCheck.update(from: release("v1.0.4"), running: "1.0.3")?.page.absoluteString,
            "https://github.com/MinLi999/CacheCue/releases/tag/v1.0.4")
        XCTAssertNil(UpdateCheck.update(from: release("v1.0.3"), running: "1.0.3"))
        XCTAssertNil(UpdateCheck.update(from: release("v1.0.2"), running: "1.0.3"))
        // A local build has no release version and is never nagged.
        XCTAssertNil(UpdateCheck.update(from: release("v9.0.0"), running: "dev"))
    }

    func testIgnoresAnAnswerThatIsNotARelease() {
        XCTAssertNil(UpdateCheck.release(from: Data()))
        XCTAssertNil(UpdateCheck.release(from: Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(UpdateCheck.release(from: release("nightly")))
        // The link is opened in a browser, so it must be a page on GitHub and nothing else.
        XCTAssertNil(UpdateCheck.release(from: release("v2.0.0", url: "https://example.com/CacheCue.dmg")))
        XCTAssertNil(UpdateCheck.release(from: release("v2.0.0", url: "file:///Applications")))
    }

    func testChecksOnceADay() {
        let now = Date(timeIntervalSince1970: 1_791_750_000)
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertEqual(UpdateCheck.endpoint.absoluteString, "https://api.github.com/repos/MinLi999/CacheCue/releases/latest")
    }
}
