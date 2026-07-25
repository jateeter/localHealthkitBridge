import Foundation
import SwiftUI
import MobileSolidCompatModel

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
}
