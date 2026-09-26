import Foundation

/// Drives the mirror (MIRROR_CONTRACT §6, §7): declare what HealthKit
/// authorizes, keep the owner's approved set, stage only `active` metrics,
/// preview, and apply only with the owner's approval of that preview.
///
/// Independent of `BridgeCoordinator`: PE ingest is unchanged and does not
/// wait on the mirror, and the mirror does not wait on ingest.
public actor MirrorCoordinator {
    /// PIM refuses larger batches.
    public static let maxBatch = 500

    private let client: PIMClient
    private let ledger: MirrorLedger
    private var registry: MetricRegistry?
    private var staged: MirrorBatch?
    private var previewed: MirrorPreview?

    public init(client: PIMClient, ledger: MirrorLedger = MirrorLedger()) {
        self.client = client
        self.ledger = ledger
    }

    /// Reads the owner's registry from PIM. Call before staging, and whenever
    /// the owner may have changed the set; staging uses the cached copy.
    @discardableResult
    public func refreshRegistry() async throws -> MetricRegistry {
        let fresh = try await client.metrics()
        registry = fresh
        return fresh
    }

    /// The metrics the bridge should read from HealthKit: only `active` ones.
    /// A metric the owner adds appears here, so the app can request HealthKit
    /// authorization for it; one the owner locks or removes disappears.
    public var approvedMetrics: Set<String> { registry?.activeMetrics ?? [] }

    public var generation: Int? { registry?.generation }

    /// Declares descriptors PIM has not seen. Declaring grants nothing: each
    /// starts `proposed` until the owner adds it.
    @discardableResult
    public func declare(_ descriptors: [MetricDescriptor]) async throws -> [String] {
        let known = try await registryOrFetch().metrics
        let fresh = descriptors.filter { known[$0.metric] == nil }
        guard !fresh.isEmpty else { return [] }
        _ = try await client.declare(fresh)
        try await refreshRegistry()
        return fresh.map(\.metric)
    }

    /// Stages up to `maxBatch` samples of approved metrics that are not
    /// already mirrored, and marks them `pendingMirror`. Returns the samples
    /// left over, for the next batch. Samples of unapproved metrics are
    /// dropped here, never sent: the bridge reads only what the owner allows.
    @discardableResult
    public func stage(_ samples: [MirrorSample]) async throws -> [MirrorSample] {
        let current = try await registryOrFetch()
        let approved = current.activeMetrics
        let entries = ledger.entries()
        var seen = Set<String>()
        let eligible = samples.filter { sample in
            approved.contains(sample.metric)
                && entries[sample.uuid]?.state != .mirrored
                && seen.insert(sample.uuid).inserted
        }
        let batch = Array(eligible.prefix(Self.maxBatch))
        staged = MirrorBatch(generation: current.generation, samples: batch)
        previewed = nil
        ledger.record(Dictionary(uniqueKeysWithValues: batch.map {
            ($0.uuid, MirrorLedger.Entry(metric: $0.metric, state: .pendingMirror))
        }))
        return Array(eligible.dropFirst(Self.maxBatch))
    }

    /// Previews the staged batch. Nothing is written. The result is what the
    /// owner is shown, as PHI-safe counts, before approving.
    public func preview() async throws -> MirrorPreview {
        guard let batch = staged else { throw MirrorError.nothingPreviewed }
        do {
            let result = try await client.preview(batch)
            previewed = result
            return result
        } catch MirrorError.staleGeneration {
            try await discardStale()
            throw MirrorError.staleGeneration
        }
    }

    /// Applies the previewed batch with the owner's approval of that preview,
    /// and records each sample's mirror state from PIM's answer. On any
    /// failure the samples stay `pendingMirror`.
    public func apply(approval: OwnerApproval) async throws -> MirrorApplyResult {
        guard let batch = staged, previewed != nil else { throw MirrorError.nothingPreviewed }
        let result: MirrorApplyResult
        do {
            result = try await client.apply(batch, approval: approval)
        } catch MirrorError.staleGeneration {
            try await discardStale()
            throw MirrorError.staleGeneration
        }
        var updates: [String: MirrorLedger.Entry] = [:]
        for outcome in result.samples {
            updates[outcome.sampleUuid] = MirrorLedger.Entry(
                metric: outcome.metric,
                state: outcome.mirrorState ?? .pendingMirror,
                reason: outcome.reason)
        }
        ledger.record(updates)
        staged = nil
        previewed = nil
        return result
    }

    /// The owner's set changed under the batch: forget it and re-read the set,
    /// so the next stage honors it. The samples stay `pendingMirror`.
    private func discardStale() async throws {
        staged = nil
        previewed = nil
        try await refreshRegistry()
    }

    private func registryOrFetch() async throws -> MetricRegistry {
        if let registry { return registry }
        return try await refreshRegistry()
    }
}
