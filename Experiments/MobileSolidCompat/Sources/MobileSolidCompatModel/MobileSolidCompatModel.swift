import Foundation

/// Phase-0 inventory for the Swift Solid packages this experiment is intended
/// to validate. The production HealthKitBridge package deliberately does not
/// depend on these packages yet.
public enum SolidSwiftPackageInventory: Sendable {
    public static let solidAuthSwiftURL = "https://github.com/crspybits/SolidAuthSwift.git"
    public static let solidResourcesSwiftURL = "https://github.com/crspybits/SolidResourcesSwift.git"

    public static let requiredProducts = [
        "SolidAuthSwiftUI",
        "SolidAuthSwiftTools",
        "SolidResourcesSwift",
    ]
}

/// Local/docker CSS connection settings used by the mobile Solid compatibility
/// spike. Values are intentionally plain strings so the model can be serialized
/// in tests and exchanged with the browser UI later.
public struct MobileSolidConfiguration: Codable, Equatable, Sendable {
    public var issuerURL: String
    public var redirectURI: String
    public var clientName: String
    public var preferredStorageIRI: String?
    public var pimRootPath: String
    public var allowInsecureLocalHTTP: Bool

    public init(
        issuerURL: String,
        redirectURI: String,
        clientName: String = "OpenCommons Health Mobile Solid",
        preferredStorageIRI: String? = nil,
        pimRootPath: String = "health-pim/",
        allowInsecureLocalHTTP: Bool = false
    ) {
        self.issuerURL = issuerURL
        self.redirectURI = redirectURI
        self.clientName = clientName
        self.preferredStorageIRI = preferredStorageIRI
        self.pimRootPath = MobileSolidPath.cleanContainerPath(pimRootPath)
        self.allowInsecureLocalHTTP = allowInsecureLocalHTTP
    }
}

/// Sanitized session state that can be shown in mobile/web observability views
/// without exposing refresh tokens, access tokens, DPoP private keys, or PHI.
public struct MobileSolidSessionSnapshot: Codable, Equatable, Sendable {
    public var authenticated: Bool
    public var webID: String?
    public var storageIRI: String?
    public var tokenExpiresAt: Date?
    public var dpopEnabled: Bool
    public var lastError: String?

    public init(
        authenticated: Bool,
        webID: String? = nil,
        storageIRI: String? = nil,
        tokenExpiresAt: Date? = nil,
        dpopEnabled: Bool = true,
        lastError: String? = nil
    ) {
        self.authenticated = authenticated
        self.webID = webID
        self.storageIRI = storageIRI
        self.tokenExpiresAt = tokenExpiresAt
        self.dpopEnabled = dpopEnabled
        self.lastError = lastError
    }
}

public enum MobileSolidResourceKind: String, Codable, CaseIterable, Sendable {
    case observation
    case bloodPressure
    case workout
    case sleep
    case provenance
    case consent
    case audit
    case syncManifest
    case conflict
}

public enum MobileSolidMirrorState: String, Codable, Sendable {
    case localOnly
    case pendingMirror
    case mirrored
    case failed
    case conflict
    case revoked
}

/// Metadata envelope for a Solid resource managed from the iPhone side. This
/// is not the RDF payload itself; it is the observable/indexable state needed
/// for queueing, mirroring, and conflict UX.
public struct MobileSolidResourceDescriptor: Codable, Equatable, Sendable {
    public var kind: MobileSolidResourceKind
    public var relativePath: String
    public var mimeType: String
    public var sha256: String?
    public var updatedAt: Date?
    public var mirrorState: MobileSolidMirrorState
    public var validationShape: String?

    public init(
        kind: MobileSolidResourceKind,
        relativePath: String,
        mimeType: String,
        sha256: String? = nil,
        updatedAt: Date? = nil,
        mirrorState: MobileSolidMirrorState = .localOnly,
        validationShape: String? = nil
    ) {
        self.kind = kind
        self.relativePath = MobileSolidPath.cleanResourcePath(relativePath)
        self.mimeType = mimeType
        self.sha256 = sha256
        self.updatedAt = updatedAt
        self.mirrorState = mirrorState
        self.validationShape = validationShape
    }
}

/// One OpenCommons Health PIM domain visible to the iPhone owner. These mirror
/// the localhost/browser PIM domains so mobile Pod observability and desktop
/// Pod management use the same owner vocabulary.
public struct MobileSolidManagedDomain: Codable, Equatable, Identifiable, Sendable {
    public var id: String { apiName }
    public var apiName: String
    public var displayName: String
    public var fhirResourceType: String

    public init(apiName: String, displayName: String, fhirResourceType: String) {
        self.apiName = apiName
        self.displayName = displayName
        self.fhirResourceType = fhirResourceType
    }
}

/// Owner-visible Solid container row for mobile Pod management. This is
/// intentionally metadata-only; it can be shown without exposing PHI, tokens,
/// DPoP keys, or raw resource bodies.
public struct MobileSolidManagedContainer: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var title: String
    public var relativePath: String
    public var purpose: String
    public var resourceKind: MobileSolidResourceKind
    public var mirrorState: MobileSolidMirrorState
    public var itemCount: Int

    public init(
        title: String,
        relativePath: String,
        purpose: String,
        resourceKind: MobileSolidResourceKind,
        mirrorState: MobileSolidMirrorState = .localOnly,
        itemCount: Int = 0
    ) {
        self.title = title
        self.relativePath = MobileSolidPath.cleanContainerPath(relativePath)
        self.purpose = purpose
        self.resourceKind = resourceKind
        self.mirrorState = mirrorState
        self.itemCount = itemCount
    }
}

