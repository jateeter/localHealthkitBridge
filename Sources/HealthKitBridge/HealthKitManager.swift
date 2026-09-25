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
    public typealias EventHandler = @Sendable (HealthKitRuntimeEvent) -> Void

    private struct FamilyReading {
        let sample: IngestSample
        let snapshot: HealthMetricSnapshot
    }

    private let store = HKHealthStore()
    private let anchors: AnchorStore
    private let queue = DispatchQueue(label: "healthkit-bridge.manager")
    private var activeQueries: [HKQuery] = []
    private let onBatch: BatchHandler
    private let onEvent: EventHandler
    /// Awaitable delivery for the background observer path: the observer's
    /// completion handler is called only after the attempt, so iOS does not
    /// suspend the app mid-request. Falls back to `onBatch` when not supplied.
    private let deliver: (@Sendable ([IngestSample]) async -> Void)?

    public init(
        anchors: AnchorStore = AnchorStore(),
        onBatch: @escaping BatchHandler,
        onEvent: @escaping EventHandler = { _ in },
        deliver: (@Sendable ([IngestSample]) async -> Void)? = nil
    ) {
        self.anchors = anchors
        self.onBatch = onBatch
        self.onEvent = onEvent
        self.deliver = deliver
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Types

    private static var quantity: (HKQuantityTypeIdentifier) -> HKQuantityType {
        { HKQuantityType.quantityType(forIdentifier: $0)! }
    }

    /// Read-only authorization set per the README.  Note: the blood-pressure
    /// correlation type must NOT appear here — HealthKit raises
    /// NSInvalidArgumentException when authorization is requested for a
    /// correlation type; authorizing the component quantities is sufficient
    /// to query the correlation.
    public static var readTypes: Set<HKObjectType> {
        [
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

    /// Returns whether HealthKit still needs to present an authorization
    /// request. HealthKit intentionally does not reveal per-type read denial;
    /// `.unnecessary` means the owner has already answered the request.
    public func authorizationRequestIsNecessary() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status == .shouldRequest)
                }
            }
        }
    }

    // MARK: - Observers

    /// Starts one anchored observer per observed type and enables background
    /// delivery. Safe to call once per launch.
    public func startObservers() {
        for type in Self.observedTypes {
            startAnchoredQuery(for: type)
            startObserverQuery(for: type)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { [weak self] _, error in
                if let error {
                    self?.onEvent(.queryFailed(typeIdentifier: type.identifier, message: error.localizedDescription))
                }
            }
        }
    }

    /// Reads the latest owner-authorized values even when anchored observers
    /// have already consumed older samples. The resulting normalized samples
    /// are delivered through the same audited PE path as observer updates.
    public func refreshSnapshot() async {
        async let bloodPressure = bloodPressureReading()
        async let exercise = exerciseReading()
        async let sleep = sleepReading()
        let readings = await [bloodPressure, exercise, sleep].compactMap { $0 }
        let present = Set(readings.map(\.snapshot.family))
        let missing = HealthMetricSnapshot.Family.allCases.filter { !present.contains($0) }
        onEvent(.snapshot(readings.map(\.snapshot), refreshedAt: Date(), missing: missing))
        if !readings.isEmpty { onBatch(readings.map(\.sample)) }
    }

    public func stopObservers() {
        queue.sync {
            activeQueries.forEach(store.stop)
            activeQueries.removeAll()
        }
    }

    /// Background delivery runs through an `HKObserverQuery`, and HealthKit
    /// requires its completion handler to be called for every update: without
    /// it HealthKit backs off and, after repeated misses, stops launching the
    /// app for background updates. The bridge had only anchored queries, which
    /// have no completion, so a system-terminated or restarted app was never
    /// woken (M5 device walk-through, 2026-09-24: no relaunch after a restart).
    /// The completion acknowledges that the update was handled, not that the PE
    /// accepted it; a failed delivery is retried by the next update and at launch.
    private func startObserverQuery(for type: HKSampleType) {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            guard let self else { completion(); return }
            if let error {
                self.onEvent(.queryFailed(typeIdentifier: type.identifier, message: error.localizedDescription))
                completion()
                return
            }
            Task {
                if let reading = await self.reading(for: type) {
                    self.onEvent(.snapshot([reading.snapshot], refreshedAt: Date(), missing: []))
                    if let deliver = self.deliver {
                        await deliver([reading.sample])
                    } else {
                        self.onBatch([reading.sample])
                    }
                }
                completion()
            }
        }
        queue.sync { activeQueries.append(query) }
        store.execute(query)
    }

    private func startAnchoredQuery(for type: HKSampleType) {
        let saved = anchors.anchorData(for: type.identifier).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, newAnchor, error in
            guard let self else { return }
            if let error {
                self.onEvent(.queryFailed(typeIdentifier: type.identifier, message: error.localizedDescription))
                return
            }
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
            let reading = await self.reading(for: type)
            if let reading {
                self.onEvent(.snapshot([reading.snapshot], refreshedAt: Date(), missing: []))
                self.onBatch([reading.sample])
            }
        }
    }

    /// The family reading an update to `type` refreshes.
    private func reading(for type: HKSampleType) async -> FamilyReading? {
        switch type.identifier {
        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
            return await bloodPressureReading()
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            return await sleepReading()
        default:
            return await exerciseReading()
        }
    }

    /// Latest blood-pressure correlation → BP family sample. Pulse comes from
    /// the most recent heart-rate reading in the correlation's window, if any.
    func latestBloodPressureSample() async -> IngestSample? {
        await bloodPressureReading()?.sample
    }

    private func bloodPressureReading() async -> FamilyReading? {
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
        let systolic = component(.bloodPressureSystolic)
        let diastolic = component(.bloodPressureDiastolic)
        let sample = SampleNormalizer.bloodPressure(
            systolicMmHg: systolic,
            diastolicMmHg: diastolic,
            pulseBpm: pulse,
            sourceName: correlation.sourceRevision.source.name
        )
        let pulseSummary = pulse > 0 ? "Pulse \(Int(pulse.rounded())) bpm" : "Pulse unavailable"
        return FamilyReading(
            sample: sample,
            snapshot: HealthMetricSnapshot(
                family: .bloodPressure,
                primaryValue: "\(Int(systolic.rounded()))/\(Int(diastolic.rounded())) mmHg",
                secondaryValue: pulseSummary,
                sourceName: correlation.sourceRevision.source.name,
                measuredAt: correlation.endDate
            )
        )
    }

    /// Today's activity totals → exercise family sample.
    func exerciseSampleForToday() async -> IngestSample? {
        await exerciseReading()?.sample
    }

    private func exerciseReading() async -> FamilyReading? {
        let now = Date()
        let interval = DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
        async let energy = sumQuantity(of: .activeEnergyBurned, unit: .kilocalorie(), over: interval)
        async let minutes = sumQuantity(of: .appleExerciseTime, unit: .minute(), over: interval)
        async let steps = sumQuantity(of: .stepCount, unit: .count(), over: interval)
        let (e, m, s) = await (energy, minutes, steps)
        guard e != nil || m != nil || s != nil else { return nil }
        let sample = SampleNormalizer.exercise(
            activeEnergyKcal: e ?? 0,
            exerciseMinutes: m ?? 0,
            steps: s ?? 0
        )
        return FamilyReading(
            sample: sample,
            snapshot: HealthMetricSnapshot(
                family: .exercise,
                primaryValue: "\(Int((s ?? 0).rounded()).formatted()) steps",
                secondaryValue: "\(Int((m ?? 0).rounded())) min · \(Int((e ?? 0).rounded())) kcal",
                sourceName: "Apple Health",
                measuredAt: now
            )
        )
    }

    /// Sleep-analysis samples from the last 24 h summed by stage → sleep family sample.
    func sleepSampleForLast24Hours() async -> IngestSample? {
        await sleepReading()?.sample
    }

    private func sleepReading() async -> FamilyReading? {
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
        let sample = SampleNormalizer.sleep(totalHours: total, remHours: rem, coreHours: core, sourceName: sourceName)
        return FamilyReading(
            sample: sample,
            snapshot: HealthMetricSnapshot(
                family: .sleep,
                primaryValue: String(format: "%.1f hr", total),
                secondaryValue: String(format: "REM %.1f hr · Core %.1f hr", rem, core),
                sourceName: sourceName ?? "Apple Health",
                measuredAt: now
            )
        )
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
