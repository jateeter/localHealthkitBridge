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
    let summary: String
    let codingSystemName: String?
    let codingSystemURL: String?
    let codingCode: String?
    let codingDisplay: String?
    let defaultUnit: String?
}

struct StagedPatientDatum: Identifiable, Codable, Equatable {
    let id: UUID
    let domainID: String
    let domainTitle: String
    let elementID: String
    let elementTitle: String
    let fhirElement: String
    let codingSystemName: String?
    let codingSystemURL: String?
    let codingCode: String?
    let codingDisplay: String?
    let value: String
    let note: String
    let stagedAt: Date
}

struct DailyPlannedActivity: Identifiable, Equatable {
    let id: String
    let title: String
    let hour: Int
    let minute: Int
    let systemImage: String
    let tint: Color

    var timeLabel: String {
        let suffix = hour >= 12 ? "PM" : "AM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(displayHour):\(String(format: "%02d", minute)) \(suffix)"
    }
}

@MainActor
final class MobilePodModel: ObservableObject {
    static let defaultLocalPIMBaseURL = "http://localhost:18080"
    static let defaultIssuerURL = "http://css.localhost:13000/"
    static let defaultOwnerStorageIRI = "http://css.localhost:13000/jateeter/"

    @Published var issuerURL: String
    @Published var storageIRI: String
    @Published var pimRootPath: String
    @Published var redirectURI: String
    @Published var localPIMBaseURL: String
    @Published var allowInsecureLocalHTTP: Bool
    @Published private(set) var session: MobileSolidSessionSnapshot
    @Published private(set) var containers: [MobileSolidManagedContainer]
    @Published private(set) var lastStatusMessage: String
    @Published private(set) var stagedData: [StagedPatientDatum]

    let managedDomains = OpenCommonsHealthPodProfile.managedDomains
    let wellnessAxisDomainIDs = ["vital-signs", "lab-results", "medications", "conditions", "allergies", "immunizations"]
    let wellnessBrowseDomainIDs = ["profiles", "providers", "insurance-policies", "documents", "workflow-tasks"]

    private let defaults = UserDefaults.standard

    init() {
        issuerURL = defaults.string(forKey: "mobileSolid.issuerURL") ?? Self.defaultIssuerURL
        storageIRI = defaults.string(forKey: "mobileSolid.storageIRI") ?? Self.defaultOwnerStorageIRI
        pimRootPath = defaults.string(forKey: "mobileSolid.pimRootPath") ?? "health-pim/"
        redirectURI = defaults.string(forKey: "mobileSolid.redirectURI") ?? "opencommons-health:/solid/callback"
        localPIMBaseURL = defaults.string(forKey: "mobileSolid.localPIMBaseURL") ?? Self.defaultLocalPIMBaseURL
        allowInsecureLocalHTTP = defaults.object(forKey: "mobileSolid.allowInsecureLocalHTTP") as? Bool ?? true
        session = MobileSolidSessionSnapshot(
            authenticated: false,
            webID: nil,
            storageIRI: defaults.string(forKey: "mobileSolid.storageIRI") ?? Self.defaultOwnerStorageIRI,
            dpopEnabled: true,
            lastError: "Local PIM/CSS status has not been refreshed yet."
        )
        containers = OpenCommonsHealthPodProfile.healthKitContainers
        lastStatusMessage = "Configured for the localhost OpenCommons PIM owner Pod."
        stagedData = Self.loadStagedData(from: defaults)
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
        session.authenticated ? "PIM Pod linked" : "Local preview"
    }

    var mirrorSummary: String {
        let pending = containers.filter { $0.mirrorState == .pendingMirror }.count
        let conflicts = containers.filter { $0.mirrorState == .conflict }.count
        if !stagedData.isEmpty {
            return "\(stagedData.count) staged · \(pending) pending · \(conflicts) conflict\(conflicts == 1 ? "" : "s")"
        }
        if pending == 0 && conflicts == 0 { return "No pending mirrors" }
        return "\(pending) pending · \(conflicts) conflict\(conflicts == 1 ? "" : "s")"
    }

