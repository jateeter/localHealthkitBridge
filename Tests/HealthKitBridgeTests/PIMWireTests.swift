import XCTest
@testable import HealthKitBridge

/// The bridge's mirror client against a running PIM (MIRROR_CONTRACT §8),
/// through PIM's public API only. Skipped unless `HEALTHKIT_PIM_WIRE_URL` is
/// set; `HEALTHKIT_PIM_WIRE_TOKEN` is PIM's `PIM_HEALTHKIT_BRIDGE_TOKEN`.
///
/// The owner's approval of the metric set is made the way the owner UI would
/// make it, with the owner-approval header; the bridge itself never sends that
/// header except on an apply the owner approved.
final class PIMWireTests: XCTestCase {
    private var baseURL: URL!
    private var token: String?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HEALTHKIT_PIM_WIRE_URL"], let url = URL(string: raw) else {
            throw XCTSkip("HEALTHKIT_PIM_WIRE_URL not set")
        }
        baseURL = url
        token = env["HEALTHKIT_PIM_WIRE_TOKEN"]
    }

    private func client() -> PIMClient {
        PIMClient(configuration: PIMConfiguration(pimBaseURL: baseURL, bridgeId: "wire-test", pimToken: token, retryDelays: []))
    }

    /// What the owner UI does: change the approved set, with approval.
    private func ownerChange(_ action: String, _ metrics: [String]) async throws -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/integrations/healthkit/metrics"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("true", forHTTPHeaderField: PIMClient.ownerApprovalHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "metrics": metrics])
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    func testMirrorLegAgainstPIM() async throws {
        let hr = "HKQuantityTypeIdentifierHeartRate"
        let steps = "HKQuantityTypeIdentifierStepCount"
        let suite = "pim-wire-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = MirrorLedger(defaults: defaults)
        let coordinator = MirrorCoordinator(client: client(), ledger: ledger)

        // Unique instants per run, so a re-run against the same PIM starts clean.
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        func hrSample(_ uuid: String, _ value: Double, at offset: TimeInterval = 0) -> MirrorSample {
            MirrorSample(uuid: uuid, metric: hr, startDate: base.addingTimeInterval(offset), value: value, unit: "/min", sourceName: "Wire")
        }
        func stepSample(_ uuid: String) -> MirrorSample {
            MirrorSample(uuid: uuid, metric: steps, startDate: base, endDate: base.addingTimeInterval(3600), value: 812, unit: "count")
        }
        func mirror(_ samples: [MirrorSample]) async throws -> MirrorApplyResult {
            try await coordinator.stage(samples)
            let preview = try await coordinator.preview()
            return try await coordinator.apply(approval: OwnerApproval(approving: preview))
        }

        // Declare: proposed, and nothing mirrors before the owner adds it.
        let described = MetricDescriber().describe([hr, steps])
        try await coordinator.declare(described.descriptors)
        var registry = try await coordinator.refreshRegistry()
        XCTAssertNotNil(registry.metrics[hr])
        let added = try await ownerChange("add", [hr, steps])
        XCTAssertEqual(added, 200)
        registry = try await coordinator.refreshRegistry()
        XCTAssertTrue(registry.activeMetrics.isSuperset(of: [hr, steps]))

        // 1. Happy path: created, in vital-signs and the activity pillar.
        let first = try await mirror([hrSample("a-\(suite)", 62), stepSample("b-\(suite)")])
        XCTAssertEqual(first.applied, 2)
        XCTAssertEqual(Set(first.samples.compactMap(\.pillar)), ["vital-signs", "activity"])
        XCTAssertEqual(ledger.state(of: "a-\(suite)"), .mirrored)

        // Idempotence: a different sample of the same measurement is unchanged.
        let again = try await mirror([hrSample("a2-\(suite)", 62)])
        XCTAssertEqual(again.applied, 0)
        XCTAssertEqual(again.samples.first?.action, .unchanged)

        // 2. Conflict: same key, different value. The POD wins.
        let conflict = try await mirror([hrSample("c-\(suite)", 99)])
        XCTAssertEqual(conflict.samples.first?.action, .conflict)
        XCTAssertEqual(conflict.samples.first?.reason, "pod-differs")
        XCTAssertEqual(ledger.state(of: "c-\(suite)"), .conflict)

        // 3. No approval, no write: apply without the header is refused.
        var bare = URLRequest(url: baseURL.appendingPathComponent("api/integrations/healthkit/sync/apply"))
        bare.httpMethod = "POST"
        bare.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { bare.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        bare.httpBody = try JSONEncoder().encode(MirrorBatch(samples: [hrSample("d-\(suite)", 64, at: 120)]))
        let (_, bareResponse) = try await URLSession.shared.data(for: bare)
        XCTAssertEqual((bareResponse as? HTTPURLResponse)?.statusCode, 403)

        // The owner changes the set: the bridge's batch is stale (409), and
        // after refreshing it no longer sends the removed metric.
        try await coordinator.stage([stepSample("e-\(suite)")])
        let removed = try await ownerChange("remove", [steps])
        XCTAssertEqual(removed, 200)
        do {
            _ = try await coordinator.preview()
            XCTFail("expected staleGeneration")
        } catch MirrorError.staleGeneration {}
        let approved = await coordinator.approvedMetrics
        XCTAssertFalse(approved.contains(steps))
        XCTAssertEqual(ledger.state(of: "e-\(suite)"), .pendingMirror)

        // A wrong token is refused.
        let intruder = PIMClient(configuration: PIMConfiguration(pimBaseURL: baseURL, pimToken: "wrong", retryDelays: []))
        if token != nil {
            do {
                _ = try await intruder.metrics()
                XCTFail("expected unauthorized")
            } catch MirrorError.unauthorized {}
        }
    }
}
