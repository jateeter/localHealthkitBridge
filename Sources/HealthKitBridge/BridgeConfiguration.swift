import Foundation

/// Runtime configuration for the bridge.
///
/// The PE base URL must point at a Perception Engine implementing the
/// canonical ingest contract (docs/INGEST_CONTRACT.md). Prefer the runtime
/// registry (`re-registry.json`, `instances[].pe_url`) over hard-coded ports.
public struct BridgeConfiguration: Sendable, Equatable {
    public var peBaseURL: URL
    public var bridgeId: String
    /// Sent as `Authorization: Bearer <token>` when non-nil.
    public var bridgeToken: String?
    /// Backoff schedule between retry attempts; count = retry count.
    public var retryDelays: [TimeInterval]
    public var requestTimeout: TimeInterval

    public init(
        peBaseURL: URL,
        bridgeId: String = "healthkit-ios-bridge",
        bridgeToken: String? = nil,
        retryDelays: [TimeInterval] = [2, 4, 8],
        requestTimeout: TimeInterval = 15
    ) {
        self.peBaseURL = peBaseURL
        self.bridgeId = bridgeId
        self.bridgeToken = bridgeToken
        self.retryDelays = retryDelays
        self.requestTimeout = requestTimeout
    }

    /// Loads configuration from an Info.plist-style dictionary, falling back
    /// to process environment variables. Keys:
    ///   - `HealthKitBridgePEBaseURL` / env `HEALTHKIT_PE_BASE_URL` (required)
    ///   - `HealthKitBridgeId`       / env `HEALTHKIT_BRIDGE_ID`
    ///   - `HealthKitBridgeToken`    / env `HEALTHKIT_BRIDGE_TOKEN`
    public static func load(
        info: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BridgeConfiguration? {
        func value(_ infoKey: String, _ envKey: String) -> String? {
            if let s = info?[infoKey] as? String, !s.isEmpty { return s }
            if let s = environment[envKey], !s.isEmpty { return s }
            return nil
        }
        guard let raw = value("HealthKitBridgePEBaseURL", "HEALTHKIT_PE_BASE_URL"),
              let url = URL(string: raw) else { return nil }
        return BridgeConfiguration(
            peBaseURL: url,
            bridgeId: value("HealthKitBridgeId", "HEALTHKIT_BRIDGE_ID") ?? "healthkit-ios-bridge",
            bridgeToken: value("HealthKitBridgeToken", "HEALTHKIT_BRIDGE_TOKEN")
        )
    }
}
