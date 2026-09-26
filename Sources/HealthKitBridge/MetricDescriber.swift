import Foundation

/// Describes a HealthKit type for declaration (MIRROR_CONTRACT §2).
///
/// This says what a type *is* (kind, unit, LOINC, Apple category), which
/// HealthKit's API does not expose. It does not decide what is mirrored: that
/// is the owner's registry in the POD, and it changes at runtime. A type with
/// no description is not declared, because PIM refuses a metric it cannot
/// place in a pillar rather than guessing; `describe` reports it instead.
/// Descriptions can be added at runtime with `adding(_:)`.
public struct MetricDescriber: Sendable {
    private var descriptions: [String: MetricDescriptor]

    public init(descriptions: [MetricDescriptor] = MetricDescriber.builtIn) {
        self.descriptions = Dictionary(descriptions.map { ($0.metric, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func adding(_ more: [MetricDescriptor]) -> MetricDescriber {
        var copy = self
        for descriptor in more { copy.descriptions[descriptor.metric] = descriptor }
        return copy
    }

    public func descriptor(for identifier: String) -> MetricDescriptor? {
        descriptions[identifier]
    }

    /// Splits identifiers into declarable descriptors and those it cannot describe.
    public func describe(_ identifiers: [String]) -> (descriptors: [MetricDescriptor], undescribed: [String]) {
        var descriptors: [MetricDescriptor] = []
        var undescribed: [String] = []
        for id in identifiers {
            if let d = descriptions[id] { descriptors.append(d) } else { undescribed.append(id) }
        }
        return (descriptors, undescribed)
    }

    /// Descriptions of the types the bridge reads today. LOINC codes follow
    /// the FHIR vital-signs profile, so PIM files them under `vital-signs`
    /// where they reconcile with Epic's readings.
    public static let builtIn: [MetricDescriptor] = [
        MetricDescriptor(metric: "HKCorrelationTypeIdentifierBloodPressure", kind: .correlation, unit: "mmHg",
                         loinc: "85354-9", fhirCategory: "vital-signs", appleCategory: "Vitals", display: "Blood pressure"),
        MetricDescriptor(metric: "HKQuantityTypeIdentifierHeartRate", kind: .quantity, unit: "/min",
                         loinc: "8867-4", fhirCategory: "vital-signs", appleCategory: "Heart", display: "Heart rate"),
        MetricDescriptor(metric: "HKQuantityTypeIdentifierStepCount", kind: .quantity, unit: "count",
                         loinc: "55423-8", fhirCategory: "activity", appleCategory: "Activity", display: "Steps"),
        MetricDescriptor(metric: "HKQuantityTypeIdentifierAppleExerciseTime", kind: .quantity, unit: "min",
                         fhirCategory: "activity", appleCategory: "Activity", display: "Exercise minutes"),
        MetricDescriptor(metric: "HKQuantityTypeIdentifierActiveEnergyBurned", kind: .quantity, unit: "kcal",
                         loinc: "41981-2", fhirCategory: "activity", appleCategory: "Activity", display: "Active energy"),
        MetricDescriptor(metric: "HKWorkoutTypeIdentifier", kind: .workout,
                         fhirCategory: "activity", appleCategory: "Activity", display: "Workouts"),
        MetricDescriptor(metric: "HKCategoryTypeIdentifierSleepAnalysis", kind: .category,
                         appleCategory: "Sleep", display: "Sleep"),
    ]
}
