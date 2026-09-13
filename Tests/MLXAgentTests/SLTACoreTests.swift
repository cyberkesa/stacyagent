import XCTest
@testable import SLTACore

final class SLTACoreTests: XCTestCase {
    func testErrorDescription() {
        XCTAssertEqual(SLTAError.fileNotFound("a.txt").description, "file not found: a.txt")
        XCTAssertEqual(SLTAError.cli("oops").description, "oops")
        XCTAssertTrue(SLTAError.invalidOption("x").errorDescription?.contains("x") == true)
    }

    func testLimitsDefaults() {
        let l = SLTALimits()
        XCTAssertEqual(l.listDirMaxEntries, 300)
        XCTAssertEqual(l.fileMaxBytes, 1_500_000)
        XCTAssertEqual(l.searchTimeoutSeconds, 20)
        XCTAssertEqual(l.swiftcTimeoutSeconds, 60)
    }

    func testLimitsFromEnv() {
        let l = SLTALimits.fromEnvironment()
        XCTAssertGreaterThan(l.fileMaxBytes, 0)
    }
}
