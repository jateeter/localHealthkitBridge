import XCTest
@testable import MobileSolidCompatModel

final class MobileSolidCompatModelTests: XCTestCase {
    func testContainerPathsAreStableAndRelative() {
        XCTAssertEqual(MobileSolidPath.cleanContainerPath("/health-pim"), "health-pim/")
        XCTAssertEqual(MobileSolidPath.cleanContainerPath(" health-pim/mobile "), "health-pim/mobile/")
        XCTAssertEqual(MobileSolidPath.healthKitContainer(for: .bloodPressure), "healthkit/blood-pressure/")
    }

    func testResourcePathAvoidsAbsoluteURLsAndSlashesInStableID() {
        XCTAssertEqual(
            MobileSolidPath.resourcePath(kind: .observation, stableID: "hk/sample/123"),
            "healthkit/observations/hk-sample-123.ttl"
        )
    }

    func testObservableSessionSnapshotDoesNotRequireSecrets() throws {
        let snapshot = MobileSolidSessionSnapshot(
            authenticated: true,
            webID: "http://localhost:13000/alice/profile/card#me",
            storageIRI: "http://localhost:13000/alice/",
            dpopEnabled: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("refresh"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("access_token"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("private"))
    }

    func testConfigurationKeepsLocalHTTPExplicit() {
        let config = MobileSolidConfiguration(
            issuerURL: "http://localhost:13000/",
            redirectURI: "opencommons-health:/solid/callback",
            preferredStorageIRI: "http://localhost:13000/alice/",
            allowInsecureLocalHTTP: true
        )
        XCTAssertEqual(config.pimRootPath, "health-pim/")
        XCTAssertTrue(config.allowInsecureLocalHTTP)
    }

    func testOpenCommonsPodProfileExposesElevenOwnerDomains() {
        let domains = OpenCommonsHealthPodProfile.managedDomains
        XCTAssertEqual(domains.count, 11)
        XCTAssertEqual(domains.map(\.apiName), [
            "profiles",
            "conditions",
            "medications",
            "allergies",
            "immunizations",
            "vital-signs",
            "providers",
            "lab-results",
            "insurance-policies",
            "documents",
            "workflow-tasks",
        ])
        XCTAssertTrue(domains.contains { $0.fhirResourceType == "DocumentReference" })
        XCTAssertTrue(domains.contains { $0.fhirResourceType == "Task" })
    }

    func testHealthKitContainersCoverMirrorAndAuditUX() {
        let containers = OpenCommonsHealthPodProfile.healthKitContainers
        XCTAssertTrue(containers.contains { $0.relativePath == "healthkit/observations/" })
        XCTAssertTrue(containers.contains { $0.relativePath == "sync/conflicts/" && $0.mirrorState == .conflict })
        XCTAssertTrue(containers.contains { $0.relativePath == "audit/" })
        XCTAssertTrue(containers.allSatisfy { !$0.purpose.localizedCaseInsensitiveContains("token") })
    }
}
