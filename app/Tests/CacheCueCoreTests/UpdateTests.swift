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
}
