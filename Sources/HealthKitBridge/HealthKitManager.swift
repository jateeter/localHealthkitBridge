#if canImport(HealthKit)
import Foundation
import HealthKit

/// Owns HealthKit access: read-only authorization, anchored observers with
/// persisted anchors, background delivery, and aggregation of raw samples
/// into the three normalized ingest families.
///
/// The manager never writes HealthKit data and never persists raw samples;
/// the only egress is the `IngestSample` batches handed to `onBatch`.
@available(iOS 16.0, macOS 13.0, *)
public final class HealthKitManager: @unchecked Sendable {
    public typealias BatchHandler = @Sendable ([IngestSample]) -> Void

    private let store = HKHealthStore()
    private let anchors: AnchorStore
    private let queue = DispatchQueue(label: "healthkit-bridge.manager")
    private var activeQueries: [HKQuery] = []
    private let onBatch: BatchHandler

    public init(anchors: AnchorStore = AnchorStore(), onBatch: @escaping BatchHandler) {
        self.anchors = anchors
        self.onBatch = onBatch
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Types

    private static var quantity: (HKQuantityTypeIdentifier) -> HKQuantityType {
        { HKQuantityType.quantityType(forIdentifier: $0)! }
    }

    /// Read-only authorization set per the README.
    public static var readTypes: Set<HKObjectType> {
        [
            HKCorrelationType.correlationType(forIdentifier: .bloodPressure)!,
            quantity(.bloodPressureSystolic),
            quantity(.bloodPressureDiastolic),
            quantity(.heartRate),
            HKObjectType.workoutType(),
            quantity(.stepCount),
            quantity(.appleExerciseTime),
            quantity(.activeEnergyBurned),
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]
    }

    /// Sample types that drive anchored observers. Blood pressure observes the
    /// systolic component (correlation types do not support background
    /// delivery); the correlation is fetched on each trigger.
    static var observedTypes: [HKSampleType] {
        [
            quantity(.bloodPressureSystolic),
            HKObjectType.workoutType(),
            quantity(.stepCount),
            quantity(.appleExerciseTime),
            quantity(.activeEnergyBurned),
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]
    }

    // MARK: - Authorization

    public func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    // MARK: - Observers

    /// Starts one anchored observer per observed type and enables background
    /// delivery. Safe to call once per launch.
    public func startObservers() {
        for type in Self.observedTypes {
            startAnchoredQuery(for: type)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    public func stopObservers() {
        queue.sync {
            activeQueries.forEach(store.stop)
            activeQueries.removeAll()
        }
    }

    private func startAnchoredQuery(for type: HKSampleType) {
        let saved = anchors.anchorData(for: type.identifier).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, newAnchor, error in
            guard let self, error == nil else { return }
            if let newAnchor,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                self.anchors.save(data, for: type.identifier)
            }
            guard let samples, !samples.isEmpty else { return }
            self.queue.async { self.handleDelivery(for: type, samples: samples) }
        }
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: nil,
            anchor: saved,
            limit: HKObjectQueryNoLimit,
            resultsHandler: handler
        )
        query.updateHandler = handler
        queue.sync { activeQueries.append(query) }
        store.execute(query)
    }

    // MARK: - Family aggregation

    private func handleDelivery(for type: HKSampleType, samples: [HKSample]) {
        Task { [weak self] in
            guard let self else { return }
            var batch: [IngestSample] = []
            switch type.identifier {
            case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
                if let bp = await self.latestBloodPressureSample() { batch.append(bp) }
            case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
                if let sleep = await self.sleepSampleForLast24Hours() { batch.append(sleep) }
            default:
                if let exercise = await self.exerciseSampleForToday() { batch.append(exercise) }
            }
            if !batch.isEmpty { self.onBatch(batch) }
        }
    }

