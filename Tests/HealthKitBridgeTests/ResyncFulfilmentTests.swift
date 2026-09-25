import XCTest
@testable import HealthKitBridge

/// Resync fulfilment (INGEST_CONTRACT.md, "Scope and resync"): a consumer asks
/// through the PE for a re-send; the bridge finds the request on `/status`,
/// re-reads, and sends one batch carrying `resyncId`.
final class ResyncFulfilmentTests: XCTestCase {

    private let okIngest = Data("""
    {"success": true, "bridgeId": "healthkit-ios-bridge",
     "resolved": [{"resolved": true, "sensorId": "healthkit.sleep"}], "unmapped": []}
    """.utf8)

    private func status(_ requests: String) -> Data {
        Data("""
        {"bridgeId": "healthkit-ios-bridge", "enabled": true,
         "scope": {"declared": true, "generation": 3, "types": {}, "resyncRequests": \(requests)}}
        """.utf8)
    }

    private let samples: [IngestSample] = [
        IngestSample(type: SampleNormalizer.HKType.bloodPressure, unit: "1", values: [0.6, 0.65, 0.32, 1]),
        IngestSample(type: SampleNormalizer.HKType.workout, unit: "1", values: [0.08, 0.016, 0.17, 1]),
        IngestSample(type: SampleNormalizer.HKType.sleepAnalysis, unit: "1", values: [0.72, 0.22, 0.55, 1]),
    ]

    private func makeCoordinator() -> BridgeCoordinator {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let config = BridgeConfiguration(peBaseURL: URL(string: "http://127.0.0.1:9")!, retryDelays: [])
        return BridgeCoordinator(configuration: config, sessionConfiguration: sessionConfig)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map { stream in
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
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNoScopeBlockSendsNothing() async {
        MockURLProtocol.reset(script: [.init(status: 200, body: Data(#"{"bridgeId":"healthkit-ios-bridge"}"#.utf8))])
        let done = await makeCoordinator().fulfilPendingResyncs { self.samples }
        XCTAssertEqual(done, [])
        XCTAssertEqual(MockURLProtocol.captured.count, 1, "only the /status read")
    }

    func testPendingRequestSendsOnlyItsTypesWithResyncId() async throws {
        MockURLProtocol.reset(script: [
            .init(status: 200, body: status(#"[{"id":"hk-resync-1","bridgeId":"healthkit-ios-bridge","types":["HKCategoryTypeIdentifierSleepAnalysis"],"requestedBy":"localAIStack","state":"pending"}]"#)),
            .init(status: 200, body: okIngest),
        ])
        let coordinator = makeCoordinator()
        let done = await coordinator.fulfilPendingResyncs { self.samples }
        XCTAssertEqual(done, ["hk-resync-1"])
        let ingest = try XCTUnwrap(MockURLProtocol.captured.last)
        XCTAssertEqual(ingest.url?.path, "/api/integrations/healthkit/ingest")
        let sent = try body(ingest)
        XCTAssertEqual(sent["resyncId"] as? String, "hk-resync-1")
        let types = (sent["samples"] as? [[String: Any]])?.compactMap { $0["type"] as? String }
        XCTAssertEqual(types, [SampleNormalizer.HKType.sleepAnalysis])

        // /status still shows it pending until the PE's flip is re-read: not answered twice.
        MockURLProtocol.reset(script: [
            .init(status: 200, body: status(#"[{"id":"hk-resync-1","bridgeId":"healthkit-ios-bridge","types":["HKCategoryTypeIdentifierSleepAnalysis"],"state":"pending"}]"#)),
        ])
        let again = await coordinator.fulfilPendingResyncs { self.samples }
        XCTAssertEqual(again, [])
        XCTAssertEqual(MockURLProtocol.captured.count, 1, "no second ingest")
    }

    func testOtherBridgesAndFulfilledRequestsAreIgnored() async {
        MockURLProtocol.reset(script: [
            .init(status: 200, body: status(#"[{"id":"a","bridgeId":"another-bridge","types":[],"state":"pending"},{"id":"b","bridgeId":"healthkit-ios-bridge","types":[],"state":"fulfilled"}]"#)),
        ])
        let done = await makeCoordinator().fulfilPendingResyncs { self.samples }
        XCTAssertEqual(done, [])
        XCTAssertEqual(MockURLProtocol.captured.count, 1)
    }

    func testEmptyTypesMeansEveryFamily() async throws {
        MockURLProtocol.reset(script: [
            .init(status: 200, body: status(#"[{"id":"all","types":[],"state":"pending"}]"#)),
            .init(status: 200, body: okIngest),
        ])
        let done = await makeCoordinator().fulfilPendingResyncs { self.samples }
        XCTAssertEqual(done, ["all"])
        let sent = try body(try XCTUnwrap(MockURLProtocol.captured.last))
        XCTAssertEqual((sent["samples"] as? [[String: Any]])?.count, 3)
    }

    func testOrdinaryIngestCarriesNoResyncId() async throws {
        MockURLProtocol.reset(script: [.init(status: 200, body: okIngest)])
        await makeCoordinator().deliver([samples[2]])
        let sent = try body(try XCTUnwrap(MockURLProtocol.captured.first))
        XCTAssertNil(sent["resyncId"])
    }
}
