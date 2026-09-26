import Foundation

// Wire types for the HealthKit → PIM → POD mirror (docs/MIRROR_CONTRACT.md).
// They match PIM's `src/integrations/healthkit/types.ts`; PIM wraps every
// response body in `{ "data": ... }`.

/// How HealthKit represents a metric.
public enum MetricKind: String, Codable, Sendable {
    case quantity, category, correlation, workout, clinical
}

/// Owner state of a declared metric (MIRROR_CONTRACT §7b). Only `active`
/// metrics are read from HealthKit or mirrored.
public enum MetricState: String, Codable, Sendable {
    case proposed, active, locked, removed
}

/// What the bridge declares about a metric (§2). PIM derives the pillar from
/// it by rule, so the bridge never names a pillar itself.
public struct MetricDescriptor: Codable, Equatable, Sendable {
    /// HealthKit type identifier, e.g. `HKQuantityTypeIdentifierStepCount`.
    public var metric: String
    public var kind: MetricKind
    /// UCUM unit of the raw values, for quantity kinds.
    public var unit: String?
    public var loinc: String?
    /// FHIR Observation category, or for clinical records the resource type.
    public var fhirCategory: String?
    /// Apple Health category: Activity, Sleep, Heart, …
    public var appleCategory: String?
    public var display: String?

    public init(
        metric: String,
        kind: MetricKind,
        unit: String? = nil,
        loinc: String? = nil,
        fhirCategory: String? = nil,
        appleCategory: String? = nil,
        display: String? = nil
    ) {
        self.metric = metric
        self.kind = kind
        self.unit = unit
        self.loinc = loinc
        self.fhirCategory = fhirCategory
        self.appleCategory = appleCategory
        self.display = display
    }
}

/// Where PIM stores a metric's records.
public struct MetricTarget: Codable, Equatable, Sendable {
    public var kind: String
    public var pillar: String
    public var vitalSignCode: String?
}

public struct RegisteredMetric: Codable, Equatable, Sendable {
    public var metric: String
    public var kind: MetricKind
    public var unit: String?
    public var loinc: String?
    public var fhirCategory: String?
    public var appleCategory: String?
    public var state: MetricState
    public var target: MetricTarget
}

/// The owner's metric registry, stored in the POD by PIM.
public struct MetricRegistry: Codable, Equatable, Sendable {
    /// Increases on every owner change; a batch built against an older one is
    /// refused with 409.
    public var generation: Int
    public var metrics: [String: RegisteredMetric]

    public init(generation: Int, metrics: [String: RegisteredMetric]) {
        self.generation = generation
        self.metrics = metrics
    }

    /// The metrics the owner has approved for mirroring.
    public var activeMetrics: Set<String> {
        Set(metrics.values.filter { $0.state == .active }.map(\.metric))
    }
}

/// One HealthKit sample, raw, taken before PE normalization (§2). Carries the
/// measurement itself, so it must never be logged.
public struct MirrorSample: Codable, Equatable, Sendable {
    /// `HKSample.uuid`, the sample's stable identity (§3).
    public var uuid: String
    public var metric: String
    /// ISO 8601.
    public var startDate: String
    public var endDate: String?
    /// Quantity value in `unit`.
    public var value: Double?
    public var unit: String?
    /// Category value, e.g. a sleep stage.
    public var categoryValue: String?
    /// Named components, e.g. `systolic`/`diastolic` for blood pressure.
    public var values: [String: Double]?
    /// HKSource name, the device or app that recorded it.
    public var sourceName: String?

