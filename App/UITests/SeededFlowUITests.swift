import XCTest

/// Drives the hands-off seeded flow (roadmap M4): launch with
/// -seedHealthData, accept the combined HealthKit permission sheet, and
/// wait for the sync log to show a delivered batch.  The companion shell
/// script asserts the sensors on the PE side.
final class SeededFlowUITests: XCTestCase {
    func testSeededDeliveryReachesPE() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-seedHealthData", "1",
            "-peBaseURL", env["PE_BASE_URL"] ?? "http://127.0.0.1:3499",
        ]
        if let token = env["HEALTHKIT_BRIDGE_TOKEN"], !token.isEmpty {
            app.launchArguments += ["-bridgeToken", token]
        }
        app.launch()

        // HealthKit permission sheet (remote view controller, surfaced in
        // the app's hierarchy). "Turn On All" enables every row; the confirm
        // control is the bottom pinned UIA.Health.Allow.Button on iOS 26
        // (older runtimes used a nav-bar "Allow" button — match either).
        let turnOnAll = app.staticTexts["Turn On All"]
        if turnOnAll.waitForExistence(timeout: 20) {
            turnOnAll.tap()
            let allow = app.buttons.matching(NSPredicate(
                format: "identifier == 'UIA.Health.Allow.Button' OR label == 'Allow'"
            )).firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 10), "Allow button not found on HK sheet")
            allow.tap()
        }

        // Observers fire on the seeded samples and the coordinator logs
        // "HTTP 200 → <sensorIds>" per delivered batch.
        let delivered = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'HTTP 2'"))
            .firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 60), "no delivered batch appeared in the sync log")
    }
}
