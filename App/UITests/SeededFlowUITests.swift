import XCTest

/// Drives the hands-off seeded flow (roadmap M4): launch with
/// -seedHealthData, accept the combined HealthKit permission sheet, and
/// wait for the sync log to show a delivered batch.  The companion shell
/// script asserts the sensors on the PE side.
final class SeededFlowUITests: XCTestCase {
    func testPodHydrationFallbackIsVisibleWhenNotSynchronized() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-clearPodHydrationCache", "1",
            "-localPIMBaseURL", "http://127.0.0.1:1",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.descendants(matching: .any)["PodSynchronizationStatus"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'Pod data has not been synchronized.'")
            ).firstMatch.waitForExistence(timeout: 10),
            "An unavailable PIM with no cache should show the unsynchronized fallback"
        )
    }

    func testStatusButtonsOpenResolutionPaths() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 90))

        let epicStatus = app.buttons["ResolveSourceStatus-Epic"]
        scrollUntilVisible(epicStatus, in: app, maxSwipes: 12)
        XCTAssertTrue(epicStatus.waitForExistence(timeout: 10))
        epicStatus.tap()
        XCTAssertTrue(app.navigationBars["Reconcile"].waitForExistence(timeout: 10))

        let appleHealthStatus = app.buttons["ResolveConnectionStatus-Apple Health"]
        XCTAssertTrue(appleHealthStatus.waitForExistence(timeout: 10))
        appleHealthStatus.tap()
        XCTAssertTrue(app.navigationBars["Scan Results"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Overview"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))

        let healthKitStatus = app.buttons["ResolveSourceStatus-HealthKit"]
        scrollUntilVisible(healthKitStatus, in: app, maxSwipes: 12)
        XCTAssertTrue(healthKitStatus.waitForExistence(timeout: 10))
        healthKitStatus.tap()
        XCTAssertTrue(app.descendants(matching: .any)["BridgeOperationsView"].waitForExistence(timeout: 10))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
        tapPatientDomain("vital-signs", in: app)
        let domainStatus = app.buttons["ResolveDomainStatus-vital-signs"]
        XCTAssertTrue(domainStatus.waitForExistence(timeout: 10))
        domainStatus.tap()
        XCTAssertTrue(app.descendants(matching: .any)["SemanticElementEntryModal"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
    }

    func testAllElevenPillarsOpenInteractiveDetailGraphs() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 90))

        let pillars = [
            "profiles", "conditions", "medications", "allergies", "immunizations",
            "vital-signs", "providers", "lab-results", "insurance-policies", "documents",
            "workflow-tasks",
        ]

        for pillarID in pillars {
            let row = app.buttons["PatientDomain-\(pillarID)"]
            scrollUntilVisible(row, in: app, maxSwipes: 16)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Pillar row \(pillarID) should be reachable")
            row.tap()

            XCTAssertTrue(
                app.descendants(matching: .any)["ActiveSpiderGraph-\(pillarID)"].waitForExistence(timeout: 10),
                "Pillar detail \(pillarID) should render its active spider graph"
            )
            XCTAssertTrue(
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'SemanticNode-'")).firstMatch.waitForExistence(timeout: 10),
                "Pillar detail \(pillarID) should expose selectable semantic nodes"
            )

            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        }
    }

    func testPatientMonitorNavigationSurfacesExistingScreens() throws {
        let app = XCUIApplication()
        app.launch()

        // Cold hosted runners are slower to first render than a warm local
        // simulator, so the first wait is generous. Later waits can be short
        // because the app is already up by then.
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 90),
                      "Overview should be the landing tab")
        XCTAssertTrue(app.staticTexts["OCH-100 CENTRAL"].waitForExistence(timeout: 10),
                      "OpenCommons Health system badge should be visible")
        XCTAssertTrue(app.descendants(matching: .any)["WellnessSpiderGraph"].waitForExistence(timeout: 10),
                      "Wellness landing should expose the same spider graph entry point as the PIM")
        XCTAssertTrue(app.buttons["PatientOwnerMenu"].waitForExistence(timeout: 10),
                      "Top-right owner menu should be visible and initially closed")

        // The three information sources the monitor surfaces.
        //
        // The section headers that used to be asserted here ("Information
        // sources", "Pod-maintained information", "Solid Pod connection") were
        // dropped: they sit in a lazy List and only exist once scrolled into
        // view, so they assert screen height rather than behavior. They failed
        // on a hosted runner while the source rows either side of them passed.
        for source in ["HealthKit", "Epic", "Solid Pod"] {
            let sourceLabel = app.staticTexts[source]
            scrollUntilVisible(sourceLabel, in: app)
            XCTAssertTrue(sourceLabel.waitForExistence(timeout: 10),
                          "\(source) should be listed as an information source")
        }

        app.swipeDown()

        tapPatientDomain("vital-signs", in: app)
        XCTAssertTrue(app.navigationBars["Physical Health Detail"].waitForExistence(timeout: 20),
                      "Physical Health should open the Figma-aligned metric detail view")

        for nodeID in ["blood-pressure", "heart-rate", "body-temperature", "oxygen-saturation", "body-weight", "bmi"] {
            XCTAssertTrue(app.buttons["SemanticNode-\(nodeID)"].waitForExistence(timeout: 10),
                          "Vital signs graph should expose PIM contract node \(nodeID)")
        }

        let heartRateNode = app.buttons["SemanticNode-heart-rate"]
        XCTAssertTrue(heartRateNode.waitForExistence(timeout: 10),
                      "Heart rate node should be selectable")
        heartRateNode.tap()

        XCTAssertTrue(app.otherElements["SemanticElementSummaryTable"].waitForExistence(timeout: 10),
                      "Selecting a node should show its current data summary")
        app.buttons["SemanticElementAddButton"].tap()
        XCTAssertTrue(app.navigationBars["New Physical Health Record"].waitForExistence(timeout: 10),
                      "Add should open the Figma-aligned data entry sheet")
        XCTAssertTrue(app.staticTexts["LOINC 8867-4"].waitForExistence(timeout: 10),
                      "Add modal should expose the PIM/FHIR coding context")
        app.buttons["Cancel"].tap()
        app.navigationBars["Physical Health Detail"].buttons.firstMatch.tap()

        let dailyTimeline = app.descendants(matching: .any)["DailyTimeline"]
        scrollUntilVisible(dailyTimeline, in: app)
        XCTAssertTrue(dailyTimeline.waitForExistence(timeout: 10),
                      "Patient monitor should expose the daily timeline")
        XCTAssertTrue(app.descendants(matching: .any)["DailyActivity-morning-medications"].waitForExistence(timeout: 10),
                      "Default daily plan should start with the morning medication regimen")

        let bridgeControls = app.buttons["Open HealthKit Bridge controls"]
        scrollUntilVisible(bridgeControls, in: app)
        bridgeControls.tap()
        XCTAssertTrue(app.navigationBars["HK Bridge"].waitForExistence(timeout: 20),
                      "Overview actions should still reach the existing bridge screen")
        let metricsSection = app.staticTexts["Apple Health metrics"]
        scrollUntilVisible(metricsSection, in: app)
        XCTAssertTrue(metricsSection.waitForExistence(timeout: 10),
                      "Bridge controls should expose owner-authorized Apple Health summaries")
        XCTAssertTrue(app.buttons["RefreshHealthMetricsButton"].waitForExistence(timeout: 10),
                      "Bridge controls should expose a manual Apple Health snapshot refresh")
        app.navigationBars["HK Bridge"].buttons.firstMatch.tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20),
                      "Settings tab should still reach the existing Pod screen")
        let podTermsLink = app.descendants(matching: .any)["PodTermsLink"]
        scrollUntilVisible(podTermsLink, in: app)
        XCTAssertTrue(podTermsLink.waitForExistence(timeout: 10),
                      "Pod screen should expose Terms")
        let podDisclosureLink = app.descendants(matching: .any)["PodDataDisclosureLink"]
        scrollUntilVisible(podDisclosureLink, in: app)
        XCTAssertTrue(podDisclosureLink.waitForExistence(timeout: 10),
                      "Pod screen should expose Data Disclosure")

        // Returning proves the Overview tab did not replace the other screens.
        app.tabBars.buttons["Overview"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20),
                      "Overview tab should remain reachable after visiting Bridge and Settings")
    }

    func testSeededDeliveryReachesPE() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-seedHealthData", "1",
            "-peBaseURL", env["PE_BASE_URL"] ?? "http://127.0.0.1:3499",
        ]
        if let token = env["HEALTHKIT_BRIDGE_TOKEN"], !token.isEmpty {
            app.launchEnvironment["HEALTHKIT_BRIDGE_TOKEN"] = token
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

    private func tapPatientDomain(_ id: String, in app: XCUIApplication) {
        let row = app.buttons["PatientDomain-\(id)"]
        let maxSwipes = 6
        for _ in 0..<maxSwipes where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Patient domain \(id) should be reachable")
        row.tap()
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }
}
