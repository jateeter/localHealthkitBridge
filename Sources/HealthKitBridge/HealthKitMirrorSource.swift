#if canImport(HealthKit)
import Foundation
import HealthKit

/// Reads raw HealthKit samples for the mirror (MIRROR_CONTRACT §2, §6):
/// `HKSample.uuid`, dates and raw values in the metric's unit, taken before
/// any PE normalization. Reads only the metrics it is given, which the caller
/// takes from the owner's approved set (`MirrorCoordinator.approvedMetrics`).
///
/// Separate from `HealthKitManager`, whose anchored observers feed PE ingest;
/// ingest is unchanged. The mirror reads by time window instead of anchors,
/// because a sample must stay readable until PIM reports it `mirrored`, and
/// the ledger, not an anchor, skips what already landed.
@available(iOS 16.0, macOS 13.0, *)
public final class HealthKitMirrorSource: @unchecked Sendable {
    private let store: HKHealthStore
    private let describer: MetricDescriber

    public init(store: HKHealthStore = HKHealthStore(), describer: MetricDescriber = MetricDescriber()) {
        self.store = store
        self.describer = describer
    }

    /// Requests read authorization for approved metrics. A metric the owner
    /// adds triggers this; HealthKit shows only types not yet answered.
    public func requestAuthorization(for metrics: Set<String>) async throws {
        let types = Set(metrics.flatMap(Self.authorizationTypes(for:)))
        guard !types.isEmpty else { return }
        try await store.requestAuthorization(toShare: [], read: types)
    }

    /// Descriptors for metrics HealthKit can read, for `MirrorCoordinator.declare`.
    public func descriptors(for identifiers: [String]) -> (descriptors: [MetricDescriptor], undescribed: [String]) {
        describer.describe(identifiers.filter { Self.sampleType(for: $0) != nil })
    }

    /// Raw samples of `metrics` whose end falls in `interval`.
    public func samples(of metrics: Set<String>, in interval: DateInterval) async -> [MirrorSample] {
        var all: [MirrorSample] = []
        for metric in metrics.sorted() {
            guard let type = Self.sampleType(for: metric) else { continue }
            let unit = describer.descriptor(for: metric)?.unit
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictEndDate)
            let found: [HKSample] = await withCheckedContinuation { continuation in
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                          limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, _ in
                    continuation.resume(returning: results ?? [])
                }
                store.execute(query)
            }
            all.append(contentsOf: found.compactMap { Self.mirrorSample($0, metric: metric, unit: unit) })
        }
        return all
    }

    // MARK: - Mapping

    static func sampleType(for identifier: String) -> HKSampleType? {
        if identifier == HKObjectType.workoutType().identifier { return HKObjectType.workoutType() }
        if let q = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) { return q }
        if let c = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)) { return c }
        if let c = HKCorrelationType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: identifier)) { return c }
        return nil
    }

    /// HealthKit refuses authorization requests for correlation types; their
    /// component quantities authorize the correlation.
    static func authorizationTypes(for identifier: String) -> [HKObjectType] {
        if identifier == HKCorrelationTypeIdentifier.bloodPressure.rawValue {
            return [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)]
        }
        guard let type = sampleType(for: identifier), !(type is HKCorrelationType) else { return [] }
        return [type]
    }

    /// The HealthKit unit for a descriptor's unit string. Descriptor units are
    /// the ones PIM stores; HealthKit's own unit strings differ for some.
    static func hkUnit(_ unit: String) -> HKUnit? {
        switch unit {
        case "mmHg": return .millimeterOfMercury()
        case "/min": return HKUnit.count().unitDivided(by: .minute())
        case "count": return .count()
        case "min": return .minute()
        case "kcal": return .kilocalorie()
        case "kg": return .gramUnit(with: .kilo)
        case "cm": return .meterUnit(with: .centi)
        case "%": return .percent()
        case "Cel": return .degreeCelsius()
        case "mg/dL": return HKUnit(from: "mg/dL")
        default: return nil
        }
    }

    static func mirrorSample(_ sample: HKSample, metric: String, unit: String?) -> MirrorSample? {
        let source = sample.sourceRevision.source.name
        switch sample {
        case let correlation as HKCorrelation where metric == HKCorrelationTypeIdentifier.bloodPressure.rawValue:
            let mmHg = HKUnit.millimeterOfMercury()
            func component(_ id: HKQuantityTypeIdentifier) -> Double? {
                (correlation.objects(for: HKQuantityType(id)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg)
            }
            guard let systolic = component(.bloodPressureSystolic),
                  let diastolic = component(.bloodPressureDiastolic) else { return nil }
            return MirrorSample(uuid: correlation.uuid.uuidString, metric: metric,
                                startDate: correlation.startDate, endDate: correlation.endDate,
                                unit: "mmHg", values: ["systolic": systolic, "diastolic": diastolic],
                                sourceName: source)
        case let quantity as HKQuantitySample:
            guard let unit, let hk = hkUnit(unit), quantity.quantity.is(compatibleWith: hk) else { return nil }
            return MirrorSample(uuid: quantity.uuid.uuidString, metric: metric,
                                startDate: quantity.startDate, endDate: quantity.endDate,
                                value: quantity.quantity.doubleValue(for: hk), unit: unit, sourceName: source)
        case let category as HKCategorySample:
            return MirrorSample(uuid: category.uuid.uuidString, metric: metric,
                                startDate: category.startDate, endDate: category.endDate,
                                categoryValue: categoryName(category), sourceName: source)
        case let workout as HKWorkout:
            var values = ["durationMin": workout.duration / 60]
            if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
                values["energyKcal"] = energy.doubleValue(for: .kilocalorie())
            }
            return MirrorSample(uuid: workout.uuid.uuidString, metric: metric,
                                startDate: workout.startDate, endDate: workout.endDate,
                                categoryValue: workout.workoutActivityType.rawValue.description,
                                values: values, sourceName: source)
        default:
            return nil
        }
    }

    static func categoryName(_ sample: HKCategorySample) -> String {
        if sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
           let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            switch stage {
            case .inBed: return "inBed"
            case .awake: return "awake"
            case .asleepCore: return "asleepCore"
            case .asleepDeep: return "asleepDeep"
            case .asleepREM: return "asleepREM"
            case .asleepUnspecified: return "asleepUnspecified"
            @unknown default: return String(sample.value)
            }
        }
        return String(sample.value)
    }
}
#endif
