import XCTest
@testable import StacyAgentCore

final class StacyAgentCoreTests: XCTestCase {
    func testErrorDescription() {
        XCTAssertEqual(StacyAgentError.fileNotFound("a.txt").description, "file not found: a.txt")
        XCTAssertEqual(StacyAgentError.cli("oops").description, "oops")
        XCTAssertTrue(StacyAgentError.invalidOption("x").errorDescription?.contains("x") == true)
    }

    func testLimitsDefaults() {
        let l = StacyAgentLimits()
        XCTAssertEqual(l.listDirMaxEntries, 300)
        XCTAssertEqual(l.fileMaxBytes, 1_500_000)
        XCTAssertEqual(l.searchTimeoutSeconds, 20)
        XCTAssertEqual(l.swiftcTimeoutSeconds, 60)
    }

    func testLimitsFromEnv() {
        let l = StacyAgentLimits.fromEnvironment()
        XCTAssertGreaterThan(l.fileMaxBytes, 0)
    }
}
