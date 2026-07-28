import Foundation
import SwiftUI
import MobileSolidCompatModel

struct PatientInformationSource: Identifiable, Equatable {
    enum Kind {
        case healthKit
        case epic
        case solidPod
    }

    let id: Kind
    let title: String
    let subtitle: String
    let systemImage: String
    let status: String
    let detail: String
    let tint: Color
}

struct PatientMonitorDomain: Identifiable, Equatable {
    let id: String
    let title: String
    let fhirResourceType: String
    let sourceLabel: String
    let itemCount: Int
    let attentionRequired: Bool
}

@MainActor
final class MobilePodModel: ObservableObject {
    @Published var issuerURL: String
    @Published var storageIRI: String
    @Published var pimRootPath: String
    @Published var redirectURI: String
    @Published var allowInsecureLocalHTTP: Bool
    @Published private(set) var session: MobileSolidSessionSnapshot
    @Published private(set) var containers: [MobileSolidManagedContainer]
    @Published private(set) var lastStatusMessage: String

    let managedDomains = OpenCommonsHealthPodProfile.managedDomains

    private let defaults = UserDefaults.standard

    init() {
        issuerURL = defaults.string(forKey: "mobileSolid.issuerURL") ?? "http://localhost:13000/"
        storageIRI = defaults.string(forKey: "mobileSolid.storageIRI") ?? "http://localhost:13000/alice/"
        pimRootPath = defaults.string(forKey: "mobileSolid.pimRootPath") ?? "health-pim/"
        redirectURI = defaults.string(forKey: "mobileSolid.redirectURI") ?? "opencommons-health:/solid/callback"
        allowInsecureLocalHTTP = defaults.object(forKey: "mobileSolid.allowInsecureLocalHTTP") as? Bool ?? true
        session = MobileSolidSessionSnapshot(
            authenticated: false,
            webID: nil,
            storageIRI: defaults.string(forKey: "mobileSolid.storageIRI"),
            dpopEnabled: true,
            lastError: "Solid sign-in is ready for the next wiring phase."
        )
        containers = OpenCommonsHealthPodProfile.healthKitContainers
        lastStatusMessage = "Pod management UX is local-only until SolidAuthSwiftUI sign-in is wired."
    }

    var configuration: MobileSolidConfiguration {
        MobileSolidConfiguration(
            issuerURL: issuerURL,
            redirectURI: redirectURI,
            preferredStorageIRI: storageIRI.isEmpty ? nil : storageIRI,
            pimRootPath: pimRootPath,
            allowInsecureLocalHTTP: allowInsecureLocalHTTP
        )
    }

    var ownerAccessLabel: String {
        session.authenticated ? "Signed in" : "Not signed in"
    }

    var mirrorSummary: String {
        let pending = containers.filter { $0.mirrorState == .pendingMirror }.count
        let conflicts = containers.filter { $0.mirrorState == .conflict }.count
        if pending == 0 && conflicts == 0 { return "No pending mirrors" }
        return "\(pending) pending · \(conflicts) conflict\(conflicts == 1 ? "" : "s")"
    }

    var patientMonitorSources: [PatientInformationSource] {
        [
            PatientInformationSource(
                id: .healthKit,
                title: "HealthKit",
                subtitle: "iPhone health summaries",
                systemImage: "heart.text.square.fill",
                status: healthKitStatusLabel,
                detail: "Blood pressure, activity, and sleep summaries are staged for owner-approved Pod mirroring.",
                tint: .pink
            ),
            PatientInformationSource(
                id: .epic,
                title: "Epic",
                subtitle: "SMART/FHIR import",
                systemImage: "cross.case.fill",
                status: "Sandbox ready",
                detail: "Epic OAuth/FHIR data is held at the current integration level; live access remains owner-authorized.",
                tint: .blue
            ),
            PatientInformationSource(
                id: .solidPod,
                title: "Solid Pod",
                subtitle: "Owner authority",
                systemImage: "lock.shield.fill",
                status: ownerAccessLabel,
                detail: mirrorSummary,
                tint: .green
            ),
        ]
    }

