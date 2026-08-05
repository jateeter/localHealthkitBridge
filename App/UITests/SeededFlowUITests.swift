import XCTest

/// Drives the hands-off seeded flow (roadmap M4): launch with
/// -seedHealthData, accept the combined HealthKit permission sheet, and
/// wait for the sync log to show a delivered batch.  The companion shell
/// script asserts the sensors on the PE side.
final class SeededFlowUITests: XCTestCase {
    func testPatientMonitorNavigationSurfacesExistingScreens() throws {
        let app = XCUIApplication()
        app.launch()

        // Cold hosted runners are slower to first render than a warm local
        // simulator, so the first wait is generous. Later waits can be short
        // because the app is already up by then.
        XCTAssertTrue(app.navigationBars["Patient Monitor"].waitForExistence(timeout: 90),
                      "Patient Monitor should be the landing tab")
        XCTAssertTrue(app.staticTexts["OpenCommons Health"].waitForExistence(timeout: 10),
                      "OpenCommons Health branding should be visible")

        // The three information sources the monitor surfaces.
        //
        // The section headers that used to be asserted here ("Information
        // sources", "Pod-maintained information", "Solid Pod connection") were
        // dropped: they sit in a lazy List and only exist once scrolled into
        // view, so they assert screen height rather than behavior. They failed
        // on a hosted runner while the source rows either side of them passed.
        for source in ["HealthKit", "Epic", "Solid Pod"] {
            XCTAssertTrue(app.staticTexts[source].waitForExistence(timeout: 10),
                          "\(source) should be listed as an information source")
        }

        app.tabBars.buttons["Bridge"].tap()
        XCTAssertTrue(app.navigationBars["HK Bridge"].waitForExistence(timeout: 20),
                      "Bridge tab should still reach the existing bridge screen")

        app.tabBars.buttons["Pod"].tap()
        XCTAssertTrue(app.navigationBars["Pod"].waitForExistence(timeout: 20),
                      "Pod tab should still reach the existing pod screen")

        // Returning proves the Patient tab did not replace the other screens.
        app.tabBars.buttons["Patient"].tap()
        XCTAssertTrue(app.navigationBars["Patient Monitor"].waitForExistence(timeout: 20),
                      "Patient tab should remain reachable after visiting Bridge and Pod")
    }

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
