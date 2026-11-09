#if canImport(Security)
import XCTest
@testable import HealthKitBridge

/// PIM#86: the lane CA given to `PIMWireTests` as PEM becomes the anchors.
final class AnchoredTrustTests: XCTestCase {
    func testEveryCertificateInAPEMBundleIsReadInOrder() {
        let first = Data((0..<40).map { UInt8($0) })
        let second = Data((0..<90).map { UInt8(255 - $0) })
        func block(_ der: Data) -> String {
            let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
        }
        let pem = "subject=/CN=lane CA\n" + block(first) + "\n" + block(second)
        XCTAssertEqual(AnchoredTrustDelegate.derCertificates(fromPEM: pem), [first, second])
    }

    func testNoCertificateYieldsNoAnchors() {
        XCTAssertEqual(AnchoredTrustDelegate.derCertificates(fromPEM: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"), [])
    }
}
#endif