    var termsURL: URL? {
        legalURL(path: "terms.html")
    }

    var dataDisclosureURL: URL? {
        legalURL(path: "data-disclosure.html")
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
                detail: "\(storageIRI) · \(mirrorSummary)",
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

    var wellnessAxisDomains: [PatientMonitorDomain] {
        domains(matching: wellnessAxisDomainIDs)
    }

    var wellnessBrowseDomains: [PatientMonitorDomain] {
        domains(matching: wellnessBrowseDomainIDs)
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
        if !stagedData.isEmpty {
            return "\(visibleDomains) domains visible · \(stagedData.count) owner-approved draft\(stagedData.count == 1 ? "" : "s") staged"
        }
        return "\(visibleDomains) domains visible · owner-controlled Pod monitor"
    }

    private func domains(matching ids: [String]) -> [PatientMonitorDomain] {
        let byID = Dictionary(uniqueKeysWithValues: patientMonitorDomains.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
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
        defaults.set(localPIMBaseURL, forKey: "mobileSolid.localPIMBaseURL")
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

    func refreshLocalPIMStatus() async {
        guard let baseURL = URL(string: localPIMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let healthURL = URL(string: "/healthz", relativeTo: baseURL)?.absoluteURL else {
            lastStatusMessage = "Local PIM URL is not valid."
            return
        }

        do {
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastStatusMessage = "Local PIM status is not reachable at \(healthURL.absoluteString)."
                return
            }
            let status = try JSONDecoder().decode(LocalPIMHealthStatus.self, from: data)
            if status.ok == true, status.podAccess == true {
                if let podServerURL = status.podServerUrl, !podServerURL.isEmpty {
                    issuerURL = podServerURL.hasSuffix("/") ? podServerURL : "\(podServerURL)/"
                }
                if let podBaseURL = status.podBaseUrl, !podBaseURL.isEmpty {
                    storageIRI = podBaseURL
                }
                session = MobileSolidSessionSnapshot(
                    authenticated: true,
                    webID: nil,
                    storageIRI: storageIRI,
                    dpopEnabled: true,
                    lastError: "PIM reports authenticated owner Pod access."
                )
                lastStatusMessage = "Local PIM/CSS owner Pod status loaded."
            } else {
                session = MobileSolidSessionSnapshot(
                    authenticated: false,
                    webID: nil,
                    storageIRI: storageIRI,
                    dpopEnabled: true,
                    lastError: "PIM is reachable but owner Pod access is not confirmed."
                )
                lastStatusMessage = "Local PIM status loaded without confirmed Pod access."
            }
        } catch {
            session = MobileSolidSessionSnapshot(
                authenticated: false,
                webID: nil,
                storageIRI: storageIRI,
                dpopEnabled: true,
                lastError: "Local preview: \(error.localizedDescription)"
            )
            lastStatusMessage = "Local PIM/CSS status refresh failed. Check the base URL for simulator, LAN, or device review."
        }
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

    func stageSemanticDatum(domain: PatientMonitorDomain, element: PatientSemanticElement, value: String, note: String) {
        let datum = StagedPatientDatum(
            id: UUID(),
            domainID: domain.id,
            domainTitle: domain.title,
            elementID: element.id,
            elementTitle: element.title,
            fhirElement: element.fhirElement,
            codingSystemName: element.codingSystemName,
            codingSystemURL: element.codingSystemURL,
            codingCode: element.codingCode,
            codingDisplay: element.codingDisplay,
            value: value.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            stagedAt: Date()
        )
        stagedData.insert(datum, at: 0)
        persistStagedData()
        containers = containers.map { container in
            var next = container
            if container.resourceKind == .syncManifest || container.resourceKind == .audit {
                next.itemCount += 1
                next.mirrorState = .pendingMirror
            }
            return next
        }
        lastStatusMessage = "Staged \(element.title) for owner review before Pod mirroring."
    }

    func plannedActivities(for weekday: Int) -> [DailyPlannedActivity] {
        let normalizedWeekday = max(1, min(7, weekday))
        var activities: [DailyPlannedActivity] = [
            .init(id: "morning-medications", title: "Morning medication regimen", hour: 8, minute: 0, systemImage: "pills.fill", tint: .blue),
            .init(id: "vitals-check", title: "Vital signs check", hour: 9, minute: 0, systemImage: "heart.text.square.fill", tint: .pink),
            .init(id: "movement", title: "Movement / activity window", hour: 12, minute: 30, systemImage: "figure.walk", tint: .green),
            .init(id: "pod-review", title: "Review Pod mirror queue", hour: 18, minute: 0, systemImage: "lock.shield.fill", tint: .teal),
        ]

        if normalizedWeekday == 2 {
            activities.append(.init(id: "weekly-planning", title: "Weekly care plan review", hour: 16, minute: 0, systemImage: "calendar.badge.clock", tint: .purple))
        }
        if normalizedWeekday == 6 {
            activities.append(.init(id: "medication-refill", title: "Medication refill check", hour: 15, minute: 0, systemImage: "arrow.triangle.2.circlepath", tint: .orange))
        }
        return activities.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    private var healthKitStatusLabel: String {
        let healthKitItems = containers
            .filter { [.observation, .bloodPressure, .workout, .sleep].contains($0.resourceKind) }
            .map(\.itemCount)
            .reduce(0, +)
        return healthKitItems > 0 ? "\(healthKitItems) summaries queued" : "Ready"
    }

    private func itemCount(for apiName: String) -> Int {
        let stagedCount = stagedData.filter { $0.domainID == apiName }.count
        switch apiName {
        case "profiles":
            return (session.authenticated ? 1 : 0) + stagedCount
        case "vital-signs":
            return containers
                .filter { [.observation, .bloodPressure].contains($0.resourceKind) }
                .map(\.itemCount)
                .reduce(0, +) + stagedCount
        default:
            return stagedCount
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
        let definitions = semanticDefinitions(for: apiName)
        return definitions.enumerated().map { index, definition in
            let elementCount = count(for: definition.id, in: apiName, fallbackDomainCount: index == 0 ? domainItemCount : 0)
            return PatientSemanticElement(
                id: definition.id,
                title: definition.title,
                fhirElement: definition.fhirElement,
                sourceLabel: sourceLabel,
                currentSummary: elementCount > 0 ? "\(elementCount) owner-visible summar\(elementCount == 1 ? "y" : "ies")" : "No current owner-visible entries",
                statusLabel: attentionRequired && index == 0 ? "Needs review" : (elementCount > 0 ? "Current" : "Ready to add"),
                itemCount: elementCount,
                graphValue: graphValue(for: elementCount, index: index, attentionRequired: attentionRequired),
                attentionRequired: attentionRequired && index == 0,
                systemImage: definition.systemImage,
                summary: definition.summary,
                codingSystemName: definition.codingSystemName,
                codingSystemURL: definition.codingSystemURL,
                codingCode: definition.codingCode,
                codingDisplay: definition.codingDisplay,
                defaultUnit: definition.defaultUnit
            )
        }
    }

    private func count(for elementID: String, in apiName: String, fallbackDomainCount: Int) -> Int {
        let stagedCount = stagedData.filter { $0.domainID == apiName && $0.elementID == elementID }.count
        if apiName == "vital-signs" {
            switch elementID {
            case "blood-pressure":
                return containers.filter { $0.resourceKind == .bloodPressure }.map(\.itemCount).reduce(0, +) + stagedCount
            case "heart-rate", "body-temperature", "oxygen-saturation", "body-weight", "bmi":
                return containers.filter { $0.resourceKind == .observation }.map(\.itemCount).reduce(0, +) + stagedCount
            default:
                return stagedCount
            }
        }
        return fallbackDomainCount + stagedCount
    }

    private func graphValue(for count: Int, index: Int, attentionRequired: Bool) -> Double {
        if attentionRequired { return 0.95 }
        if count > 0 { return min(0.95, 0.45 + (Double(count) * 0.12)) }
        return [0.34, 0.42, 0.5, 0.58, 0.66][index % 5]
    }

    private func semanticDefinitions(for apiName: String) -> [SemanticElementDefinition] {
        switch apiName {
        case "profiles":
            return [
                .init("identity", "Identity", "Patient.identifier", "Owner name and demographic basics.", "person.crop.circle"),
                .init("birth-date", "Birth date", "Patient.birthDate", "Date of birth used for owner-held health context.", "calendar"),
                .init("biological-sex", "Biological sex", "Patient.gender", "Administrative clinical sex value.", "person.text.rectangle"),
                .init("photo", "Photo", "Patient.photo", "Optional owner-selected profile image URL.", "photo"),
            ]
        case "conditions":
            return [
                .init("active-condition", "Active condition", "Condition.code", "SNOMED CT-coded active diagnosis or concern.", "stethoscope", .snomedCT, "38341003", "Hypertensive disorder"),
                .init("severity", "Severity", "Condition.severity", "Mild, moderate, or severe clinical impact.", "gauge.medium", .snomedCT, "386661006", "Fever"),
                .init("onset", "Onset", "Condition.onset", "When a condition began or was recognized.", "calendar", .snomedCT, "73211009", "Diabetes mellitus"),
                .init("resolved", "Resolved", "Condition.abatement", "Conditions that are inactive, resolved, or in remission.", "checkmark.circle", .snomedCT, "195967001", "Asthma"),
            ]
        case "medications":
            return [
                .init("active-medication", "Active medication", "MedicationStatement.medication", "RxNorm-coded medicine currently taken.", "pills", .rxNorm, "860975", "Metformin 500 MG Oral Tablet"),
                .init("dosage", "Dosage", "MedicationStatement.dosage", "Dose, route, and timing instructions.", "slider.horizontal.3", .rxNorm, "617314", "Atorvastatin 20 MG Oral Tablet"),
                .init("prescriber", "Prescriber", "MedicationRequest.requester", "Clinician or source associated with the medication.", "person.crop.circle.badge.checkmark", .rxNorm, "197361", "Lisinopril 10 MG Oral Tablet"),
                .init("history", "Medication history", "MedicationStatement.status", "Stopped, completed, or historical medications.", "clock.arrow.circlepath", .rxNorm, "198440", "Acetaminophen 325 MG Oral Tablet"),
            ]
        case "allergies":
            return [
                .init("substance", "Substance", "AllergyIntolerance.code", "SNOMED CT-coded allergen or intolerance.", "allergens", .snomedCT, "91936005", "Allergy to penicillin"),
                .init("food", "Food", "AllergyIntolerance.category", "Food allergy or intolerance.", "fork.knife", .snomedCT, "91935009", "Allergy to peanuts"),
                .init("medication", "Medication", "AllergyIntolerance.category", "Medication allergy or adverse sensitivity.", "pills", .snomedCT, "294954006", "Aspirin allergy"),
                .init("environment", "Environment", "AllergyIntolerance.category", "Environmental allergy or sensitivity.", "leaf", .snomedCT, "300916003", "Latex allergy"),
            ]
        case "immunizations":
            return [
                .init("vaccine", "Vaccine", "Immunization.vaccineCode", "CVX-coded vaccine record.", "syringe", .cvx, "141", "Influenza, seasonal, injectable"),
                .init("date", "Administration date", "Immunization.occurrence", "When the vaccine was given.", "calendar.badge.checkmark", .cvx, "207", "COVID-19, mRNA, LNP-S, PF, 100 mcg/0.5 mL dose"),
                .init("dose", "Dose series", "Immunization.protocolApplied", "Dose number within a vaccine series.", "list.number", .cvx, "208", "COVID-19, mRNA, LNP-S, PF, 30 mcg/0.3 mL dose"),
                .init("performer", "Performer", "Immunization.performer", "Clinic, pharmacy, or clinician administering the vaccine.", "person.badge.shield.checkmark", .cvx, "140", "Influenza, seasonal, injectable, preservative free"),
            ]
        case "vital-signs":
            return [
                .init("blood-pressure", "Blood pressure", "Observation.code", "LOINC blood pressure panel.", "heart.text.square", .loinc, "85354-9", "Blood pressure panel with all children optional", "mmHg"),
                .init("heart-rate", "Heart rate", "Observation.valueQuantity", "LOINC heart rate observation.", "heart.fill", .loinc, "8867-4", "Heart rate", "beats/min"),
                .init("body-temperature", "Temperature", "Observation.valueQuantity", "LOINC body temperature observation.", "thermometer.medium", .loinc, "8310-5", "Body temperature", "Cel"),
                .init("oxygen-saturation", "Oxygen saturation", "Observation.valueQuantity", "LOINC pulse oximetry oxygen saturation.", "lungs.fill", .loinc, "59408-5", "Oxygen saturation in arterial blood by pulse oximetry", "%"),
                .init("body-weight", "Body weight", "Observation.valueQuantity", "LOINC body weight measurement.", "scalemass", .loinc, "29463-7", "Body weight", "kg"),
                .init("bmi", "BMI", "Observation.valueQuantity", "LOINC body mass index measurement.", "figure.stand", .loinc, "39156-5", "Body mass index (BMI)", "kg/m2"),
            ]
        case "providers":
            return [
                .init("primary-care", "Primary care", "PractitionerRole.code", "Primary care clinician or practice.", "cross.case"),
                .init("specialist", "Specialist", "PractitionerRole.specialty", "Specialty care clinician.", "stethoscope"),
                .init("pharmacy", "Pharmacy", "Organization.type", "Preferred or historical pharmacy.", "pills"),
                .init("lab", "Laboratory", "Organization.type", "Laboratory or diagnostic service provider.", "testtube.2"),
            ]
        case "lab-results":
            return [
                .init("glucose", "Glucose", "Observation.code", "LOINC-coded glucose laboratory result.", "drop", .loinc, "2339-0", "Glucose mass/volume in blood", "mg/dL"),
                .init("hemoglobin-a1c", "Hemoglobin A1c", "Observation.code", "LOINC-coded A1c result.", "chart.xyaxis.line", .loinc, "4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood", "%"),
                .init("lipids", "Lipids", "Observation.code", "Cholesterol and lipid panel observations.", "waveform.path.ecg.rectangle", .loinc, "24331-1", "Lipid panel", "mg/dL"),
                .init("interpretation", "Interpretation", "Observation.interpretation", "Normal, abnormal, high, low, or critical result interpretation.", "exclamationmark.magnifyingglass", .loinc, "718-7", "Hemoglobin [Mass/volume] in Blood"),
            ]
        case "insurance-policies":
            return [
                .init("medical", "Medical", "Coverage.type", "Medical coverage policy.", "shield.lefthalf.filled"),
                .init("pharmacy", "Pharmacy", "Coverage.class", "Prescription benefit coverage.", "pills"),
                .init("member-id", "Member ID", "Coverage.identifier", "Owner-held member identifier for the plan.", "person.text.rectangle"),
                .init("effective-dates", "Effective dates", "Coverage.period", "Coverage start and expiration dates.", "calendar"),
            ]
        case "documents":
            return [
                .init("summary", "Visit summary", "DocumentReference.type", "LOINC-coded clinical or visit summary metadata.", "doc.text", .loinc, "34133-9", "Summary of episode note"),
                .init("lab-report", "Lab report", "DocumentReference.type", "Laboratory report document metadata.", "testtube.2", .loinc, "11502-2", "Laboratory report"),
                .init("care-plan", "Care plan", "DocumentReference.category", "Plan of care or care coordination document.", "list.bullet.clipboard", .loinc, "18776-5", "Plan of care note"),
                .init("source", "Source", "DocumentReference.content", "Source system, custodian, or pod binary link.", "tray.and.arrow.down"),
            ]
        case "workflow-tasks":
            return [
                .init("review", "Review", "Task.intent", "Owner-tracked review task.", "checklist", .snomedCT, "183452005", "Review of medication"),
                .init("follow-up", "Follow-up", "Task.executionPeriod", "Care follow-up or next-step task.", "calendar.badge.clock", .snomedCT, "185389009", "Follow-up visit"),
                .init("due-date", "Due date", "Task.executionPeriod", "Task with a planned due date.", "calendar", .snomedCT, "225358003", "Wound care"),
                .init("completed", "Completed", "Task.status", "Finished owner-held workflow task.", "checkmark.circle", .snomedCT, "308335008", "Patient encounter procedure"),
            ]
        default:
            return [
                .init("summary", "Summary", "Domain.summary", "Domain summary.", "circle.grid.cross"),
                .init("source", "Source", "Domain.source", "Source summary.", "tray.and.arrow.down"),
                .init("status", "Status", "Domain.status", "Status summary.", "gauge.medium"),
                .init("actions", "Actions", "Domain.actions", "Available actions.", "plus.circle"),
            ]
        }
    }

    private func legalURL(path: String) -> URL? {
        guard var components = URLComponents(string: localPIMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.path = "/\(path)"
        return components.url
    }

    private func persistStagedData() {
        if let data = try? JSONEncoder().encode(stagedData) {
            defaults.set(data, forKey: "mobileSolid.stagedData")
        }
    }

    private static func loadStagedData(from defaults: UserDefaults) -> [StagedPatientDatum] {
        guard let data = defaults.data(forKey: "mobileSolid.stagedData"),
              let decoded = try? JSONDecoder().decode([StagedPatientDatum].self, from: data) else {
            return []
        }
        return decoded
    }
}

private struct LocalPIMHealthStatus: Decodable {
    let ok: Bool?
    let podAccess: Bool?
    let podServerUrl: String?
    let podBaseUrl: String?
}

private struct CodingSystemDefinition {
    let name: String
    let url: String

    static let loinc = CodingSystemDefinition(name: "LOINC", url: "http://loinc.org")
    static let rxNorm = CodingSystemDefinition(name: "RxNorm", url: "http://www.nlm.nih.gov/research/umls/rxnorm")
    static let snomedCT = CodingSystemDefinition(name: "SNOMED CT", url: "http://snomed.info/sct")
    static let cvx = CodingSystemDefinition(name: "CVX", url: "http://hl7.org/fhir/sid/cvx")
}

private struct SemanticElementDefinition {
    let id: String
    let title: String
    let fhirElement: String
    let summary: String
    let systemImage: String
    let codingSystemName: String?
    let codingSystemURL: String?
    let codingCode: String?
    let codingDisplay: String?
    let defaultUnit: String?

    init(
        _ id: String,
        _ title: String,
        _ fhirElement: String,
        _ summary: String,
        _ systemImage: String,
        _ codingSystem: CodingSystemDefinition? = nil,
        _ codingCode: String? = nil,
        _ codingDisplay: String? = nil,
        _ defaultUnit: String? = nil
    ) {
        self.id = id
        self.title = title
        self.fhirElement = fhirElement
        self.summary = summary
        self.systemImage = systemImage
        self.codingSystemName = codingSystem?.name
        self.codingSystemURL = codingSystem?.url
        self.codingCode = codingCode
        self.codingDisplay = codingDisplay
        self.defaultUnit = defaultUnit
    }
}
