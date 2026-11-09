#if canImport(Security)
import Foundation
import Security

/// Verifies a server against the given anchor certificates (DER) instead of the
/// OS trust store (PIM#86). The trust object URLSession hands over already
/// carries the SSL policy with the request's hostname, so the name check stays
/// on; only the anchors change, and a chain that does not reach them is refused.
/// Nothing here accepts an unverified server.
final class AnchoredTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let anchors: [SecCertificate]

    init(anchorsDER: [Data]) {
        self.anchors = anchorsDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard !anchors.isEmpty,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// The DER certificates in a PEM bundle, in order.
    static func derCertificates(fromPEM pem: String) -> [Data] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var result: [Data] = []
        var rest = Substring(pem)
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)) { result.append(der) }
            rest = rest[stop.upperBound...]
        }
        return result
    }
}
#endif
