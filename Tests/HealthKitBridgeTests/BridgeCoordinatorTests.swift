import XCTest
@testable import HealthKitBridge

/// Silent-failure watchdog behavior (roadmap M5): one `.alert` per silence
/// episode after the threshold, re-armed by the next successful delivery.
final class BridgeCoordinatorTests: XCTestCase {

    private let okBody = Data("""
    {"success": true, "bridgeId": "healthkit-ios-bridge",
     "resolved": [{"resolved": true, "sensorId": "healthkit.bp"}],
     "unmapped": []}
    """.utf8)

    private func makeCoordinator() -> BridgeCoordinator {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let config = BridgeConfiguration(
            peBaseURL: URL(string: "http://127.0.0.1:9")!,
            retryDelays: []
        )
        return BridgeCoordinator(configuration: config, sessionConfiguration: sessionConfig)
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SyncEvent] = []
        func append(_ e: SyncEvent) { lock.lock(); storage.append(e); lock.unlock() }
        var events: [SyncEvent] { lock.lock(); defer { lock.unlock() }; return storage }
        func alerts() -> [SyncEvent] { events.filter { if case .alert = $0.kind { return true }; return false } }
    }

    private func collect(_ coordinator: BridgeCoordinator) async -> EventBox {
        let box = EventBox()
        let stream = await coordinator.events()
        Task { for await event in stream { box.append(event) } }
        // Give the consumer task a beat to subscribe before events flow.
        try? await Task.sleep(nanoseconds: 20_000_000)
        return box
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testSilenceAlertFiresOnceAfterThreshold() async {
        let coordinator = makeCoordinator()
        let box = await collect(coordinator)

        let base = Date()
        // Huge checkInterval: ticks are driven manually via checkSilence.
        await coordinator.startSilenceWatchdog(threshold: 100, checkInterval: 3600, clock: { base })

        await coordinator.checkSilence(now: base.addingTimeInterval(50))
        await settle()
        XCTAssertTrue(box.alerts().isEmpty, "no alert before the threshold")

        await coordinator.checkSilence(now: base.addingTimeInterval(150))
        await settle()
        XCTAssertEqual(box.alerts().count, 1, "alert after threshold")
        XCTAssertTrue(box.alerts()[0].message.contains("no delivery since launch"))

        await coordinator.checkSilence(now: base.addingTimeInterval(500))
        await settle()
        XCTAssertEqual(box.alerts().count, 1, "only one alert per silence episode")

        await coordinator.stopSilenceWatchdog()
    }

    func testSuccessfulDeliveryReArmsWatchdog() async {
        let coordinator = makeCoordinator()
        let box = await collect(coordinator)

        let base = Date()
        await coordinator.startSilenceWatchdog(threshold: 100, checkInterval: 3600, clock: { base })
        await coordinator.checkSilence(now: base.addingTimeInterval(150))
        await settle()
        XCTAssertEqual(box.alerts().count, 1)

        // A successful delivery clears the episode and moves the baseline.
        MockURLProtocol.reset(script: [.init(status: 200, body: okBody)])
        await coordinator.deliver([
            SampleNormalizer.bloodPressure(systolicMmHg: 120, diastolicMmHg: 78, pulseBpm: 64)
        ])
        await settle()

        let lastSync = await coordinator.lastSync
        XCTAssertNotNil(lastSync)

        // Quiet again: within threshold of the new baseline → no new alert…
        await coordinator.checkSilence(now: lastSync!.addingTimeInterval(50))
        await settle()
        XCTAssertEqual(box.alerts().count, 1)

        // …but a fresh silence past the threshold alerts again (re-armed).
        await coordinator.checkSilence(now: lastSync!.addingTimeInterval(150))
        await settle()
        XCTAssertEqual(box.alerts().count, 2, "watchdog re-arms after a successful delivery")
        XCTAssertTrue(box.alerts()[1].message.contains("last success"))

        await coordinator.stopSilenceWatchdog()
    }

    func testFailedDeliveryDoesNotMoveBaseline() async {
        let coordinator = makeCoordinator()
        let box = await collect(coordinator)

        let base = Date()
        await coordinator.startSilenceWatchdog(threshold: 100, checkInterval: 3600, clock: { base })

        // Scripted failure: exhausted script → connection error.
        MockURLProtocol.reset(script: [])
        await coordinator.deliver([
            SampleNormalizer.bloodPressure(systolicMmHg: 120, diastolicMmHg: 78, pulseBpm: 64)
        ])
        await settle()

        let lastSync = await coordinator.lastSync
        XCTAssertNil(lastSync, "failed delivery must not count as a sync")

        await coordinator.checkSilence(now: base.addingTimeInterval(150))
        await settle()
        XCTAssertEqual(box.alerts().count, 1, "silence measured from watchdog start when nothing ever succeeded")

        await coordinator.stopSilenceWatchdog()
    }
}
