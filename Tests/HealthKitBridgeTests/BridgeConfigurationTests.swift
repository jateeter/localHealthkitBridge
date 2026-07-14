import XCTest
@testable import HealthKitBridge

final class BridgeConfigurationTests: XCTestCase {

    func testLoadPrefersInfoPlistOverEnvironment() {
        let config = BridgeConfiguration.load(
            info: ["HealthKitBridgePEBaseURL": "http://192.168.1.10:5300",
                   "HealthKitBridgeToken": "plist-token"],
            environment: ["HEALTHKIT_PE_BASE_URL": "http://ignored:1",
                          "HEALTHKIT_BRIDGE_TOKEN": "env-token"]
        )
        XCTAssertEqual(config?.peBaseURL.absoluteString, "http://192.168.1.10:5300")
        XCTAssertEqual(config?.bridgeToken, "plist-token")
    }

    func testLoadFallsBackToEnvironment() {
        let config = BridgeConfiguration.load(
            info: [:],
            environment: ["HEALTHKIT_PE_BASE_URL": "http://127.0.0.1:3004"]
        )
        XCTAssertEqual(config?.peBaseURL.absoluteString, "http://127.0.0.1:3004")
        XCTAssertEqual(config?.bridgeId, "healthkit-ios-bridge")
        XCTAssertNil(config?.bridgeToken)
    }

    func testLoadReturnsNilWithoutBaseURL() {
        XCTAssertNil(BridgeConfiguration.load(info: [:], environment: [:]))
    }

    func testDefaultRetrySchedule() {
        let config = BridgeConfiguration(peBaseURL: URL(string: "http://x")!)
        XCTAssertEqual(config.retryDelays, [2, 4, 8])
    }
}
