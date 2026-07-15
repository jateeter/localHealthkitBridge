import Foundation

/// One line in the app-visible sync log.
public struct SyncEvent: Identifiable, Sendable {
    public enum Kind: Sendable { case delivered, unmapped, failed, info, alert }
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

    // Silent-failure watchdog (roadmap M5): background delivery can stop
    // quietly — device asleep, PE unreachable, token rotated.  When armed,
    // an `.alert` event fires once per silence episode after `silenceThreshold`
    // without a successful delivery; the next success re-arms it.
    private var watchdogTask: Task<Void, Never>?
    private var watchdogStartedAt: Date?
    private var silenceThreshold: TimeInterval = 30 * 60
    private var silenceAlerted = false

    public init(configuration: BridgeConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.client = IngestClient(configuration: configuration, sessionConfiguration: sessionConfiguration)
    }

    public func reconfigure(_ configuration: BridgeConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        client = IngestClient(configuration: configuration, sessionConfiguration: sessionConfiguration)
        emit(.init(kind: .info, message: "Reconfigured → \(configuration.peBaseURL.absoluteString)"))
    }

    /// Arms the silence watchdog. `clock` is injectable for tests.
    public func startSilenceWatchdog(
        threshold: TimeInterval = 30 * 60,
        checkInterval: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        watchdogTask?.cancel()
        silenceThreshold = threshold
        watchdogStartedAt = clock()
        silenceAlerted = false
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.checkSilence(now: clock())
            }
        }
        emit(.init(kind: .info, message: "Silence watchdog armed (\(Int(threshold / 60)) min)"))
    }

    public func stopSilenceWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogStartedAt = nil
        silenceAlerted = false
    }

    /// One watchdog tick. Internal so tests can drive it with synthetic clocks.
    func checkSilence(now: Date) {
        guard let started = watchdogStartedAt, !silenceAlerted else { return }
        let baseline = lastSync ?? started
        let silence = now.timeIntervalSince(baseline)
        guard silence > silenceThreshold else { return }
        silenceAlerted = true
        let minutes = Int(silence / 60)
        let last = lastSync.map { "last success \($0.formatted(date: .omitted, time: .standard))" } ?? "no delivery since launch"
        emit(.init(kind: .alert, message: "No successful delivery in \(minutes) min (\(last)) — check PE reachability, token, and Background App Refresh"))
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
            silenceAlerted = false
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
