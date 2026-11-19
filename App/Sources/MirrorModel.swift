import Foundation
import SwiftUI
import HealthKitBridge

/// The HealthKit → PIM → POD mirror from the phone (MIRROR_CONTRACT §6, §7;
/// localHealthkitBridge#58, RealityEngine_CI#808): the app drives
/// `MirrorCoordinator` against PIM's device listener (PIM#91).
///
/// Consent is the contract's: declaring grants nothing, only metrics the owner
/// has made `active` are read and staged, and nothing is written until the
/// owner approves the preview of that batch. The approval is the owner's tap on
/// "Approve and apply"; a Debug build also takes `-autoApproveMirrorBatch 1`
/// for the unattended device test (owner decision, 2026-11-19), which Release
/// builds compile out.
///
/// Diagnostics print flags and PHI-safe counts only: the console is captured
/// off the device by the e2e runs.
@MainActor
final class MirrorModel: ObservableObject {
    static let shared = MirrorModel()

    /// The window the preview reads from Apple Health.
    static let readWindow: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var preview: MirrorPreview?
    @Published private(set) var lastApplied: MirrorApplyResult?
    @Published private(set) var message = "The mirror to PIM has not run."
    @Published private(set) var busy = false

    private var coordinator: MirrorCoordinator?
    private var configuredFor: String?

    /// Builds the client for `baseURL` and `token`, reusing the coordinator
    /// while they are unchanged (it holds the staged batch and its preview).
    private func coordinator(baseURL: String, token: String) -> MirrorCoordinator? {
        let key = "\(baseURL)\u{1F}\(token)"
        if key == configuredFor, let coordinator { return coordinator }
        guard let url = BridgeConfiguration.normalizedBaseURL(from: baseURL) else {
            message = "The PIM base URL is not valid."
            return nil
        }
        let client = PIMClient(configuration: PIMConfiguration(
            pimBaseURL: url,
            pimToken: token.isEmpty ? nil : token))
        let made = MirrorCoordinator(client: client)
        coordinator = made
        configuredFor = key
        preview = nil
        return made
    }

    /// Declares the metrics the bridge knows to PIM. Each starts `proposed`
    /// and mirrors nothing until the owner adds it.
    func declareMetrics(baseURL: String, token: String) async {
        guard let coordinator = coordinator(baseURL: baseURL, token: token) else { return }
        await run("declare") {
            let declared = try await coordinator.declare(MetricDescriber.builtIn)
            self.message = declared.isEmpty
                ? "PIM already knows every metric; approve them in PIM to mirror them."
                : "Declared \(declared.count) metric(s); each mirrors once the owner approves it in PIM."
        }
    }

    /// Reads the approved metrics from Apple Health and previews them. Nothing
    /// is written; the owner is shown the counts before approving.
    func previewFromHealthKit(baseURL: String, token: String) async {
        guard let coordinator = coordinator(baseURL: baseURL, token: token) else { return }
        await run("preview") {
            try await coordinator.refreshRegistry()
            let approved = await coordinator.approvedMetrics
            guard !approved.isEmpty else {
                self.preview = nil
                self.message = "No metric is approved for the mirror yet."
                return
            }
            let source = HealthKitMirrorSource()
            try await source.requestAuthorization(for: approved)
            let window = DateInterval(start: Date().addingTimeInterval(-Self.readWindow), end: Date())
            let samples = await source.samples(of: approved, in: window)
            try await self.stageAndPreview(samples, on: coordinator)
        }
    }

    /// Applies the previewed batch with the owner's approval of that preview.
    func approveAndApply() async {
        guard let coordinator, let preview else {
            message = "Preview a batch before approving it."
            return
        }
        await run("apply") {
            let result = try await coordinator.apply(approval: OwnerApproval(approving: preview))
            self.lastApplied = result
            self.preview = nil
            print("HealthKitBridge mirror applied=\(result.applied) unchanged=\(result.summary.unchanged) conflict=\(result.summary.conflict) excluded=\(result.summary.excluded)")
            self.message = "Applied: \(result.applied) written, \(result.summary.unchanged) unchanged, \(result.summary.conflict) held as conflicts."
        }
    }

    private func stageAndPreview(_ samples: [MirrorSample], on coordinator: MirrorCoordinator) async throws {
        try await coordinator.stage(samples)
        let result = try await coordinator.preview()
        preview = result
        let s = result.summary
        print("HealthKitBridge mirror preview total=\(s.total) create=\(s.create) unchanged=\(s.unchanged) conflict=\(s.conflict) excluded=\(s.excluded)")
        message = "Preview: \(s.create) new, \(s.unchanged) unchanged, \(s.conflict) conflicts, \(s.excluded) excluded. Approve to write them to the Pod."
    }

    private func run(_ step: String, _ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
        } catch {
            // The error's case only: never a URL, token or record.
            let reason = (error as? MirrorError).map { String(describing: $0) } ?? String(describing: type(of: error))
            print("HealthKitBridge mirror \(step) failed error=\(reason)")
            message = "The mirror \(step) failed: \(reason)."
        }
    }

#if DEBUG
    /// e2e hook (`-autoTestMirror 1`, scripts/e2e_device.sh with PIM_BASE_URL):
    /// stages synthetic samples, never the owner's Health data, and previews
    /// them; with `-autoApproveMirrorBatch 1` it applies the previewed batch.
    /// The harness has already made the test metrics `active` as the owner.
    func autoTestMirror(baseURL: String, token: String, autoApprove: Bool) async {
        guard let coordinator = coordinator(baseURL: baseURL, token: token) else { return }
        print("HealthKitBridge mirror autotest autoApprove=\(autoApprove)")
        await run("preview") {
            try await coordinator.refreshRegistry()
            let now = Date()
            let samples = [
                MirrorSample(uuid: UUID().uuidString, metric: "HKQuantityTypeIdentifierHeartRate",
                             startDate: now.addingTimeInterval(-120), endDate: now.addingTimeInterval(-120),
                             value: 61, unit: "/min", sourceName: "HK Bridge Test"),
                MirrorSample(uuid: UUID().uuidString, metric: "HKQuantityTypeIdentifierStepCount",
                             startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(-60),
                             value: 1234, unit: "count", sourceName: "HK Bridge Test"),
            ]
            try await self.stageAndPreview(samples, on: coordinator)
        }
        if autoApprove, preview != nil {
            await approveAndApply()
        }
    }
#endif
}
