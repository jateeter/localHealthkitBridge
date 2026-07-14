import XCTest
@testable import HealthKitBridge

/// URLProtocol mock capturing requests and replaying scripted responses.
final class MockURLProtocol: URLProtocol {
    struct Scripted {
        var status: Int
        var body: Data
    }

    nonisolated(unsafe) static var script: [Scripted] = []
    nonisolated(unsafe) static var captured: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(script: [Scripted]) {
        lock.lock(); defer { lock.unlock() }
        self.script = script
        self.captured = []
    }

    static func next() -> Scripted? {
        lock.lock(); defer { lock.unlock() }
        return script.isEmpty ? nil : script.removeFirst()
    }

    static func capture(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capture(request)
        guard let step = Self.next() else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: step.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class IngestClientTests: XCTestCase {

    private let okBody = Data("""
    {"success": true, "bridgeId": "healthkit-ios-bridge",
     "resolved": [{"resolved": true, "sensorId": "healthkit.blood-pressure"}],
     "unmapped": []}
    """.utf8)

    private func makeClient(token: String? = nil, retryDelays: [TimeInterval] = [0, 0, 0]) -> IngestClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let config = BridgeConfiguration(
            peBaseURL: URL(string: "http://127.0.0.1:9")!,
            bridgeToken: token,
            retryDelays: retryDelays
        )
        // No-op sleeper: retries execute immediately in tests.
        return IngestClient(configuration: config, sessionConfiguration: sessionConfig, sleeper: { _ in })
    }

    private var sample: IngestSample {
        SampleNormalizer.bloodPressure(systolicMmHg: 144, diastolicMmHg: 57.6, pulseBpm: 48)
    }

    func testPostsCanonicalPathAndBody() async throws {
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody)])
        let result = try await makeClient().ingest(samples: [sample], anchorToken: "batch-1")

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertTrue(result.response.success)
        XCTAssertEqual(result.attempts, 1)

        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/api/integrations/healthkit/ingest")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        })
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["bridgeId"] as? String, "healthkit-ios-bridge")
        XCTAssertEqual(decoded["anchorToken"] as? String, "batch-1")
        XCTAssertEqual((decoded["samples"] as? [[String: Any]])?.count, 1)
        // Token never travels in the body.
        XCTAssertNil(decoded["bridgeToken"])
    }

    func testBearerHeaderSentWhenTokenConfigured() async throws {
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody)])
        _ = try await makeClient(token: "secret-token").ingest(samples: [sample])
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testNoAuthorizationHeaderWithoutToken() async throws {
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody)])
        _ = try await makeClient().ingest(samples: [sample])
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedFailsImmediatelyWithoutRetry() async {
        MockURLProtocol.reset(script: [
            .init(status: 401, body: Data("{\"error\":\"invalid HealthKit bridge token\"}".utf8)),
            .init(status: 200, body: okBody),
        ])
        do {
            _ = try await makeClient(token: "wrong").ingest(samples: [sample])
            XCTFail("expected unauthorized")
        } catch let error as BridgeError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(MockURLProtocol.captured.count, 1, "401 must not be retried")
    }

    func testServerErrorsRetryThenSucceed() async throws {
        MockURLProtocol.reset(script: [
            .init(status: 500, body: Data()),
            .init(status: 503, body: Data()),
            .init(status: 200, body: okBody),
        ])
        let result = try await makeClient().ingest(samples: [sample])
        XCTAssertEqual(result.attempts, 3)
        XCTAssertEqual(MockURLProtocol.captured.count, 3)
    }

    func testExhaustedRetriesThrowLastStatus() async {
        MockURLProtocol.reset(script: [
            .init(status: 500, body: Data()),
            .init(status: 500, body: Data()),
            .init(status: 500, body: Data()),
            .init(status: 500, body: Data()),
        ])
        do {
            _ = try await makeClient().ingest(samples: [sample])
            XCTFail("expected failure")
        } catch let error as BridgeError {
            XCTAssertEqual(error, .httpStatus(500))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // 1 initial + 3 retries.
        XCTAssertEqual(MockURLProtocol.captured.count, 4)
    }

    func testAllUnmappedIsAContractAnswerNotAFailure() async throws {
        let body = Data("""
        {"success": false, "resolved": [],
         "unmapped": [{"unmapped": true, "type": "HKX", "reason": "no registry mapping"}]}
        """.utf8)
        MockURLProtocol.reset(script: [.init(status: 400, body: body)])
        let result = try await makeClient().ingest(samples: [sample])
        XCTAssertEqual(result.statusCode, 400)
        XCTAssertFalse(result.response.success)
        XCTAssertEqual(result.response.unmapped.first?.reason, "no registry mapping")
    }

    func testStatusEndpoint() async throws {
        let body = Data("""
        {"bridgeId": "healthkit-ios-bridge", "enabled": true, "tokenConfigured": true,
         "ingestEndpoint": "/api/integrations/healthkit/ingest",
         "statusEndpoint": "/api/integrations/healthkit/status"}
        """.utf8)
        MockURLProtocol.reset(script: [.init(status: 200, body: body)])
        let status = try await makeClient().status()
        XCTAssertEqual(status.tokenConfigured, true)
        XCTAssertEqual(status.ingestEndpoint, "/api/integrations/healthkit/ingest")
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/api/integrations/healthkit/status")
    }
}
