import Foundation

/// One normalized sample in the ingest contract's `samples[]` array.
public struct IngestSample: Codable, Equatable, Sendable {
    public var type: String
    public var sourceName: String?
    public var unit: String
    public var values: [Double]
    public var metadata: [String: String]?

    public init(type: String, sourceName: String? = nil, unit: String, values: [Double], metadata: [String: String]? = nil) {
        self.type = type
        self.sourceName = sourceName
        self.unit = unit
        self.values = values
        self.metadata = metadata
    }
}

struct IngestRequestBody: Encodable {
    var bridgeId: String
    var anchorToken: String?
    var samples: [IngestSample]
}

/// Per-sample resolution echo from the PE. Field presence varies slightly by
/// runtime, so everything but the discriminator is optional.
public struct IngestResolution: Decodable, Sendable {
    public var resolved: Bool?
    public var unmapped: Bool?
    public var sensorId: String?
    public var type: String?
    public var sourceMappingId: String?
    public var reason: String?
}

public struct IngestResponse: Decodable, Sendable {
    public var success: Bool
    public var bridgeId: String?
    public var anchorToken: String?
    public var resolved: [IngestResolution]
    public var unmapped: [IngestResolution]
}

/// Result of one delivery attempt, including transport-level detail the UI
/// surfaces in the sync log.
public struct IngestResult: Sendable {
    public var statusCode: Int
    public var response: IngestResponse
    public var attempts: Int
}

/// GET /api/integrations/healthkit/status payload subset used by the app.
public struct BridgeStatus: Decodable, Sendable {
    public var bridgeId: String?
    public var enabled: Bool?
    public var tokenConfigured: Bool?
    public var ingestEndpoint: String?
    public var statusEndpoint: String?
}

public enum BridgeError: Error, Equatable, Sendable {
    /// Non-2xx/207 HTTP status after all retries. 401 is surfaced immediately.
    case httpStatus(Int)
    case unauthorized
    case invalidResponse
    case transport(String)
}
