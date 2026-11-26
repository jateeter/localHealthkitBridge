import Foundation
import HealthKitBridge

/// The phone's one clock participant (RealityEngine_CI#600,
/// localHealthkitBridge#49), shared by PE ingest and the PIM mirror: one UUID
/// and one Lamport counter, kept in the Keychain so a reinstall keeps them.
///
/// If the Keychain cannot hold the clock the bridge still delivers, unstamped,
/// as a legacy caller the PEs accept; it never stamps a tick it could not make
/// durable. The failure is reported once in the sync log.
enum BridgeClock {
    static let loaded: Result<ParticipantClock, Error> = Result { try ParticipantClock.device() }

    static var shared: ParticipantClock? { try? loaded.get() }

    /// The sync-log line describing the clock, PHI-free.
    static var summary: String {
        switch loaded {
        case .success(let clock):
            return "Clock participant \(clock.instance.uuidString.lowercased())"
        case .failure(let error):
            return "Clock unavailable, delivering unstamped: \(error)"
        }
    }
}
