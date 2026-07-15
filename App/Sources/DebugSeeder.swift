#if DEBUG
import Foundation
import HealthKit
import HealthKitBridge

/// Test-only seeding path (roadmap M4): writes one nominal sample per family
/// so the anchored observers fire against real store data.  Compiled out of
/// release builds — the shipped app stays strictly read-only, matching the
/// NSHealthUpdateUsageDescription privacy string.
enum DebugSeeder {
    static func seed(store: HKHealthStore) async throws {
        let systolic = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic)!
        let diastolic = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic)!
        let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!

        // One combined sheet covers the bridge's read set and the seeder's
        // write set, so the UI test only has to accept once.
        try await store.requestAuthorization(
            toShare: [systolic, diastolic, heartRate, steps, energy, sleep],
            read: HealthKitManager.readTypes
        )

        let now = Date()
        let bpDate = now.addingTimeInterval(-300)
        let mmHg = HKUnit.millimeterOfMercury()
        let sys = HKQuantitySample(type: systolic, quantity: HKQuantity(unit: mmHg, doubleValue: 120), start: bpDate, end: bpDate)
        let dia = HKQuantitySample(type: diastolic, quantity: HKQuantity(unit: mmHg, doubleValue: 78), start: bpDate, end: bpDate)
        let bp = HKCorrelation(
            type: HKCorrelationType.correlationType(forIdentifier: .bloodPressure)!,
            start: bpDate, end: bpDate, objects: [sys, dia]
        )
        let pulse = HKQuantitySample(
            type: heartRate,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 64),
            start: bpDate, end: bpDate
        )
        let stepsSample = HKQuantitySample(
            type: steps, quantity: HKQuantity(unit: .count(), doubleValue: 6100),
            start: now.addingTimeInterval(-3600), end: now
        )
        let energySample = HKQuantitySample(
            type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 320),
            start: now.addingTimeInterval(-3600), end: now
        )
        let sleepStart = now.addingTimeInterval(-9 * 3600)
        let core = HKCategorySample(
            type: sleep, value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: sleepStart, end: sleepStart.addingTimeInterval(4 * 3600)
        )
        let rem = HKCategorySample(
            type: sleep, value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            start: sleepStart.addingTimeInterval(4 * 3600), end: sleepStart.addingTimeInterval(5.6 * 3600)
        )
        try await store.save([bp, pulse, stepsSample, energySample, core, rem])
    }
}
#endif