    var patientMonitorDomains: [PatientMonitorDomain] {
        managedDomains.map { domain in
            PatientMonitorDomain(
                id: domain.apiName,
                title: domain.displayName,
                fhirResourceType: domain.fhirResourceType,
                sourceLabel: sourceLabel(for: domain.apiName),
                itemCount: itemCount(for: domain.apiName),
                attentionRequired: attentionRequired(for: domain.apiName)
            )
        }
    }

    var patientMonitorSummary: String {
        let visibleDomains = patientMonitorDomains.count
        let pending = containers.filter { $0.mirrorState == .pendingMirror }.count
        let conflicts = containers.filter { $0.mirrorState == .conflict }.count
        if conflicts > 0 {
            return "\(visibleDomains) domains visible · \(conflicts) conflict\(conflicts == 1 ? "" : "s") need review"
        }
        if pending > 0 {
            return "\(visibleDomains) domains visible · \(pending) Pod mirror item\(pending == 1 ? "" : "s") pending"
        }
        return "\(visibleDomains) domains visible · owner-controlled Pod monitor"
    }

    func saveConfiguration() {
        let config = configuration
        issuerURL = config.issuerURL
        storageIRI = config.preferredStorageIRI ?? ""
        pimRootPath = config.pimRootPath
        redirectURI = config.redirectURI
        allowInsecureLocalHTTP = config.allowInsecureLocalHTTP

        defaults.set(issuerURL, forKey: "mobileSolid.issuerURL")
        defaults.set(storageIRI, forKey: "mobileSolid.storageIRI")
        defaults.set(pimRootPath, forKey: "mobileSolid.pimRootPath")
        defaults.set(redirectURI, forKey: "mobileSolid.redirectURI")
        defaults.set(allowInsecureLocalHTTP, forKey: "mobileSolid.allowInsecureLocalHTTP")

        session = MobileSolidSessionSnapshot(
            authenticated: false,
            webID: nil,
            storageIRI: storageIRI.isEmpty ? nil : storageIRI,
            dpopEnabled: true,
            lastError: "Saved. Sign-in and resource CRUD wiring are the next implementation phase."
        )
        lastStatusMessage = "Saved Pod settings for \(pimRootPath)"
    }

    func markBridgeSampleQueued() {
        containers = containers.map { container in
            var next = container
            if [.observation, .bloodPressure, .workout, .sleep, .syncManifest].contains(container.resourceKind) {
                next.itemCount += 1
                next.mirrorState = .pendingMirror
            }
            return next
        }
        lastStatusMessage = "Marked HealthKit bridge summaries as pending mirror to the owner Pod."
    }

    private var healthKitStatusLabel: String {
        let healthKitItems = containers
            .filter { [.observation, .bloodPressure, .workout, .sleep].contains($0.resourceKind) }
            .map(\.itemCount)
            .reduce(0, +)
        return healthKitItems > 0 ? "\(healthKitItems) summaries queued" : "Ready"
    }

    private func itemCount(for apiName: String) -> Int {
        switch apiName {
        case "profiles":
            return session.authenticated ? 1 : 0
        case "conditions", "medications", "allergies", "immunizations", "providers", "lab-results", "insurance-policies", "documents", "workflow-tasks":
            return 0
        case "vital-signs":
            return containers
                .filter { [.observation, .bloodPressure].contains($0.resourceKind) }
                .map(\.itemCount)
                .reduce(0, +)
        default:
            return 0
        }
    }

    private func sourceLabel(for apiName: String) -> String {
        switch apiName {
        case "vital-signs":
            return "HealthKit + Epic"
        case "conditions", "medications", "allergies", "immunizations", "lab-results", "providers", "insurance-policies", "documents", "workflow-tasks":
            return "Epic FHIR"
        case "profiles":
            return "Solid owner"
        default:
            return "OpenCommons"
        }
    }

    private func attentionRequired(for apiName: String) -> Bool {
        let hasContainerConflict = containers.contains { $0.mirrorState == .conflict }
        return apiName == "vital-signs" && hasContainerConflict
    }
}
