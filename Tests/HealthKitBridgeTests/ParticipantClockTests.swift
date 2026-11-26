import XCTest
@testable import HealthKitBridge

/// The bridge as a Lamport clock participant (RealityEngine_CI#600,
/// localHealthkitBridge#49; INGEST_CONTRACT.md, "Clock").
/// Reuses `MockURLProtocol` from IngestClientTests.
final class ParticipantClockTests: XCTestCase {

    private let peer = UUID(uuidString: "01a218ae-9952-7517-a905-dd44095ec14b")!

    // MARK: - The header

    func testHeaderIsCanonical() {
        let id = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
        XCTAssertEqual(ParticipantClock.header(ClockStamp(instance: id, lamport: 42)),
                       "instance=0f8fad5b-d9cb-469f-a165-70867728950e; lamport=42")
    }

    func testParseAcceptsTheContractForm() {
        let stamp = ParticipantClock.parse("instance=01a218ae-9952-7517-a905-dd44095ec14b; lamport=1029639")
        XCTAssertEqual(stamp, ClockStamp(instance: peer, lamport: 1_029_639))
        XCTAssertEqual(ParticipantClock.parse("instance=01a218ae-9952-7517-a905-dd44095ec14b;lamport=0")?.lamport, 0)
        XCTAssertEqual(ParticipantClock.parse("instance=01a218ae-9952-7517-a905-dd44095ec14b;  lamport=9007199254740991")?.lamport,
                       ParticipantClock.maxLamport)
    }

    func testParseRefusesEverythingElse() {
        let id = "01a218ae-9952-7517-a905-dd44095ec14b"
        for bad in [
            "", "instance=\(id)", "lamport=1", "lamport=1; instance=\(id)",
            "instance=\(id); lamport=1; extra=2", "instance=\(id.uppercased()); lamport=1",
            "instance=not-a-uuid; lamport=1", "instance=\(id); lamport=-1", "instance=\(id); lamport=+1",
            "instance=\(id); lamport=01", "instance=\(id); lamport=9007199254740992", "instance=\(id); lamport=1.5",
            "instance=\(id); lamport=",
        ] {
            XCTAssertNil(ParticipantClock.parse(bad), bad)
        }
    }

    // MARK: - Ticks and persistence

    func testSendAndStoreTickAndNeverRepeat() async throws {
        let clock = try ParticipantClock(store: MemoryClockStore())
        let a = try await clock.stampStore()
        let h = try await clock.stampSend()
        let b = try await clock.stampStore()
        XCTAssertEqual(a.lamport, 1)
        XCTAssertEqual(ParticipantClock.parse(h)?.lamport, 2)
        XCTAssertEqual(b.lamport, 3)
        XCTAssertEqual(a.instance, clock.instance)
    }

    func testCounterIsMonotonicAcrossRelaunch() async throws {
        let store = MemoryClockStore()
        let first = try ParticipantClock(store: store)
        var last: UInt64 = 0
        for _ in 0..<5 { last = try await first.stampStore().lamport }
        // A relaunch (or a crash) resumes from the reserved mark, past every
        // tick the first life could have issued, with the same UUID.
        let second = try ParticipantClock(store: store)
        XCTAssertEqual(second.instance, first.instance)
        let next = try await second.stampStore().lamport
        XCTAssertGreaterThan(next, last)
        XCTAssertEqual(next, ParticipantClock.reservation + 1)
    }

    func testTickPastTheMarkReservesTheNextBlockFirst() async throws {
        let store = MemoryClockStore()
        let clock = try ParticipantClock(store: store)
        XCTAssertEqual(try store.load()?.mark, ParticipantClock.reservation)
        for _ in 0..<Int(ParticipantClock.reservation) { _ = try await clock.stampStore() }
        XCTAssertEqual(try store.load()?.mark, ParticipantClock.reservation)
        let past = try await clock.stampStore().lamport
        XCTAssertEqual(past, ParticipantClock.reservation + 1)
        XCTAssertEqual(try store.load()?.mark, past + ParticipantClock.reservation)
    }

    func testResponseAheadMovesPastIt() async throws {
        let store = MemoryClockStore()
        let clock = try ParticipantClock(store: store)
        _ = try await clock.stampSend()
        try await clock.receive(header: "instance=\(peer.uuidString.lowercased()); lamport=5000000")
        let after = await clock.lamport
        XCTAssertEqual(after, 5_000_001)
        // The jump was made durable before it was used.
        XCTAssertEqual(try store.load()?.mark, 5_000_001 + ParticipantClock.reservation)
        let relaunched = try ParticipantClock(store: store)
        let next = try await relaunched.stampStore().lamport
        XCTAssertGreaterThan(next, after)
    }

