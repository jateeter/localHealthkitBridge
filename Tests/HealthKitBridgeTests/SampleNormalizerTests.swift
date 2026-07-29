import XCTest
@testable import HealthKitBridge

final class SampleNormalizerTests: XCTestCase {

    func testBloodPressureNominal() {
        let sample = SampleNormalizer.bloodPressure(
            systolicMmHg: 144, diastolicMmHg: 57.6, pulseBpm: 48, confidence: 0.99)
        XCTAssertEqual(sample.type, "HKCorrelationTypeIdentifierBloodPressure")
        XCTAssertEqual(sample.unit, "mm[Hg]")
        XCTAssertEqual(sample.values[0], 0.72, accuracy: 1e-9)
        XCTAssertEqual(sample.values[1], 0.48, accuracy: 1e-9)
        XCTAssertEqual(sample.values[2], 0.24, accuracy: 1e-9)
        XCTAssertEqual(sample.values[3], 0.99, accuracy: 1e-9)
        XCTAssertEqual(sample.sourceMappingId, "healthkit:HKCorrelationTypeIdentifierBloodPressure")
        XCTAssertEqual(sample.metadata?["fhirCode"], "85354-9")
    }

    func testValuesClampToUnitInterval() {
        let high = SampleNormalizer.bloodPressure(
            systolicMmHg: 500, diastolicMmHg: -20, pulseBpm: 1000, confidence: 3)
        XCTAssertEqual(high.values, [1, 0, 1, 1])
    }

    func testNonFiniteValuesBecomeZero() {
        let sample = SampleNormalizer.exercise(
            activeEnergyKcal: .nan, exerciseMinutes: .infinity, steps: 5000)
        XCTAssertEqual(sample.values[0], 0)
        XCTAssertEqual(sample.values[1], 0)
        XCTAssertEqual(sample.values[2], 0.5, accuracy: 1e-9)
    }

    func testExerciseNominal() {
        let sample = SampleNormalizer.exercise(
            activeEnergyKcal: 1950, exerciseMinutes: 69.6, steps: 4200, confidence: 0.97)
        XCTAssertEqual(sample.type, "HKWorkoutTypeIdentifierWorkout")
        XCTAssertEqual(sample.values[0], 0.65, accuracy: 1e-9)
        XCTAssertEqual(sample.values[1], 0.58, accuracy: 1e-9)
        XCTAssertEqual(sample.values[2], 0.42, accuracy: 1e-9)
        XCTAssertEqual(sample.values[3], 0.97, accuracy: 1e-9)
        XCTAssertEqual(sample.sourceMappingId, "healthkit:HKWorkoutTypeIdentifierWorkout")
    }

    func testSleepFractionsAreOfTotalSleep() {
        let sample = SampleNormalizer.sleep(totalHours: 8.2, remHours: 0.984, coreHours: 1.476)
        XCTAssertEqual(sample.type, "HKCategoryTypeIdentifierSleepAnalysis")
        XCTAssertEqual(sample.values[0], 0.82, accuracy: 1e-9)
        XCTAssertEqual(sample.values[1], 0.12, accuracy: 1e-9)
        XCTAssertEqual(sample.values[2], 0.18, accuracy: 1e-9)
        XCTAssertEqual(sample.sourceMappingId, "healthkit:HKCategoryTypeIdentifierSleepAnalysis")
    }

    func testExplicitSourceMappingCanBeOverriddenOrOmitted() {
        let overridden = SampleNormalizer.exercise(
            activeEnergyKcal: 100,
            exerciseMinutes: 20,
            steps: 500,
            sourceMappingId: "healthkit:HKWorkoutTypeIdentifierWorkout:Apple Watch"
        )
        XCTAssertEqual(overridden.sourceMappingId, "healthkit:HKWorkoutTypeIdentifierWorkout:Apple Watch")

        let inferredOnly = SampleNormalizer.sleep(
            totalHours: 7,
            remHours: 1,
            coreHours: 4,
            sourceMappingId: nil
        )
        XCTAssertNil(inferredOnly.sourceMappingId)
    }

    func testZeroSleepYieldsZeroFractions() {
        let sample = SampleNormalizer.sleep(totalHours: 0, remHours: 2, coreHours: 3)
        XCTAssertEqual(sample.values[0], 0)
        XCTAssertEqual(sample.values[1], 0)
        XCTAssertEqual(sample.values[2], 0)
    }

    func testRawValuesRetainedInMetadata() {
        let sample = SampleNormalizer.bloodPressure(systolicMmHg: 120, diastolicMmHg: 80, pulseBpm: 60)
        XCTAssertEqual(sample.metadata?["rawSystolicMmHg"], "120.0")
        XCTAssertEqual(sample.metadata?["rawDiastolicMmHg"], "80.0")
    }
}