public enum OpenCommonsHealthPodProfile {
    public static let managedDomains: [MobileSolidManagedDomain] = [
        .init(apiName: "profiles", displayName: "Profiles", fhirResourceType: "Patient"),
        .init(apiName: "conditions", displayName: "Conditions", fhirResourceType: "Condition"),
        .init(apiName: "medications", displayName: "Medications", fhirResourceType: "MedicationStatement"),
        .init(apiName: "allergies", displayName: "Allergies", fhirResourceType: "AllergyIntolerance"),
        .init(apiName: "immunizations", displayName: "Immunizations", fhirResourceType: "Immunization"),
        .init(apiName: "vital-signs", displayName: "Vital signs", fhirResourceType: "Observation"),
        .init(apiName: "providers", displayName: "Providers", fhirResourceType: "PractitionerRole"),
        .init(apiName: "lab-results", displayName: "Lab results", fhirResourceType: "Observation"),
        .init(apiName: "insurance-policies", displayName: "Insurance policies", fhirResourceType: "Coverage"),
        .init(apiName: "documents", displayName: "Documents", fhirResourceType: "DocumentReference"),
        .init(apiName: "workflow-tasks", displayName: "Workflow tasks", fhirResourceType: "Task"),
    ]

    public static let healthKitContainers: [MobileSolidManagedContainer] = [
        .init(
            title: "HealthKit observations",
            relativePath: MobileSolidPath.healthKitContainer(for: .observation),
            purpose: "FHIR-aligned HealthKit Observation resources prepared on iPhone.",
            resourceKind: .observation
        ),
        .init(
            title: "Blood pressure",
            relativePath: MobileSolidPath.healthKitContainer(for: .bloodPressure),
            purpose: "Owner-held blood pressure summaries and validation state.",
            resourceKind: .bloodPressure
        ),
        .init(
            title: "Workouts",
            relativePath: MobileSolidPath.healthKitContainer(for: .workout),
            purpose: "Activity and workout summaries queued for Pod mirroring.",
            resourceKind: .workout
        ),
        .init(
            title: "Sleep",
            relativePath: MobileSolidPath.healthKitContainer(for: .sleep),
            purpose: "Sleep summaries derived from authorized HealthKit samples.",
            resourceKind: .sleep
        ),
        .init(
            title: "Provenance",
            relativePath: MobileSolidPath.healthKitContainer(for: .provenance),
            purpose: "Source, bridge, and validation metadata without raw secrets.",
            resourceKind: .provenance
        ),
        .init(
            title: "Consents",
            relativePath: MobileSolidPath.healthKitContainer(for: .consent),
            purpose: "Owner approval records for mirroring and anonymized release.",
            resourceKind: .consent
        ),
        .init(
            title: "Sync manifests",
            relativePath: MobileSolidPath.healthKitContainer(for: .syncManifest),
            purpose: "Mirror checkpoints shared with localhost/docker CSS.",
            resourceKind: .syncManifest
        ),
        .init(
            title: "Conflicts",
            relativePath: MobileSolidPath.healthKitContainer(for: .conflict),
            purpose: "Records that need owner review before overwrite or merge.",
            resourceKind: .conflict,
            mirrorState: .conflict
        ),
        .init(
            title: "Audit",
            relativePath: MobileSolidPath.healthKitContainer(for: .audit),
            purpose: "Append-only owner-visible sync and release events.",
            resourceKind: .audit
        ),
    ]
}

/// Protocol boundary for the future SolidAuthSwift + SolidResourcesSwift
/// adapter. Keeping the boundary small lets the HealthKit Bridge remain
/// unchanged while Phase 0 proves auth/resource compatibility.
public protocol MobileSolidResourceAccessing: AnyObject {
    func sessionSnapshot() async -> MobileSolidSessionSnapshot
    func putResource(_ descriptor: MobileSolidResourceDescriptor, data: Data) async throws
    func getResource(relativePath: String) async throws -> Data
    func deleteResource(relativePath: String) async throws
    func listContainer(relativePath: String) async throws -> [MobileSolidResourceDescriptor]
}

public enum MobileSolidPath {
    public static func cleanContainerPath(_ path: String) -> String {
        let clean = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clean.isEmpty ? "" : "\(clean)/"
    }

    public static func cleanResourcePath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func healthKitContainer(for kind: MobileSolidResourceKind) -> String {
        switch kind {
        case .observation:
            return "healthkit/observations/"
        case .bloodPressure:
            return "healthkit/blood-pressure/"
        case .workout:
            return "healthkit/workouts/"
        case .sleep:
            return "healthkit/sleep/"
        case .provenance:
            return "provenance/"
        case .consent:
            return "consents/"
        case .audit:
            return "audit/"
        case .syncManifest:
            return "sync/manifests/"
        case .conflict:
            return "sync/conflicts/"
        }
    }

    public static func resourcePath(kind: MobileSolidResourceKind, stableID: String, extension ext: String = "ttl") -> String {
        let safeID = stableID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return "\(healthKitContainer(for: kind))\(safeID).\(ext)"
    }
}

public enum MobileSolidCompatibilityChecklist {
    public static let phase0Checks = [
        "Resolve SolidAuthSwift and SolidResourcesSwift with SwiftPM.",
        "Compile MobileSolidCompatCore without importing SolidAuthSwiftUI.",
        "Compile MobileSolidCompatUI for an iOS destination.",
        "Authenticate against local CSS using SolidAuthSwiftUI.",
        "Create, read, list, and delete a Turtle resource through SolidResourcesSwift.",
        "Verify the existing HealthKitBridge package still builds and tests unchanged.",
    ]
}
