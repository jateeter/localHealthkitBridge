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
    let semanticElements: [PatientSemanticElement]
}

struct PatientSemanticElement: Identifiable, Equatable {
    let id: String
    let title: String
    let fhirElement: String
    let sourceLabel: String
    let currentSummary: String
    let statusLabel: String
    let itemCount: Int
    let graphValue: Double
    let attentionRequired: Bool
    let systemImage: String
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
            let count = itemCount(for: domain.apiName)
            let source = sourceLabel(for: domain.apiName)
            let needsReview = attentionRequired(for: domain.apiName)
            return PatientMonitorDomain(
                id: domain.apiName,
                title: domain.displayName,
                fhirResourceType: domain.fhirResourceType,
                sourceLabel: source,
                itemCount: count,
                attentionRequired: needsReview,
                semanticElements: semanticElements(
                    for: domain.apiName,
                    domainItemCount: count,
                    sourceLabel: source,
                    attentionRequired: needsReview
                )
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

    private func semanticElements(
        for apiName: String,
        domainItemCount: Int,
        sourceLabel: String,
        attentionRequired: Bool
    ) -> [PatientSemanticElement] {
        if apiName == "vital-signs" {
            return vitalSignSemanticElements(sourceLabel: sourceLabel, attentionRequired: attentionRequired)
        }

        let definitions: [(String, String, String, String)] = {
            switch apiName {
            case "profiles":
                return [
                    ("identity", "Identity", "Patient.identifier", "person.crop.circle"),
                    ("contacts", "Contacts", "Patient.telecom", "phone"),
                    ("demographics", "Demographics", "Patient.extension", "person.text.rectangle"),
                    ("care-team", "Care team", "Patient.generalPractitioner", "person.2"),
                ]
            case "conditions":
                return [
                    ("active-conditions", "Active conditions", "Condition.clinicalStatus", "stethoscope"),
                    ("onset", "Onset", "Condition.onset", "calendar"),
                    ("severity", "Severity", "Condition.severity", "waveform.path.ecg"),
                    ("evidence", "Evidence", "Condition.evidence", "doc.text.magnifyingglass"),
                    ("abatement", "Resolution", "Condition.abatement", "checkmark.circle"),
                ]
            case "medications":
                return [
                    ("active-medications", "Active medications", "MedicationStatement.medication", "pills"),
                    ("dosage", "Dosage", "MedicationStatement.dosage", "slider.horizontal.3"),
                    ("schedule", "Schedule", "MedicationStatement.effective", "clock"),
                    ("adherence", "Adherence", "MedicationStatement.status", "checklist"),
                    ("refills", "Refills", "MedicationRequest.dispenseRequest", "arrow.triangle.2.circlepath"),
                ]
            case "allergies":
                return [
                    ("substances", "Substances", "AllergyIntolerance.code", "allergens"),
                    ("reactions", "Reactions", "AllergyIntolerance.reaction", "exclamationmark.triangle"),
                    ("criticality", "Criticality", "AllergyIntolerance.criticality", "gauge.medium"),
                    ("verification", "Verification", "AllergyIntolerance.verificationStatus", "checkmark.shield"),
                ]
            case "immunizations":
                return [
                    ("vaccines", "Vaccines", "Immunization.vaccineCode", "syringe"),
                    ("dates", "Dates", "Immunization.occurrence", "calendar.badge.checkmark"),
                    ("performer", "Performer", "Immunization.performer", "person.badge.shield.checkmark"),
                    ("series", "Series", "Immunization.protocolApplied", "list.number"),
                ]
            case "providers":
                return [
                    ("practitioners", "Practitioners", "PractitionerRole.practitioner", "person.crop.rectangle"),
                    ("organizations", "Organizations", "PractitionerRole.organization", "building.2"),
                    ("specialties", "Specialties", "PractitionerRole.specialty", "cross.case"),
                    ("contacts", "Contacts", "PractitionerRole.telecom", "phone.connection"),
                ]
            case "lab-results":
                return [
                    ("panels", "Panels", "Observation.code", "testtube.2"),
                    ("values", "Values", "Observation.value", "number"),
                    ("ranges", "Ranges", "Observation.referenceRange", "ruler"),
                    ("interpretation", "Interpretation", "Observation.interpretation", "exclamationmark.magnifyingglass"),
                    ("specimens", "Specimens", "Observation.specimen", "shippingbox"),
                ]
            case "insurance-policies":
                return [
                    ("coverage", "Coverage", "Coverage.status", "shield.lefthalf.filled"),
                    ("members", "Members", "Coverage.beneficiary", "person.2"),
                    ("payors", "Payors", "Coverage.payor", "building.columns"),
                    ("periods", "Periods", "Coverage.period", "calendar"),
                ]
            case "documents":
                return [
                    ("clinical-notes", "Clinical notes", "DocumentReference.category", "doc.text"),
                    ("attachments", "Attachments", "DocumentReference.content", "paperclip"),
                    ("authors", "Authors", "DocumentReference.author", "person.text.rectangle"),
                    ("dates", "Dates", "DocumentReference.date", "calendar"),
                ]
            case "workflow-tasks":
                return [
                    ("owner-actions", "Owner actions", "Task.intent", "checklist"),
                    ("due-dates", "Due dates", "Task.executionPeriod", "calendar.badge.clock"),
                    ("requesters", "Requesters", "Task.requester", "person.crop.circle.badge.questionmark"),
                    ("status", "Status", "Task.status", "gauge.medium"),
                ]
            default:
                return [
                    ("summary", "Summary", "Domain.summary", "circle.grid.cross"),
                    ("source", "Source", "Domain.source", "tray.and.arrow.down"),
                    ("status", "Status", "Domain.status", "gauge.medium"),
                    ("actions", "Actions", "Domain.actions", "plus.circle"),
                ]
            }
        }()

        return definitions.enumerated().map { index, definition in
            let elementCount = index == 0 ? domainItemCount : 0
            return PatientSemanticElement(
                id: definition.0,
                title: definition.1,
                fhirElement: definition.2,
                sourceLabel: sourceLabel,
                currentSummary: elementCount > 0 ? "\(elementCount) owner-visible summar\(elementCount == 1 ? "y" : "ies")" : "No current owner-visible entries",
                statusLabel: attentionRequired && index == 0 ? "Needs review" : (elementCount > 0 ? "Current" : "Ready to add"),
                itemCount: elementCount,
                graphValue: graphValue(for: elementCount, index: index, attentionRequired: attentionRequired),
                attentionRequired: attentionRequired && index == 0,
                systemImage: definition.3
            )
        }
    }

    private func vitalSignSemanticElements(
        sourceLabel: String,
        attentionRequired: Bool
    ) -> [PatientSemanticElement] {
        let bloodPressureCount = containers
            .filter { $0.resourceKind == .bloodPressure }
            .map(\.itemCount)
            .reduce(0, +)
        let activityCount = containers
            .filter { $0.resourceKind == .workout }
            .map(\.itemCount)
            .reduce(0, +)
        let sleepCount = containers
            .filter { $0.resourceKind == .sleep }
            .map(\.itemCount)
            .reduce(0, +)
        let observationCount = containers
            .filter { $0.resourceKind == .observation }
            .map(\.itemCount)
            .reduce(0, +)

        return [
            vitalSemanticElement(
                id: "blood-pressure",
                title: "Blood pressure",
                fhirElement: "Observation.component",
                sourceLabel: sourceLabel,
                count: bloodPressureCount,
                attentionRequired: attentionRequired,
                systemImage: "heart.text.square"
            ),
            vitalSemanticElement(
                id: "heart-rate",
                title: "Heart rate",
                fhirElement: "Observation.valueQuantity",
                sourceLabel: sourceLabel,
                count: observationCount,
                attentionRequired: false,
                systemImage: "heart.fill"
            ),
            vitalSemanticElement(
                id: "activity",
                title: "Activity",
                fhirElement: "Observation.category",
                sourceLabel: sourceLabel,
                count: activityCount,
                attentionRequired: false,
                systemImage: "figure.run"
            ),
            vitalSemanticElement(
                id: "sleep",
                title: "Sleep",
                fhirElement: "Observation.effective",
                sourceLabel: sourceLabel,
                count: sleepCount,
                attentionRequired: false,
                systemImage: "bed.double"
            ),
            vitalSemanticElement(
                id: "provenance",
                title: "Provenance",
                fhirElement: "Observation.meta.source",
                sourceLabel: sourceLabel,
                count: observationCount + bloodPressureCount + activityCount + sleepCount,
                attentionRequired: false,
                systemImage: "point.3.connected.trianglepath.dotted"
            ),
        ]
    }

    private func vitalSemanticElement(
        id: String,
        title: String,
        fhirElement: String,
        sourceLabel: String,
        count: Int,
        attentionRequired: Bool,
        systemImage: String
    ) -> PatientSemanticElement {
        PatientSemanticElement(
            id: id,
            title: title,
            fhirElement: fhirElement,
            sourceLabel: sourceLabel,
            currentSummary: count > 0 ? "\(count) HealthKit summar\(count == 1 ? "y" : "ies") queued" : "No current owner-visible entries",
            statusLabel: attentionRequired ? "Needs review" : (count > 0 ? "Current" : "Ready to add"),
            itemCount: count,
            graphValue: graphValue(for: count, index: 0, attentionRequired: attentionRequired),
            attentionRequired: attentionRequired,
            systemImage: systemImage
        )
    }

    private func graphValue(for count: Int, index: Int, attentionRequired: Bool) -> Double {
        if attentionRequired { return 0.95 }
        if count > 0 { return min(0.95, 0.45 + (Double(count) * 0.12)) }
        return [0.34, 0.42, 0.5, 0.58, 0.66][index % 5]
    }
}
