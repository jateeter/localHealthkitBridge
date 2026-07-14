import Foundation

/// One line in the app-visible sync log.
public struct SyncEvent: Identifiable, Sendable {
    public enum Kind: Sendable { case delivered, unmapped, failed, info }
    public let id = UUID()
    public let date: Date
    public let kind: Kind
    public let message: String

    public init(date: Date = Date(), kind: Kind, message: String) {
        self.date = date
        self.kind = kind
        self.message = message
    }
}

/// Ties sample batches (from HealthKitManager or a simulator source) to the
/// IngestClient and publishes a bounded sync log via an AsyncStream.
public actor BridgeCoordinator {
    public private(set) var client: IngestClient
    public private(set) var lastSync: Date?
    private var continuation: AsyncStream<SyncEvent>.Continuation?
    /// Monotonic batch counter used as the anchorToken echo.
    private var batchCounter = 0

    public init(configuration: BridgeConfiguration) {
        self.client = IngestClient(configuration: configuration)
    }

    public func reconfigure(_ configuration: BridgeConfiguration) {
        client = IngestClient(configuration: configuration)
        emit(.init(kind: .info, message: "Reconfigured → \(configuration.peBaseURL.absoluteString)"))
    }

    /// The app consumes this stream to render the sync log.
    public func events() -> AsyncStream<SyncEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Delivers one batch, mapping the outcome onto sync-log events.
    public func deliver(_ samples: [IngestSample]) async {
        guard !samples.isEmpty else { return }
        batchCounter += 1
        do {
            let result = try await client.ingest(samples: samples, anchorToken: "batch-\(batchCounter)")
            lastSync = Date()
            let resolved = result.response.resolved.compactMap(\.sensorId)
            if !resolved.isEmpty {
                emit(.init(kind: .delivered, message: "HTTP \(result.statusCode) → \(resolved.joined(separator: ", "))"))
            }
            for miss in result.response.unmapped {
                emit(.init(kind: .unmapped, message: "\(miss.type ?? "?"): \(miss.reason ?? "unmapped")"))
            }
        } catch BridgeError.unauthorized {
            emit(.init(kind: .failed, message: "401 — bridge token rejected"))
        } catch {
            emit(.init(kind: .failed, message: String(describing: error)))
        }
    }

    public func fetchStatus() async -> BridgeStatus? {
        try? await client.status()
    }

    private func emit(_ event: SyncEvent) {
        continuation?.yield(event)
    }
}
