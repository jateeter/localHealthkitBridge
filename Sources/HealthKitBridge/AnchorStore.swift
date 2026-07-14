import Foundation

/// Persists opaque anchor blobs (archived HKQueryAnchor) per HK type so
/// anchored queries resume from the last-seen sample across launches.
/// Deliberately Data-based: testable without HealthKit.
public struct AnchorStore: Sendable {
    // UserDefaults is documented thread-safe but not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "healthkit-bridge.anchor.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func anchorData(for typeIdentifier: String) -> Data? {
        defaults.data(forKey: keyPrefix + typeIdentifier)
    }

    public func save(_ data: Data?, for typeIdentifier: String) {
        let key = keyPrefix + typeIdentifier
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func reset(typeIdentifiers: [String]) {
        for id in typeIdentifiers { save(nil, for: id) }
    }
}
