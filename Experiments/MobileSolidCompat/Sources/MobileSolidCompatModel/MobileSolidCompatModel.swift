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