    public init(
        uuid: String,
        metric: String,
        startDate: Date,
        endDate: Date? = nil,
        value: Double? = nil,
        unit: String? = nil,
        categoryValue: String? = nil,
        values: [String: Double]? = nil,
        sourceName: String? = nil
    ) {
        self.uuid = uuid
        self.metric = metric
        self.startDate = MirrorSample.iso8601(startDate)
        self.endDate = endDate.map(MirrorSample.iso8601)
        self.value = value
        self.unit = unit
        self.categoryValue = categoryValue
        self.values = values
        self.sourceName = sourceName
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// A batch for `sync/preview` and `sync/apply`.
public struct MirrorBatch: Codable, Equatable, Sendable {
    public var bridgeId: String?
    /// The registry generation the bridge read.
    public var generation: Int?
    /// Metrics seen for the first time; PIM declares them `proposed`.
    public var descriptors: [MetricDescriptor]?
    public var samples: [MirrorSample]

    public init(bridgeId: String? = nil, generation: Int? = nil, descriptors: [MetricDescriptor]? = nil, samples: [MirrorSample]) {
        self.bridgeId = bridgeId
        self.generation = generation
        self.descriptors = descriptors
        self.samples = samples
    }
}

/// Per-sample mirror state the bridge records (§3). A reading is not durable
/// until PIM reports it `mirrored`.
public enum MirrorState: String, Codable, Sendable {
    case pendingMirror, mirrored, conflict
}

/// Per-sample outcome from PIM. PHI-safe: identity, metric, pillar and
/// outcome, never values.
public struct SampleOutcome: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case create, unchanged, conflict, excluded
    }

    public var sampleUuid: String
    public var metric: String
    public var pillar: String?
    public var action: Action
    /// `undeclared`, `pending-approval`, `locked`, `not-in-scope`,
    /// `unmappable`, `invalid`, `pod-differs` or `ambiguous`.
    public var reason: String?
    public var url: String?
    public var mirrorState: MirrorState?
}

public struct MirrorCounts: Codable, Equatable, Sendable {
    public var create: Int
    public var unchanged: Int
    public var conflict: Int
    public var excluded: Int
}

public struct MirrorSummary: Codable, Equatable, Sendable {
    public var total: Int
    public var create: Int
    public var unchanged: Int
    public var conflict: Int
    public var excluded: Int
    public var byPillar: [String: MirrorCounts]
}

/// What `sync/preview` returns. Nothing has been written.
public struct MirrorPreview: Codable, Equatable, Sendable {
    public var generation: Int
    public var declared: [String]
    public var samples: [SampleOutcome]
    public var summary: MirrorSummary
}

/// What `sync/apply` returns.
public struct MirrorApplyResult: Codable, Equatable, Sendable {
    public var generation: Int
    public var declared: [String]
    public var samples: [SampleOutcome]
    public var summary: MirrorSummary
    /// Records written.
    public var applied: Int
}

public struct MetricChangeResult: Codable, Equatable, Sendable {
    public struct Applied: Codable, Equatable, Sendable {
        public var metric: String
        public var state: MetricState
        public var previous: MetricState?
    }

    public var action: String
    public var generation: Int
    public var applied: [Applied]
}

/// The owner's approval of one previewed batch (§7a). It can only be made from
/// the preview the owner saw, and `apply` refuses a batch that differs from it,
/// so what is applied is what was previewed.
public struct OwnerApproval: Equatable, Sendable {
    public let generation: Int
    public let sampleUuids: [String]

    /// Call only when the owner has approved `preview`.
    public init(approving preview: MirrorPreview) {
        self.generation = preview.generation
        self.sampleUuids = preview.samples.map(\.sampleUuid)
    }

    func covers(_ batch: MirrorBatch) -> Bool {
        batch.generation == generation && batch.samples.map(\.uuid) == sampleUuids
    }
}

public enum MirrorError: Error, Equatable, Sendable {
    /// PIM refused the bridge token (401).
    case unauthorized
    /// PIM requires the owner-approval header (403).
    case ownerApprovalRequired
    /// The batch was built against an older approved set (409). Refresh the
    /// registry and preview again.
    case staleGeneration
    /// PIM rejected the request body (400).
    case invalidRequest
    /// The approval was given for a different batch than the one applied.
    case approvalDoesNotMatchBatch
    /// No batch has been previewed.
    case nothingPreviewed
    case httpStatus(Int)
    case invalidResponse
    case transport(String)
}
