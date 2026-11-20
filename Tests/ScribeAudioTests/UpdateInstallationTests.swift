import XCTest
@testable import Scribe

@MainActor
final class UpdateInstallationTests: XCTestCase {
    func testRestartWaitsForActiveWorkAndResumesExactlyOnce() {
        let gate = UpdateInstallationGate()
        var installations = 0
        gate.isBusy = true
        XCTAssertTrue(gate.postpone { installations += 1 })
        XCTAssertEqual(installations, 0)
        gate.isBusy = true // Another recording/processing state notification.
        XCTAssertEqual(installations, 0)
        gate.isBusy = false
        XCTAssertEqual(installations, 1)
        gate.isBusy = false
        gate.isBusy = true
        gate.isBusy = false
        XCTAssertEqual(installations, 1)
    }

    func testIdleAppLetsSparkleInstallImmediatelyWithoutRetainingTheHandler() {
        let gate = UpdateInstallationGate()
        var called = false
        XCTAssertFalse(gate.postpone { called = true })
        gate.isBusy = true
        gate.isBusy = false
        XCTAssertFalse(called)
    }
}
