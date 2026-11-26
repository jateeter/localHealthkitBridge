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
///
/// Clock (RealityEngine_CI#600, INGEST_CONTRACT.md "Clock"): with a
/// `ParticipantClock`, every attempt is a send stamped `RE-Clock`, every
/// response is a receive, and the ingest body carries the batch's `clock`.
public actor IngestClient {
    public let configuration: BridgeConfiguration
    public let clock: ParticipantClock?
    private let session: URLSession
    /// Injectable for tests — production uses Task.sleep.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        configuration: BridgeConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        clock: ParticipantClock? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        Self.applyTransportProfile(to: sessionConfiguration)
        self.configuration = configuration
        self.clock = clock
        self.session = URLSession(configuration: sessionConfiguration)
        self.sleeper = sleeper
    }

    /// Holds an `https` PE to TLS 1.3, the only version the install's transport
    /// profile accepts (RealityEngine_CI `config/transport-profile.json`,
    /// localHealthkitBridge#52). The server is verified by the OS trust store,
    /// which holds the install CA once its configuration profile is installed
    /// and fully trusted (docs/INGEST_CONTRACT.md, "Transport"); verification
    /// is never disabled. A plain `http` PE (a lane with RE_TLS off) is
    /// unaffected.
    public static func applyTransportProfile(to sessionConfiguration: URLSessionConfiguration) {
        #if !canImport(FoundationNetworking)
        sessionConfiguration.tlsMinimumSupportedProtocolVersion = .TLSv13
        sessionConfiguration.tlsMaximumSupportedProtocolVersion = .TLSv13
        #endif
    }

    /// `batchClock` is the clock the batch was stored with when it was created
    /// (`ParticipantClock.stampStore()`); without one the batch is stored now.
    public func ingest(
        samples: [IngestSample], anchorToken: String? = nil, resyncId: String? = nil,
        batchClock: ClockStamp? = nil
    ) async throws -> IngestResult {
        let stored: ClockStamp?
        if let batchClock {
            stored = batchClock
        } else {
            stored = try await clockStore()
        }
        let body = IngestRequestBody(
            bridgeId: configuration.bridgeId,
            anchorToken: anchorToken,
            resyncId: resyncId,
            clock: stored,
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
                let (data, response, sent) = try await exchange(request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = .invalidResponse
                    continue
                }
                let peClock = http.value(forHTTPHeaderField: ParticipantClock.headerName).flatMap(ParticipantClock.parse)
                switch http.statusCode {
                case 200, 207, 400:
                    // 400 (all unmapped) is a contract-level answer, not a
                    // transport failure — decode and surface it.
                    let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
                    return IngestResult(statusCode: http.statusCode, response: decoded, attempts: attempts,
                                        sentClock: sent, peClock: peClock)
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
        if let token = configuration.bridgeToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response, _) = try await exchange(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do {
            return try JSONDecoder().decode(BridgeStatus.self, from: data)
        } catch {
            throw BridgeError.invalidResponse
        }
    }

    /// One request: a send stamped with a fresh tick, its response a receive.
    /// A clock that cannot persist fails the request rather than reuse a tick.
    private func exchange(_ request: URLRequest) async throws -> (Data, URLResponse, ClockStamp?) {
        var request = request
        var sent: ClockStamp?
        if let clock {
            do {
                let header = try await clock.stampSend()
                request.setValue(header, forHTTPHeaderField: ParticipantClock.headerName)
                sent = ParticipantClock.parse(header)
            } catch {
                throw BridgeError.clock(String(describing: error))
            }
        }
        let (data, response) = try await session.data(for: request)
        if let clock {
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: ParticipantClock.headerName)
            do {
                try await clock.receive(header: header)
            } catch {
                throw BridgeError.clock(String(describing: error))
            }
        }
        return (data, response, sent)
    }

    private func clockStore() async throws -> ClockStamp? {
        guard let clock else { return nil }
        do {
            return try await clock.stampStore()
        } catch {
            throw BridgeError.clock(String(describing: error))
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: configuration.peBaseURL) ?? configuration.peBaseURL
    }
}
