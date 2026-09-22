import XCTest
@testable import HealthKitBridge

final class HealthMetricSnapshotTests: XCTestCase {
    func testFamiliesHaveStableOwnerFacingTitles() {
        XCTAssertEqual(HealthMetricSnapshot.Family.allCases, [.bloodPressure, .exercise, .sleep])
        XCTAssertEqual(HealthMetricSnapshot.Family.bloodPressure.title, "Blood pressure")
        XCTAssertEqual(HealthMetricSnapshot.Family.exercise.title, "Activity")
        XCTAssertEqual(HealthMetricSnapshot.Family.sleep.title, "Sleep")
    }

    func testSnapshotIdentityIsItsFamilyAndPreservesProvenance() {
        let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = HealthMetricSnapshot(
            family: .exercise,
            primaryValue: "6,100 steps",
            secondaryValue: "42 min · 320 kcal",
            sourceName: "Apple Health",
            measuredAt: measuredAt
        )

        XCTAssertEqual(snapshot.id, .exercise)
        XCTAssertEqual(snapshot.sourceName, "Apple Health")
        XCTAssertEqual(snapshot.measuredAt, measuredAt)
        XCTAssertFalse(snapshot.isTestData)
    }
}