    func testResponseBehindOrAbsentOrMalformedIsALocalEvent() async throws {
        let clock = try ParticipantClock(store: MemoryClockStore())
        for _ in 0..<10 { _ = try await clock.stampStore() }
        try await clock.receive(header: "instance=\(peer.uuidString.lowercased()); lamport=3")
        var now = await clock.lamport
        XCTAssertEqual(now, 11)
        try await clock.receive(header: nil)
        now = await clock.lamport
        XCTAssertEqual(now, 12)
        try await clock.receive(header: "garbage")
        now = await clock.lamport
        XCTAssertEqual(now, 13)
    }

    func testAStoreThatCannotWriteRefusesToTick() async throws {
        let store = FailingStore()
        XCTAssertThrowsError(try ParticipantClock(store: store))
    }

    func testResetStartsANewParticipant() throws {
        let store = MemoryClockStore()
        let first = try ParticipantClock(store: store)
        try store.reset()
        let second = try ParticipantClock(store: store)
        XCTAssertNotEqual(first.instance, second.instance)
    }

    func testBodyClockEncodesLowerCase() throws {
        let id = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
        let json = String(decoding: try JSONEncoder().encode(ClockStamp(instance: id, lamport: 7)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""instance":"0f8fad5b-d9cb-469f-a165-70867728950e""#), json)
        XCTAssertTrue(json.contains(#""lamport":7"#), json)
    }

    // MARK: - On the wire to the PE

    private let okBody = Data("""
    {"success": true, "bridgeId": "healthkit-ios-bridge",
     "resolved": [{"resolved": true, "sensorId": "healthkit.heart-rate"}], "unmapped": []}
    """.utf8)

    private func peHeader(_ n: UInt64) -> [String: String] {
        [ParticipantClock.headerName: "instance=\(peer.uuidString.lowercased()); lamport=\(n)"]
    }

    private func makeIngest(clock: ParticipantClock, retryDelays: [TimeInterval] = [0, 0]) -> IngestClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        return IngestClient(
            configuration: BridgeConfiguration(peBaseURL: URL(string: "http://127.0.0.1:9")!, retryDelays: retryDelays),
            sessionConfiguration: sessionConfig, clock: clock, sleeper: { _ in })
    }

    private let sample = IngestSample(type: "HKQuantityTypeIdentifierHeartRate", unit: "count/min", values: [62])

    func testIngestStampsEveryAttemptAndAppliesTheResponse() async throws {
        let clock = try ParticipantClock(store: MemoryClockStore())
        MockURLProtocol.reset(script: [
            .init(status: 503, body: Data(), headers: peHeader(100)),
            .init(status: 200, body: okBody, headers: peHeader(9_000)),
        ])
        _ = try await makeIngest(clock: clock).ingest(samples: [sample])
        let sent = MockURLProtocol.captured.compactMap {
            $0.value(forHTTPHeaderField: ParticipantClock.headerName).flatMap(ParticipantClock.parse)
        }
        XCTAssertEqual(sent.count, 2, "each attempt is its own send")
        XCTAssertEqual(sent.map(\.instance), [clock.instance, clock.instance])
        // The retry is stamped after the 503's receive of lamport 100.
        XCTAssertGreaterThan(sent[1].lamport, 100)
        let now = await clock.lamport
        XCTAssertEqual(now, 9_001, "the response is a receive")
    }

    func testAQueuedBatchKeepsItsCreationClock() async throws {
        let clock = try ParticipantClock(store: MemoryClockStore())
        let created = try await clock.stampStore()
        // Other traffic happens while the batch waits.
        for _ in 0..<3 { _ = try await clock.stampSend() }
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody, headers: peHeader(10))])
        _ = try await makeIngest(clock: clock).ingest(samples: [sample], batchClock: created)
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        let body = try JSONSerialization.jsonObject(with: try bodyData(request)) as? [String: Any]
        let bodyClock = try XCTUnwrap(body?["clock"] as? [String: Any])
        XCTAssertEqual(bodyClock["instance"] as? String, clock.instance.uuidString.lowercased())
        XCTAssertEqual((bodyClock["lamport"] as? NSNumber)?.uint64Value, created.lamport)
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: ParticipantClock.headerName).flatMap(ParticipantClock.parse))
        XCTAssertGreaterThan(header.lamport, created.lamport, "the send is stamped when it is sent")
    }

    func testWithoutAClockNothingIsStamped() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let client = IngestClient(
            configuration: BridgeConfiguration(peBaseURL: URL(string: "http://127.0.0.1:9")!, retryDelays: []),
            sessionConfiguration: sessionConfig, sleeper: { _ in })
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody)])
        _ = try await client.ingest(samples: [sample])
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertNil(request.value(forHTTPHeaderField: ParticipantClock.headerName))
        let body = try JSONSerialization.jsonObject(with: try bodyData(request)) as? [String: Any]
        XCTAssertNil(body?["clock"])
    }

    func testCoordinatorStoresEachBatchAtCreation() async throws {
        let clock = try ParticipantClock(store: MemoryClockStore())
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let coordinator = BridgeCoordinator(
            configuration: BridgeConfiguration(peBaseURL: URL(string: "http://127.0.0.1:9")!, retryDelays: []),
            sessionConfiguration: sessionConfig, clock: clock)
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody, headers: peHeader(1))])
        await coordinator.deliver([sample])
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        let body = try JSONSerialization.jsonObject(with: try bodyData(request)) as? [String: Any]
        let stored = try XCTUnwrap((body?["clock"] as? [String: Any])?["lamport"] as? NSNumber).uint64Value
        let sent = try XCTUnwrap(request.value(forHTTPHeaderField: ParticipantClock.headerName).flatMap(ParticipantClock.parse))
        XCTAssertEqual(sent.lamport, stored + 1, "stored, then sent")
    }

    // MARK: - On the wire to PIM

    func testTheMirrorCarriesOneClockThroughPreviewAndApply() async throws {
        let clock = try ParticipantClock(store: MemoryClockStore())
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let pim = PIMClient(
            configuration: PIMConfiguration(pimBaseURL: URL(string: "http://127.0.0.1:9")!, bridgeId: "bridge-1",
                                            pimToken: "t", retryDelays: []),
            sessionConfiguration: sessionConfig, clock: clock, sleeper: { _ in })
        let suite = "clock-mirror-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = MirrorCoordinator(client: pim, ledger: MirrorLedger(defaults: defaults))
        let hr = "HKQuantityTypeIdentifierHeartRate"
        let registry = #"{"data":{"generation":1,"metrics":{"\#(hr)":{"metric":"\#(hr)","kind":"quantity","state":"active","target":{"kind":"pillar","pillar":"vital-signs"}}}}}"#
        let outcome = #"{"sampleUuid":"s-1","metric":"\#(hr)","action":"create","pillar":"vital-signs","mirrorState":"mirrored"}"#
        let summary = #"{"total":1,"create":1,"unchanged":0,"conflict":0,"excluded":0,"byPillar":{}}"#
        let preview = #"{"data":{"generation":1,"declared":[],"samples":[\#(outcome)],"summary":\#(summary)}}"#
        let applied = #"{"data":{"generation":1,"declared":[],"samples":[\#(outcome)],"summary":\#(summary),"applied":1}}"#
        MockURLProtocol.reset(script: [
            .init(status: 200, body: Data(registry.utf8)),
            .init(status: 200, body: Data(preview.utf8)),
            .init(status: 200, body: Data(applied.utf8)),
        ])
        _ = try await coordinator.stage([MirrorSample(uuid: "s-1", metric: hr, startDate: Date(timeIntervalSince1970: 1_790_000_000),
                                                      value: 62, unit: "/min")])
        let shown = try await coordinator.preview()
        _ = try await coordinator.apply(approval: OwnerApproval(approving: shown))

        let requests = MockURLProtocol.captured
        XCTAssertEqual(requests.count, 3)
        let headers = requests.compactMap { $0.value(forHTTPHeaderField: ParticipantClock.headerName).flatMap(ParticipantClock.parse) }
        XCTAssertEqual(headers.count, 3, "every PIM request is a send")
        XCTAssertEqual(headers.map(\.lamport), headers.map(\.lamport).sorted())
        let clocks = try requests.dropFirst().map { request -> [String: Any] in
            let body = try JSONSerialization.jsonObject(with: try bodyData(request)) as? [String: Any]
            return try XCTUnwrap(body?["clock"] as? [String: Any])
        }
        XCTAssertEqual(clocks.count, 2)
        XCTAssertEqual(clocks[0]["lamport"] as? NSNumber, clocks[1]["lamport"] as? NSNumber,
                       "preview and apply of one batch carry its staging clock")
    }

    // MARK: - Helpers

    private func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private struct FailingStore: ClockStore {
    func load() throws -> ClockState? { nil }
    func save(_ state: ClockState) throws { throw ClockError.store("read-only") }
    func reset() throws {}
}
