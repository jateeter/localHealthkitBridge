import Foundation

/// Normalizes raw HealthKit values into the four-element `[0,1]` vectors the
/// ingest contract expects. Ranges are fixed by the README normalization
/// tables — keep them in sync with docs/INGEST_CONTRACT.md and the runtime
/// example configs (integrations.healthkit-spezi.example.json).
public enum SampleNormalizer {

    public enum HKType {
        public static let bloodPressure = "HKCorrelationTypeIdentifierBloodPressure"
        public static let workout = "HKWorkoutTypeIdentifierWorkout"
        public static let sleepAnalysis = "HKCategoryTypeIdentifierSleepAnalysis"
    }

    // Normalization ranges (family → per-slot full-scale value).
    public static let systolicRange = 0.0...200.0     // mmHg
    public static let diastolicRange = 0.0...120.0    // mmHg
    public static let pulseRange = 0.0...200.0        // bpm
    public static let activeEnergyRange = 0.0...3000.0 // kcal
    public static let exerciseTimeRange = 0.0...120.0  // minutes
    public static let stepsRange = 0.0...10000.0       // steps
    public static let sleepHoursRange = 0.0...10.0     // hours

    static func scale(_ value: Double, over range: ClosedRange<Double>) -> Double {
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
        let unit = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(max(unit, 0), 1)
    }

    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Blood pressure family: systolic, diastolic, pulse, confidence.
    public static func bloodPressure(
        systolicMmHg: Double,
        diastolicMmHg: Double,
        pulseBpm: Double,
        confidence: Double = 1.0,
        sourceName: String? = nil
    ) -> IngestSample {
        IngestSample(
            type: HKType.bloodPressure,
            sourceName: sourceName,
            unit: "mm[Hg]",
            values: [
                scale(systolicMmHg, over: systolicRange),
                scale(diastolicMmHg, over: diastolicRange),
                scale(pulseBpm, over: pulseRange),
                clamp01(confidence),
            ],
            metadata: [
                "standard": "HealthKit",
                "fhirProfile": "http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure",
                "fhirCode": "85354-9",
                "rawSystolicMmHg": String(systolicMmHg),
                "rawDiastolicMmHg": String(diastolicMmHg),
                "rawPulseBpm": String(pulseBpm),
            ]
        )
    }

    /// Exercise family: active energy, exercise minutes, step fraction, confidence.
    public static func exercise(
        activeEnergyKcal: Double,
        exerciseMinutes: Double,
        steps: Double,
        confidence: Double = 1.0,
        sourceName: String? = nil
    ) -> IngestSample {
        IngestSample(
            type: HKType.workout,
            sourceName: sourceName,
            unit: "normalized",
            values: [
                scale(activeEnergyKcal, over: activeEnergyRange),
                scale(exerciseMinutes, over: exerciseTimeRange),
                scale(steps, over: stepsRange),
                clamp01(confidence),
            ],
            metadata: [
                "standard": "HealthKit",
                "fhirCode": "55411-3",
                "rawActiveEnergyKcal": String(activeEnergyKcal),
                "rawExerciseMinutes": String(exerciseMinutes),
                "rawSteps": String(steps),
            ]
        )
    }

    /// Sleep family: total sleep fraction, REM fraction, core fraction, confidence.
    /// REM/core fractions are of total sleep time (0 when totalHours is 0).
    public static func sleep(
        totalHours: Double,
        remHours: Double,
        coreHours: Double,
        confidence: Double = 1.0,
        sourceName: String? = nil
    ) -> IngestSample {
        let remFraction = totalHours > 0 ? clamp01(remHours / totalHours) : 0
        let coreFraction = totalHours > 0 ? clamp01(coreHours / totalHours) : 0
        return IngestSample(
            type: HKType.sleepAnalysis,
            sourceName: sourceName,
            unit: "normalized",
            values: [
                scale(totalHours, over: sleepHoursRange),
                remFraction,
                coreFraction,
                clamp01(confidence),
            ],
            metadata: [
                "standard": "HealthKit",
                "fhirCode": "93832-4",
                "rawTotalHours": String(totalHours),
                "rawRemHours": String(remHours),
                "rawCoreHours": String(coreHours),
            ]
        )
    }
}
