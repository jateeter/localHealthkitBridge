# localHealthkitBridge

Swift iOS bridge that connects Apple HealthKit to a RealityEngine Perception Engine
via `POST /api/integrations/healthkit/ingest`.

The bridge is a Swift app or SPM module that lives entirely outside the RealityEngine
server repos. It owns Apple HealthKit authorization and posts already-authorized,
normalized, read-only samples to whatever runtime PE is reachable on the local network.

---

## Architecture

```
iPhone / Apple Watch
  └─ HealthKit data store
       └─ SpeziHealthKit observer (Swift / SwiftUI)
            └─ localHealthkitBridge (normalization + posting)
                 └─ POST /api/integrations/healthkit/ingest
                          └─ RealityEngine Perception Engine
                               └─ perceptual-space vector
                                    └─ Reality Engine transitions
```

The bridge is the only component that links `HealthKit.framework`. The PE and RE
remain pure HTTP services with no Apple SDK dependency.

---

## iOS App Setup

### Capabilities

Enable in Xcode → target → Signing & Capabilities:

- **HealthKit** — required
- **Background Modes → Background fetch** — required for observer delivery when the app is backgrounded

### Privacy strings (Info.plist)

```xml
<key>NSHealthShareUsageDescription</key>
<string>This app reads blood pressure, exercise, and sleep data to send to your personal health monitor.</string>
<key>NSHealthUpdateUsageDescription</key>
<string>This app does not write HealthKit data.</string>
```

No write usage description is required if the bridge does not request write access.

### Authorization request

Request read-only authorization using `HKHealthStore.requestAuthorization`:

```swift
let readTypes: Set<HKSampleType> = [
    HKCorrelationType.correlationType(
        forIdentifier: .bloodPressure)!,
    HKQuantityType.quantityType(
        forIdentifier: .bloodPressureSystolic)!,
    HKQuantityType.quantityType(
        forIdentifier: .bloodPressureDiastolic)!,
    HKObjectType.workoutType(),
    HKQuantityType.quantityType(
        forIdentifier: .stepCount)!,
    HKQuantityType.quantityType(
        forIdentifier: .appleExerciseTime)!,
    HKQuantityType.quantityType(
        forIdentifier: .activeEnergyBurned)!,
    HKCategoryType.categoryType(
        forIdentifier: .sleepAnalysis)!,
]
healthStore.requestAuthorization(
    toShare: nil, read: readTypes) { _, _ in }
```

Use anchored object queries (`HKAnchoredObjectQuery`) so samples are not
replayed across app launches.

---

## HealthKit Types

| HK type identifier | Bridge family | PE sensor |
|---|---|---|
| `HKCorrelationTypeIdentifierBloodPressure` | blood pressure | `healthkit.blood-pressure` |
| `HKQuantityTypeIdentifierBloodPressureSystolic` | blood pressure | (component of above) |
| `HKQuantityTypeIdentifierBloodPressureDiastolic` | blood pressure | (component of above) |
| `HKWorkoutTypeIdentifierWorkout` | exercise | `healthkit.exercise` |
| `HKQuantityTypeIdentifierStepCount` | exercise | (component of above) |
| `HKQuantityTypeIdentifierAppleExerciseTime` | exercise | (component of above) |
| `HKQuantityTypeIdentifierActiveEnergyBurned` | exercise | (component of above) |
| `HKCategoryTypeIdentifierSleepAnalysis` | sleep | `healthkit.sleep` |

---

## Normalization

Each sample family is normalized to a four-element PE vector `[0.0 … 1.0]`:

| Family | values[0] | values[1] | values[2] | values[3] |
|---|---|---|---|---|
| Blood pressure | systolic (0–200 mmHg → 0–1) | diastolic (0–120 mmHg → 0–1) | pulse (0–200 bpm → 0–1) | confidence |
| Exercise | active energy (0–3000 kcal → 0–1) | exercise time (0–120 min → 0–1) | step fraction (0–10000 steps → 0–1) | confidence |
| Sleep | total sleep fraction (0–10 h → 0–1) | REM fraction | core fraction | confidence |

Retain raw HealthKit values and FHIR units in `metadata` for downstream audit.

---

## PE Ingest Payload

### Single sample (flat body)

```json
{
  "type": "HKQuantityTypeIdentifierHeartRate",
  "value": 72.0,
  "sourceName": "Apple Watch"
}
```

### Batch (preferred for multi-sample delivery)

```json
{
  "bridgeId": "healthkit-ios-bridge",
  "bridgeToken": "<token>",
  "samples": [
    { "type": "HKCategoryTypeIdentifierSleepAnalysis", "value": 0.82 },
    { "type": "HKCorrelationTypeIdentifierBloodPressure", "value": 0.72 }
  ]
}
```

### Blood pressure example

