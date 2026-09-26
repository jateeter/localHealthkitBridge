import XCTest
@testable import HealthKitBridge

/// The bridge side of docs/MIRROR_CONTRACT.md, against a scripted PIM.
/// Reuses `MockURLProtocol` from IngestClientTests.
final class PIMMirrorTests: XCTestCase {

    private let hr = "HKQuantityTypeIdentifierHeartRate"
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"

    private var defaults: UserDefaults!
    private var ledger: MirrorLedger!

    override func setUp() {
        let suite = "pim-mirror-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        ledger = MirrorLedger(defaults: defaults)
    }

    private func makeClient(token: String? = "pim-token", retryDelays: [TimeInterval] = [0, 0]) -> PIMClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        return PIMClient(
            configuration: PIMConfiguration(pimBaseURL: URL(string: "http://127.0.0.1:9")!, bridgeId: "bridge-1",
                                            pimToken: token, retryDelays: retryDelays),
            sessionConfiguration: sessionConfig,
            sleeper: { _ in })
    }

    // MARK: - Scripted PIM bodies

    private func ok(_ json: String) -> MockURLProtocol.Scripted {
        .init(status: 200, body: Data(#"{"data":\#(json)}"#.utf8))
    }

    private func registry(generation: Int, _ states: [String: String]) -> MockURLProtocol.Scripted {
        let metrics = states.map { metric, state in
            #""\#(metric)":{"metric":"\#(metric)","kind":"quantity","state":"\#(state)","target":{"kind":"pillar","pillar":"activity"}}"#
        }.joined(separator: ",")
        return ok(#"{"generation":\#(generation),"metrics":{\#(metrics)}}"#)
    }

    private func outcomes(_ items: [(String, String, String?, String?)], applied: Int? = nil) -> MockURLProtocol.Scripted {
        let samples = items.map { uuid, action, reason, state in
            var fields = [#""sampleUuid":"\#(uuid)""#, #""metric":"\#(hr)""#, #""action":"\#(action)""#, #""pillar":"vital-signs""#]
            if let reason { fields.append(#""reason":"\#(reason)""#) }
            if let state { fields.append(#""mirrorState":"\#(state)""#) }
            return "{\(fields.joined(separator: ","))}"
        }.joined(separator: ",")
        let summary = #"{"total":\#(items.count),"create":0,"unchanged":0,"conflict":0,"excluded":0,"byPillar":{}}"#
        let appliedField = applied.map { #","applied":\#($0)"# } ?? ""
        return ok(#"{"generation":1,"declared":[],"samples":[\#(samples)],"summary":\#(summary)\#(appliedField)}"#)
    }

    private func sample(_ uuid: String, metric: String? = nil, value: Double = 62) -> MirrorSample {
        MirrorSample(uuid: uuid, metric: metric ?? hr, startDate: Date(timeIntervalSince1970: 1_790_000_000),
                     value: value, unit: "/min", sourceName: "Apple Watch")
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        } ?? Data()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - PIMClient

    func testDeclareSendsDescriptorsWithBearerAndNoApproval() async throws {
        MockURLProtocol.reset(script: [ok(#"{"action":"declare","generation":0,"applied":[{"metric":"\#(hr)","state":"proposed","previous":null}]}"#)])
        let descriptor = try XCTUnwrap(MetricDescriber().descriptor(for: hr))
        let result = try await makeClient().declare([descriptor])

        XCTAssertEqual(result.applied.first?.state, .proposed)
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/api/integrations/healthkit/metrics")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pim-token")
        XCTAssertNil(request.value(forHTTPHeaderField: PIMClient.ownerApprovalHeader), "declaring grants nothing, so it carries no approval")
        let sent = try body(request)
        XCTAssertEqual(sent["action"] as? String, "declare")
        XCTAssertEqual((sent["descriptors"] as? [[String: Any]])?.first?["loinc"] as? String, "8867-4")
    }

    func testPreviewCarriesNoApprovalAndApplyDoes() async throws {
        let batch = MirrorBatch(generation: 1, samples: [sample("s-1")])
        MockURLProtocol.reset(script: [outcomes([("s-1", "create", nil, nil)]), outcomes([("s-1", "create", nil, "mirrored")], applied: 1)])
        let client = makeClient()

        let preview = try await client.preview(batch)
        _ = try await client.apply(batch, approval: OwnerApproval(approving: preview))

        let (previewRequest, applyRequest) = (MockURLProtocol.captured[0], MockURLProtocol.captured[1])
        XCTAssertEqual(previewRequest.url?.path, "/api/integrations/healthkit/sync/preview")
        XCTAssertNil(previewRequest.value(forHTTPHeaderField: PIMClient.ownerApprovalHeader))
        XCTAssertEqual(applyRequest.url?.path, "/api/integrations/healthkit/sync/apply")
        XCTAssertEqual(applyRequest.value(forHTTPHeaderField: PIMClient.ownerApprovalHeader), "true")
        let sent = try body(applyRequest)
        XCTAssertEqual(sent["bridgeId"] as? String, "bridge-1")
        XCTAssertEqual(sent["generation"] as? Int, 1)
        let first = try XCTUnwrap((sent["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["uuid"] as? String, "s-1")
        XCTAssertEqual(first["value"] as? Double, 62, "the mirror carries the raw value, not a [0,1] normalization")
    }

    func testApplyRefusesABatchTheOwnerDidNotApprove() async throws {
        MockURLProtocol.reset(script: [outcomes([("s-1", "create", nil, nil)])])
        let client = makeClient()
        let preview = try await client.preview(MirrorBatch(generation: 1, samples: [sample("s-1")]))

        do {
            _ = try await client.apply(MirrorBatch(generation: 1, samples: [sample("s-1"), sample("s-2")]),
                                       approval: OwnerApproval(approving: preview))
            XCTFail("expected approvalDoesNotMatchBatch")
        } catch let error as MirrorError {
            XCTAssertEqual(error, .approvalDoesNotMatchBatch)
        }
        XCTAssertEqual(MockURLProtocol.captured.count, 1, "the refused apply never reaches PIM")
    }

    func testStatusCodesMapToMirrorErrorsWithoutRetry() async throws {
        let cases: [(Int, MirrorError)] = [(400, .invalidRequest), (401, .unauthorized), (403, .ownerApprovalRequired), (409, .staleGeneration)]
        for (status, expected) in cases {
            MockURLProtocol.reset(script: [.init(status: status, body: Data(#"{"error":"x"}"#.utf8))])
            do {
                _ = try await makeClient().metrics()
                XCTFail("expected \(expected)")
            } catch let error as MirrorError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(MockURLProtocol.captured.count, 1, "\(status) is final")
        }
    }

    func testRetriesServerErrorsThenSucceeds() async throws {
        MockURLProtocol.reset(script: [.init(status: 503, body: Data()), registry(generation: 2, [hr: "active"])])
        let registry = try await makeClient().metrics()
        XCTAssertEqual(registry.generation, 2)
        XCTAssertEqual(registry.activeMetrics, [hr])
        XCTAssertEqual(MockURLProtocol.captured.count, 2)
    }

    func testConfigurationLoadsFromEnvironment() {
        let config = PIMConfiguration.load(info: nil, environment: ["HEALTHKIT_PIM_BASE_URL": "192.168.1.20:3100/api", "HEALTHKIT_PIM_TOKEN": "t"])
        XCTAssertEqual(config?.pimBaseURL.absoluteString, "http://192.168.1.20:3100")
        XCTAssertEqual(config?.pimToken, "t")
        XCTAssertNil(PIMConfiguration.load(info: nil, environment: [:]))
    }

    // MARK: - MirrorCoordinator

    func testStagesOnlyApprovedMetricsAndMarksThemPending() async throws {
        MockURLProtocol.reset(script: [registry(generation: 3, [hr: "active", steps: "proposed", sleep: "locked"])])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)

        let leftover = try await coordinator.stage([sample("s-1"), sample("st-1", metric: steps), sample("sl-1", metric: sleep)])
        XCTAssertTrue(leftover.isEmpty)
        XCTAssertEqual(ledger.state(of: "s-1"), .pendingMirror)
        XCTAssertNil(ledger.state(of: "st-1"), "a proposed metric is never sent")
        XCTAssertNil(ledger.state(of: "sl-1"), "a locked metric is never sent")
        let approved = await coordinator.approvedMetrics
        XCTAssertEqual(approved, [hr])
    }

    func testPreviewApproveApplyRecordsStatesFromPIM() async throws {
        MockURLProtocol.reset(script: [
            registry(generation: 1, [hr: "active"]),
            outcomes([("s-1", "create", nil, nil), ("s-2", "conflict", "pod-differs", nil)]),
            outcomes([("s-1", "create", nil, "mirrored"), ("s-2", "conflict", "pod-differs", "conflict")], applied: 1),
        ])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        try await coordinator.stage([sample("s-1"), sample("s-2", value: 99)])

        let preview = try await coordinator.preview()
        XCTAssertEqual(ledger.state(of: "s-1"), .pendingMirror, "a preview writes nothing, so nothing is mirrored yet")

        let result = try await coordinator.apply(approval: OwnerApproval(approving: preview))
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(ledger.state(of: "s-1"), .mirrored)
        XCTAssertEqual(ledger.state(of: "s-2"), .conflict, "the POD wins; the device copy is held as a conflict")
        XCTAssertEqual(ledger.entries()["s-2"]?.reason, "pod-differs")
    }

    func testMirroredSamplesAreNotSentAgain() async throws {
        ledger.record(["s-1": .init(metric: hr, state: .mirrored)])
        MockURLProtocol.reset(script: [registry(generation: 1, [hr: "active"])])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        try await coordinator.stage([sample("s-1"), sample("s-2"), sample("s-2")])

        MockURLProtocol.reset(script: [outcomes([("s-2", "create", nil, nil)])])
        _ = try await coordinator.preview()
        let sent = try body(try XCTUnwrap(MockURLProtocol.captured.first))
        XCTAssertEqual((sent["samples"] as? [[String: Any]])?.compactMap { $0["uuid"] as? String }, ["s-2"])
    }

    func testFailedApplyLeavesSamplesPending() async throws {
        MockURLProtocol.reset(script: [
            registry(generation: 1, [hr: "active"]),
            outcomes([("s-1", "create", nil, nil)]),
            .init(status: 403, body: Data(#"{"error":"approval"}"#.utf8)),
        ])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        try await coordinator.stage([sample("s-1")])
        let preview = try await coordinator.preview()
        do {
            _ = try await coordinator.apply(approval: OwnerApproval(approving: preview))
            XCTFail("expected ownerApprovalRequired")
        } catch let error as MirrorError {
            XCTAssertEqual(error, .ownerApprovalRequired)
        }
        XCTAssertEqual(ledger.state(of: "s-1"), .pendingMirror, "never reported mirrored after a refusal")
    }

    func testStaleGenerationDropsTheBatchAndHonorsTheNewSet() async throws {
        MockURLProtocol.reset(script: [
            registry(generation: 1, [hr: "active"]),
            .init(status: 409, body: Data(#"{"error":"stale"}"#.utf8)),
            registry(generation: 2, [hr: "removed"]),
        ])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        try await coordinator.stage([sample("s-1")])
        do {
            _ = try await coordinator.preview()
            XCTFail("expected staleGeneration")
        } catch let error as MirrorError {
            XCTAssertEqual(error, .staleGeneration)
        }
        let generation = await coordinator.generation
        let approved = await coordinator.approvedMetrics
        XCTAssertEqual(generation, 2)
        XCTAssertTrue(approved.isEmpty, "the owner removed the metric, so the bridge stops reading it")

        do {
            _ = try await coordinator.preview()
            XCTFail("the stale batch must not survive")
        } catch let error as MirrorError {
            XCTAssertEqual(error, .nothingPreviewed)
        }
    }

    func testApplyWithoutPreviewIsRefused() async throws {
        MockURLProtocol.reset(script: [registry(generation: 1, [hr: "active"])])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        try await coordinator.stage([sample("s-1")])
        let unseen = try JSONDecoder().decode(MirrorPreview.self, from: Data(
            #"{"generation":1,"declared":[],"samples":[{"sampleUuid":"s-1","metric":"x","action":"create"}],"summary":{"total":1,"create":1,"unchanged":0,"conflict":0,"excluded":0,"byPillar":{}}}"#.utf8))
        do {
            _ = try await coordinator.apply(approval: OwnerApproval(approving: unseen))
            XCTFail("expected nothingPreviewed")
        } catch let error as MirrorError {
            XCTAssertEqual(error, .nothingPreviewed)
        }
    }

    func testStageCapsTheBatchAndReturnsTheRest() async throws {
        MockURLProtocol.reset(script: [registry(generation: 1, [hr: "active"])])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        let many = (0..<(MirrorCoordinator.maxBatch + 7)).map { sample("s-\($0)") }
        let leftover = try await coordinator.stage(many)
        XCTAssertEqual(leftover.count, 7)
        XCTAssertEqual(ledger.counts()[.pendingMirror], MirrorCoordinator.maxBatch)
    }

    func testDeclaresOnlyMetricsPIMHasNotSeen() async throws {
        MockURLProtocol.reset(script: [
            registry(generation: 1, [hr: "active"]),
            ok(#"{"action":"declare","generation":1,"applied":[{"metric":"\#(steps)","state":"proposed","previous":null}]}"#),
            registry(generation: 1, [hr: "active", steps: "proposed"]),
        ])
        let coordinator = MirrorCoordinator(client: makeClient(), ledger: ledger)
        let described = MetricDescriber().describe([hr, steps, "HKQuantityTypeIdentifierUnknownThing"])
        XCTAssertEqual(described.undescribed, ["HKQuantityTypeIdentifierUnknownThing"], "an undescribable type is reported, not guessed")

        let declared = try await coordinator.declare(described.descriptors)
        XCTAssertEqual(declared, [steps])
        let sent = try body(MockURLProtocol.captured[1])
        XCTAssertEqual((sent["descriptors"] as? [[String: Any]])?.compactMap { $0["metric"] as? String }, [steps])
        let approved = await coordinator.approvedMetrics
        XCTAssertEqual(approved, [hr], "declaring approves nothing")
    }

    func testDescriberCanBeExtendedAtRuntime() {
        let extra = MetricDescriptor(metric: "HKQuantityTypeIdentifierBodyMass", kind: .quantity, unit: "kg",
                                     loinc: "29463-7", appleCategory: "Body Measurements")
        XCTAssertNil(MetricDescriber().descriptor(for: extra.metric))
        XCTAssertEqual(MetricDescriber().adding([extra]).descriptor(for: extra.metric), extra)
    }
}
