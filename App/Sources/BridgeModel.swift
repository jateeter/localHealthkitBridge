import Foundation
import HealthKit
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
        let environment = ProcessInfo.processInfo.environment
        peBaseURL = launchArgumentValue(for: "peBaseURL")
            ?? environment["PE_BASE_URL"]
            ?? environment["HEALTHKIT_PE_BASE_URL"]
            ?? defaults.string(forKey: "peBaseURL")
            ?? (info?["HealthKitBridgePEBaseURL"] as? String)
            ?? "http://127.0.0.1:3004"
        bridgeId = launchArgumentValue(for: "bridgeId")
            ?? environment["HEALTHKIT_BRIDGE_ID"]
            ?? defaults.string(forKey: "bridgeId")
            ?? "healthkit-ios-bridge"
        bridgeToken = launchArgumentValue(for: "bridgeToken")
            ?? environment["HEALTHKIT_BRIDGE_TOKEN"]
            ?? environment["BRIDGE_TOKEN"]
            ?? defaults.string(forKey: "bridgeToken")
            ?? ""
        applyConfiguration()
    }

    /// Rebuild the coordinator from the current settings and persist them.
    func applyConfiguration() {
        let enteredBaseURL = peBaseURL
        guard let url = BridgeConfiguration.normalizedBaseURL(from: enteredBaseURL) else {
            appendLocal(.failed, "Invalid PE base URL: \(peBaseURL)")
            return
        }
        peBaseURL = url.absoluteString
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
        print("HealthKitBridge configured peBaseURL=\(url.absoluteString) bridgeId=\(bridgeId) tokenConfigured=\(!bridgeToken.isEmpty)")
        if enteredBaseURL != peBaseURL {
            appendLocal(.info, "Normalized PE base URL to \(peBaseURL)")
        }
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
            Task { await coordinator?.stopSilenceWatchdog() }
        } else {
            manager.startObservers()
            observing = true
            appendLocal(.info, "Anchored observers started (background delivery armed)")
            let minutes = UserDefaults.standard.double(forKey: "silenceThresholdMinutes")
            let threshold = (minutes > 0 ? minutes : 30) * 60
            Task { await coordinator?.startSilenceWatchdog(threshold: threshold) }
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
        print("HealthKitBridge test batch requested sampleCount=\(samples.count) peBaseURL=\(peBaseURL)")
        await coordinator?.deliver(samples)
    }

#if DEBUG
    /// e2e hook (`-seedHealthData 1`): combined read+write authorization,
    /// seed nominal samples, then arm the observers — fully hands-off apart
    /// from the permission sheet, which the UI test accepts.
    func seedAndObserve() async {
        do {
            try await DebugSeeder.seed(store: HKHealthStore())
            authorized = true
            appendLocal(.info, "Seeded debug Health data")
        } catch {
            appendLocal(.failed, "Seed failed: \(error.localizedDescription)")
            return
        }
        if !observing { toggleObservers() }
    }
#endif

    func refreshStatus() async {
        statusError = nil
        status = await coordinator?.fetchStatus()
        if status == nil { statusError = "PE status unreachable at \(peBaseURL)" }
    }

    private func appendLocal(_ kind: SyncEvent.Kind, _ message: String) {
        log.insert(SyncEvent(kind: kind, message: message), at: 0)
    }
}

func launchArgumentValue(for key: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    let flag = "-\(key)"
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else { return nil }
    let value = arguments[valueIndex]
    return value.hasPrefix("-") ? nil : value
}

func launchArgumentBool(for key: String) -> Bool {
    guard let value = launchArgumentValue(for: key) else {
        return ProcessInfo.processInfo.arguments.contains("-\(key)")
    }
    return !["0", "false", "no"].contains(value.lowercased())
}

func launchEnvironmentBool(_ keys: String...) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return keys.contains { key in
        guard let value = environment[key] else { return false }
        return !["0", "false", "no"].contains(value.lowercased())
    }
}
