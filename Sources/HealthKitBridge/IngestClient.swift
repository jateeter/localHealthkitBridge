import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the canonical ingest contract (docs/INGEST_CONTRACT.md).
///
/// Auth: `Authorization: Bearer <token>` header when the configuration has a
/// token — never placed in the body. Retries transport failures and 5xx with
/// the configured backoff schedule; 401 fails immediately (a wrong token will
/// not become right by retrying).
public actor IngestClient {
    public let configuration: BridgeConfiguration
    private let session: URLSession
    /// Injectable for tests — production uses Task.sleep.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        configuration: BridgeConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        self.configuration = configuration
        self.session = URLSession(configuration: sessionConfiguration)
        self.sleeper = sleeper
    }

    public func ingest(samples: [IngestSample], anchorToken: String? = nil) async throws -> IngestResult {
        let body = IngestRequestBody(
            bridgeId: configuration.bridgeId,
            anchorToken: anchorToken,
            samples: samples
        )
        var request = URLRequest(url: endpoint("/api/integrations/healthkit/ingest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.bridgeToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        var attempts = 0
        var lastError: BridgeError = .transport("no attempt made")
        // One initial attempt plus one per retry delay.
        for delay in [nil] + configuration.retryDelays.map(Optional.some) {
            if let delay { try await sleeper(delay) }
            attempts += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = .invalidResponse
                    continue
                }
                switch http.statusCode {
                case 200, 207, 400:
                    // 400 (all unmapped) is a contract-level answer, not a
                    // transport failure — decode and surface it.
                    let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
                    return IngestResult(statusCode: http.statusCode, response: decoded, attempts: attempts)
                case 401:
                    throw BridgeError.unauthorized
                case 500...:
                    lastError = .httpStatus(http.statusCode)
                    continue
                default:
                    throw BridgeError.httpStatus(http.statusCode)
                }
            } catch let error as BridgeError {
                throw error
            } catch is DecodingError {
                throw BridgeError.invalidResponse
            } catch {
                lastError = .transport(String(describing: error))
                continue
            }
        }
        throw lastError
    }

    public func status() async throws -> BridgeStatus {
        var request = URLRequest(url: endpoint("/api/integrations/healthkit/status"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do {
            return try JSONDecoder().decode(BridgeStatus.self, from: data)
        } catch {
            throw BridgeError.invalidResponse
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: configuration.peBaseURL) ?? configuration.peBaseURL
    }
}
