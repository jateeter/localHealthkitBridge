import Foundation

/// Configuration for the PIM mirror client (docs/MIRROR_CONTRACT.md §6).
/// Separate from `BridgeConfiguration`: the PE and the PIM are different
/// services with different tokens, and ingest does not depend on the mirror.
public struct PIMConfiguration: Sendable, Equatable {
    public var pimBaseURL: URL
    public var bridgeId: String
    /// Sent as `Authorization: Bearer <token>`; PIM's `PIM_HEALTHKIT_BRIDGE_TOKEN`.
    public var pimToken: String?
    public var retryDelays: [TimeInterval]
    public var requestTimeout: TimeInterval

    public init(
        pimBaseURL: URL,
        bridgeId: String = "healthkit-ios-bridge",
        pimToken: String? = nil,
        retryDelays: [TimeInterval] = [2, 4, 8],
        requestTimeout: TimeInterval = 30
    ) {
        self.pimBaseURL = pimBaseURL
        self.bridgeId = bridgeId
        self.pimToken = pimToken
        self.retryDelays = retryDelays
        self.requestTimeout = requestTimeout
    }

    /// Loads from an Info.plist-style dictionary, falling back to the
    /// environment. Keys:
    ///   - `HealthKitBridgePIMBaseURL` / env `HEALTHKIT_PIM_BASE_URL` (required)
    ///   - `HealthKitBridgeId`         / env `HEALTHKIT_BRIDGE_ID`
    ///   - `HealthKitBridgePIMToken`   / env `HEALTHKIT_PIM_TOKEN`
    public static func load(
        info: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PIMConfiguration? {
        func value(_ infoKey: String, _ envKey: String) -> String? {
            if let s = info?[infoKey] as? String, !s.isEmpty { return s }
            if let s = environment[envKey], !s.isEmpty { return s }
            return nil
        }
        guard let raw = value("HealthKitBridgePIMBaseURL", "HEALTHKIT_PIM_BASE_URL"),
              let url = BridgeConfiguration.normalizedBaseURL(from: raw) else { return nil }
        return PIMConfiguration(
            pimBaseURL: url,
            bridgeId: value("HealthKitBridgeId", "HEALTHKIT_BRIDGE_ID") ?? "healthkit-ios-bridge",
            pimToken: value("HealthKitBridgePIMToken", "HEALTHKIT_PIM_TOKEN")
        )
    }
}

/// HTTP client for PIM's HealthKit mirror routes. The bridge holds no Solid
/// session: PIM is the only writer to the POD (MIRROR_CONTRACT §1).
///
/// Retries 5xx and transport failures on `retryDelays`. Retrying `apply` is
/// safe because PIM reconciles on the measurement key, so a retry of a batch
/// that landed comes back `unchanged`. 4xx answers are final.
public actor PIMClient {
    public static let ownerApprovalHeader = "x-opencommons-owner-approved"

    private let configuration: PIMConfiguration
    private let session: URLSession
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(
        configuration: PIMConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        self.session = URLSession(configuration: sessionConfiguration)
        self.sleeper = sleeper
    }

    /// `GET /api/integrations/healthkit/metrics`: the owner's registry.
    public func metrics() async throws -> MetricRegistry {
        try await send("GET", "/api/integrations/healthkit/metrics", body: Optional<Empty>.none)
    }

    /// Declares metrics as HealthKit authorizes them. They start `proposed`
    /// and mirror nothing until the owner adds them; declaring grants nothing,
    /// so it needs no approval.
    public func declare(_ descriptors: [MetricDescriptor]) async throws -> MetricChangeResult {
        try await send("POST", "/api/integrations/healthkit/metrics",
                       body: DeclareBody(descriptors: descriptors))
    }

    /// `POST sync/preview`: PIM maps and reconciles the batch and writes nothing.
    public func preview(_ batch: MirrorBatch) async throws -> MirrorPreview {
        try await send("POST", "/api/integrations/healthkit/sync/preview", body: stamped(batch))
    }

    /// `POST sync/apply` with the owner-approval header. Refused locally,
    /// before any request, when `approval` was given for a different batch.
    public func apply(_ batch: MirrorBatch, approval: OwnerApproval) async throws -> MirrorApplyResult {
        guard approval.covers(batch) else { throw MirrorError.approvalDoesNotMatchBatch }
        return try await send("POST", "/api/integrations/healthkit/sync/apply",
                              body: stamped(batch), ownerApproved: true)
    }

    // MARK: - Transport

    private struct Empty: Encodable {}
    private struct DeclareBody: Encodable {
        let action = "declare"
        let descriptors: [MetricDescriptor]
    }
    private struct Envelope<T: Decodable>: Decodable { let data: T }

    private func stamped(_ batch: MirrorBatch) -> MirrorBatch {
        var batch = batch
        batch.bridgeId = batch.bridgeId ?? configuration.bridgeId
        return batch
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        ownerApproved: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: path, relativeTo: configuration.pimBaseURL) ?? configuration.pimBaseURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = configuration.pimToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if ownerApproved {
            request.setValue("true", forHTTPHeaderField: Self.ownerApprovalHeader)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        var lastError = MirrorError.transport("no attempt made")
        for attempt in 0...configuration.retryDelays.count {
            if attempt > 0 { await sleeper(configuration.retryDelays[attempt - 1]) }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = .transport(String(describing: type(of: error)))
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw MirrorError.invalidResponse }
            switch http.statusCode {
            case 200:
                do {
                    return try JSONDecoder().decode(Envelope<Response>.self, from: data).data
                } catch {
                    throw MirrorError.invalidResponse
                }
            case 400: throw MirrorError.invalidRequest
            case 401: throw MirrorError.unauthorized
            case 403: throw MirrorError.ownerApprovalRequired
            case 409: throw MirrorError.staleGeneration
            case 500...:
                lastError = .httpStatus(http.statusCode)
                continue
            default:
                throw MirrorError.httpStatus(http.statusCode)
            }
        }
        throw lastError
    }
}