    /// Latest blood-pressure correlation → BP family sample. Pulse comes from
    /// the most recent heart-rate reading in the correlation's window, if any.
    func latestBloodPressureSample() async -> IngestSample? {
        let bpType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)!
        guard let correlation = await latestSample(of: bpType) as? HKCorrelation else { return nil }
        let mmHg = HKUnit.millimeterOfMercury()
        func component(_ id: HKQuantityTypeIdentifier) -> Double {
            let type = Self.quantity(id)
            let sample = correlation.objects(for: type).first as? HKQuantitySample
            return sample?.quantity.doubleValue(for: mmHg) ?? 0
        }
        let window = DateInterval(start: correlation.startDate.addingTimeInterval(-300),
                                  end: correlation.endDate.addingTimeInterval(300))
        let pulse = await averageQuantity(
            of: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            over: window
        ) ?? 0
        return SampleNormalizer.bloodPressure(
            systolicMmHg: component(.bloodPressureSystolic),
            diastolicMmHg: component(.bloodPressureDiastolic),
            pulseBpm: pulse,
            sourceName: correlation.sourceRevision.source.name
        )
    }

    /// Today's activity totals → exercise family sample.
    func exerciseSampleForToday() async -> IngestSample? {
        let now = Date()
        let interval = DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
        async let energy = sumQuantity(of: .activeEnergyBurned, unit: .kilocalorie(), over: interval)
        async let minutes = sumQuantity(of: .appleExerciseTime, unit: .minute(), over: interval)
        async let steps = sumQuantity(of: .stepCount, unit: .count(), over: interval)
        let (e, m, s) = await (energy, minutes, steps)
        guard e != nil || m != nil || s != nil else { return nil }
        return SampleNormalizer.exercise(
            activeEnergyKcal: e ?? 0,
            exerciseMinutes: m ?? 0,
            steps: s ?? 0
        )
    }

    /// Sleep-analysis samples from the last 24 h summed by stage → sleep family sample.
    func sleepSampleForLast24Hours() async -> IngestSample? {
        let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        let now = Date()
        let predicate = HKQuery.predicateForSamples(
            withStart: now.addingTimeInterval(-24 * 3600), end: now, options: .strictEndDate)
        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: results ?? [])
            }
            store.execute(query)
        }
        var total = 0.0, rem = 0.0, core = 0.0
        var sourceName: String?
        for case let sample as HKCategorySample in samples {
            guard let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  HKCategoryValueSleepAnalysis.allAsleepValues.contains(stage) else { continue }
            let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
            total += hours
            if stage == .asleepREM { rem += hours }
            if stage == .asleepCore { core += hours }
            sourceName = sourceName ?? sample.sourceRevision.source.name
        }
        guard total > 0 else { return nil }
        return SampleNormalizer.sleep(totalHours: total, remHours: rem, coreHours: core, sourceName: sourceName)
    }

    // MARK: - Query helpers

    private func latestSample(of type: HKSampleType) async -> HKSample? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: [sort]) { _, results, _ in
                continuation.resume(returning: results?.first)
            }
            store.execute(query)
        }
    }

    private func sumQuantity(of id: HKQuantityTypeIdentifier, unit: HKUnit, over interval: DateInterval) async -> Double? {
        await statistics(of: id, options: .cumulativeSum, over: interval) {
            $0.sumQuantity()?.doubleValue(for: unit)
        }
    }

    private func averageQuantity(of id: HKQuantityTypeIdentifier, unit: HKUnit, over interval: DateInterval) async -> Double? {
        await statistics(of: id, options: .discreteAverage, over: interval) {
            $0.averageQuantity()?.doubleValue(for: unit)
        }
    }

    private func statistics(
        of id: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        over interval: DateInterval,
        extract: @escaping @Sendable (HKStatistics) -> Double?
    ) async -> Double? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: interval.start, end: interval.end, options: .strictStartDate)
            let query = HKStatisticsQuery(
                quantityType: Self.quantity(id),
                quantitySamplePredicate: predicate,
                options: options
            ) { _, stats, _ in
                continuation.resume(returning: stats.flatMap(extract))
            }
            store.execute(query)
        }
    }
}
#endif