```json
{
  "bridgeId": "healthkit-ios-bridge",
  "bridgeToken": "your-shared-dev-token",
  "type": "HKCorrelationTypeIdentifierBloodPressure",
  "unit": "mm[Hg]",
  "values": [0.72, 0.48, 0.24, 0.99],
  "metadata": {
    "standard": "SpeziHealthKit",
    "fhirProfile": "http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure",
    "fhirCode": "85354-9"
  }
}
```

### Exercise example

```json
{
  "bridgeId": "healthkit-ios-bridge",
  "bridgeToken": "your-shared-dev-token",
  "type": "HKWorkoutTypeIdentifierWorkout",
  "unit": "normalized",
  "values": [0.65, 0.58, 0.42, 0.97],
  "metadata": {
    "standard": "SpeziHealthKit",
    "fhirCode": "55411-3"
  }
}
```

### Sleep example

```json
{
  "bridgeId": "healthkit-ios-bridge",
  "bridgeToken": "your-shared-dev-token",
  "type": "HKCategoryTypeIdentifierSleepAnalysis",
  "unit": "normalized",
  "values": [0.82, 0.12, 0.18, 0.96],
  "metadata": {
    "standard": "SpeziHealthKit",
    "fhirCode": "93832-4"
  }
}
```

---

## Mapping Registry

The PE maps ingest samples to perceptual-space regions using a two-level registry lookup:

1. Explicit `sourceMappingId` or `mappingId` in the sample (highest priority).
2. `healthkit:<type>:<sourceName>` when `sourceName` is non-empty.
3. `healthkit:<type>` generic fallback.

Default perceptual regions (from `config/integrations.healthkit-spezi.example.json`
in each runtime repo):

```
healthkit:HKCorrelationTypeIdentifierBloodPressure → [4320:4324]
healthkit:HKWorkoutTypeIdentifierWorkout           → [4330:4334]
healthkit:HKCategoryTypeIdentifierSleepAnalysis    → [4340:4344]
```

---

## Token Authentication

The PE checks `HEALTHKIT_BRIDGE_TOKEN` at startup.

| Env set | Behavior |
|---|---|
| Not set | All ingest accepted without auth (dev / no-token mode) |
| Set | Body must contain `bridgeToken` (primary) or `token` (alias). Bearer `Authorization` header is **not** accepted. Wrong or missing token → `401 Unauthorized`. |

---

## PE Response

```json
{
  "success": true,
  "bridgeId": "healthkit-ios-bridge",
  "resolved": [
    {
      "resolved": true,
      "sensorId": "healthkit.blood-pressure",
      "type": "HKCorrelationTypeIdentifierBloodPressure",
      "sourceMappingId": "healthkit:HKCorrelationTypeIdentifierBloodPressure",
      "values": [0.72, 0.48, 0.24, 0.99],
      "ttlMs": 3600000
    }
  ],
  "unmapped": []
}
```

HTTP status: `200` (all resolved) · `207` (partial) · `400` (all unmapped).

---

## Runtime Connection

| Runtime | Default PE port | Example base URL |
|---|---|---|
| CPP (C++ / Boost.Beast) | `5300` | `http://<mac-lan-ip>:5300` |
| Scala (Akka-HTTP) | `5000` | `http://<mac-lan-ip>:5000` |
| LSP (SBCL / Hunchentoot) | `5600` | `http://<mac-lan-ip>:5600` |

Do not use `localhost` from the simulator or a physical iPhone unless the PE
is running inside that same device. For simulator-to-Mac, `127.0.0.1` with
the runtime port works. For a physical iPhone, use the Mac's LAN IP.

Per-runtime bridge setup guides with example configs and e2e verification:

- CPP → [`RealityEngine_CPP/docs/HEALTHKIT_SPEZI_BRIDGE.md`](https://github.com/jateeter/RealityEngine_CPP/blob/main/docs/HEALTHKIT_SPEZI_BRIDGE.md)
- Scala → [`RealityEngine_Scala/perception-engine/docs/HEALTHKIT_SPEZI_BRIDGE.md`](https://github.com/jateeter/RealityEngine_Scala/blob/main/perception-engine/docs/HEALTHKIT_SPEZI_BRIDGE.md)
- LSP → [`RealityEngine_LSP/docs/HEALTHKIT_SPEZI_BRIDGE.md`](https://github.com/jateeter/RealityEngine_LSP/blob/main/docs/HEALTHKIT_SPEZI_BRIDGE.md)

---

## References

- [Stanford SpeziHealthKit](https://github.com/StanfordSpezi/SpeziHealthKit)
- [SpeziHealthKit on Swift Package Index](https://swiftpackageindex.com/StanfordSpezi/SpeziHealthKit)
- [Apple HealthKit setup](https://developer.apple.com/documentation/healthkit/setting_up_healthkit)
- [Apple HealthKit authorization](https://developer.apple.com/documentation/HealthKit/authorizing-access-to-health-data)
- [FHIR US Core Blood Pressure](http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure)
