import Foundation

/// Per-sample mirror state (MIRROR_CONTRACT §3, §6), keyed by `HKSample.uuid`.
///
/// Holds identity and outcome only, never measurements. A sample is
/// `pendingMirror` from the moment it is staged until PIM answers for it, so a
/// network or auth failure can never be mistaken for a mirrored reading.
public struct MirrorLedger: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var metric: String
        public var state: MirrorState
        public var reason: String?
    }

    // UserDefaults is documented thread-safe but not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "healthkit-bridge.mirror-ledger") {
        self.defaults = defaults
        self.key = key
    }

    public func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }

    public func state(of uuid: String) -> MirrorState? {
        entries()[uuid]?.state
    }

    /// Records states for many samples in one write.
    public func record(_ updates: [String: Entry]) {
        guard !updates.isEmpty else { return }
        var all = entries()
        all.merge(updates) { _, new in new }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    /// Counts by state, for the owner-visible status.
    public func counts() -> [MirrorState: Int] {
        entries().values.reduce(into: [:]) { $0[$1.state, default: 0] += 1 }
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }
}
