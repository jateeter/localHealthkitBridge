import Foundation
import SwiftUI
import HealthKitBridge

/// Observable façade over the HealthKitBridge package for the SwiftUI host.
/// Owns the coordinator, the HealthKit manager, the sync log, and the
/// user-editable configuration (persisted to UserDefaults).
@MainActor
final class BridgeModel: ObservableObject {
    @Published var peBaseURL: String
    @Published var bridgeId: String
    @Published var bridgeToken: String

    @Published private(set) var log: [SyncEvent] = []
    @Published private(set) var status: BridgeStatus?
    @Published private(set) var statusError: String?
    @Published private(set) var authorized = false
    @Published private(set) var observing = false

    private var coordinator: BridgeCoordinator?
    private var manager: HealthKitManager?
    private var eventTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        let info = Bundle.main.infoDictionary
        peBaseURL = defaults.string(forKey: "peBaseURL")
            ?? (info?["HealthKitBridgePEBaseURL"] as? String)
            ?? "http://127.0.0.1:3004"
        bridgeId = defaults.string(forKey: "bridgeId") ?? "healthkit-ios-bridge"
        bridgeToken = defaults.string(forKey: "bridgeToken") ?? ""
        applyConfiguration()
    }

    /// Rebuild the coordinator from the current settings and persist them.
    func applyConfiguration() {
        guard let url = URL(string: peBaseURL), url.scheme != nil else {
            appendLocal(.failed, "Invalid PE base URL: \(peBaseURL)")
            return
        }
        defaults.set(peBaseURL, forKey: "peBaseURL")
        defaults.set(bridgeId, forKey: "bridgeId")
        defaults.set(bridgeToken, forKey: "bridgeToken")

        let config = BridgeConfiguration(
            peBaseURL: url,
            bridgeId: bridgeId,
            bridgeToken: bridgeToken.isEmpty ? nil : bridgeToken
        )
        let coordinator = BridgeCoordinator(configuration: config)
        self.coordinator = coordinator
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in await coordinator.events() {
                self?.log.insert(event, at: 0)
                if let count = self?.log.count, count > 200 {
                    self?.log.removeLast(count - 200)
                }
            }
        }
        // The manager forwards each de-anchored, normalized batch to the PE.
        manager?.stopObservers()
        observing = false
        manager = HealthKitManager(onBatch: { samples in
            Task { await coordinator.deliver(samples) }
        })
        appendLocal(.info, "Configured for \(url.absoluteString) as \(bridgeId)")
    }

    func authorize() async {
        guard HealthKitManager.isAvailable else {
            appendLocal(.failed, "HealthKit is not available on this device")
            return
        }
        do {
            try await manager?.requestAuthorization()
            authorized = true
            appendLocal(.info, "HealthKit read authorization granted")
        } catch {
            appendLocal(.failed, "Authorization failed: \(error.localizedDescription)")
        }
    }

    func toggleObservers() {
        guard let manager else { return }
        if observing {
            manager.stopObservers()
            observing = false
            appendLocal(.info, "Observers stopped")
        } else {
            manager.startObservers()
            observing = true
            appendLocal(.info, "Anchored observers started (background delivery armed)")
        }
    }

    /// Push one nominal sample per family — used to verify connectivity
    /// without seeded Health data (and by the e2e -autoTestPush path).
    func sendTestBatch() async {
        let samples = [
            SampleNormalizer.bloodPressure(systolicMmHg: 120, diastolicMmHg: 78, pulseBpm: 64, sourceName: "HK Bridge Test"),
            SampleNormalizer.exercise(activeEnergyKcal: 320, exerciseMinutes: 42, steps: 6100, sourceName: "HK Bridge Test"),
            SampleNormalizer.sleep(totalHours: 7.2, remHours: 1.6, coreHours: 4.0, sourceName: "HK Bridge Test"),
        ]
        await coordinator?.deliver(samples)
    }

    func refreshStatus() async {
        statusError = nil
        status = await coordinator?.fetchStatus()
        if status == nil { statusError = "PE status unreachable at \(peBaseURL)" }
    }

    private func appendLocal(_ kind: SyncEvent.Kind, _ message: String) {
        log.insert(SyncEvent(kind: kind, message: message), at: 0)
    }
}
