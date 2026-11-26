import Foundation
#if canImport(Security)
import Security
#endif

/// The bridge as a Lamport clock participant (RealityEngine_CI#600,
/// localHealthkitBridge#49; docs/INGEST_CONTRACT.md, "Clock").
///
/// The bridge keeps one UUID and one Lamport counter for the life of the
/// install, and they survive a reinstall: the device store is the Keychain, not
/// app storage, so only the user's own reset (the store's `reset()`) starts
/// a new participant.
///
/// - Every request the bridge makes is a **send**: it ticks, then stamps
///   `RE-Clock: instance=<uuid>; lamport=<n>` (`stampSend()`).
/// - Every response is a **receive**: `lamport = max(local, received) + 1`, or
///   `local + 1` when the responder sent no header (`receive(header:)`).
/// - Every batch is **stored** at creation, which is an event of its own: the
///   batch's body `clock` is that tick (`stampStore()`), so a batch delivered
///   late keeps the order it was created in while each attempt to send it is
///   stamped afresh.
///
/// **No tick is handed out twice.** The store holds a high-water mark reserved
/// `reservation` ticks ahead, as the engines' clock directories do: a boot
/// resumes from the mark and reserves the next block before issuing a tick, a
/// tick past the mark is preceded by the write of the next block, and a receive
/// that jumps past it writes `received + 1 + reservation` before the value is
/// used.
public actor ParticipantClock {
    public static let reservation: UInt64 = 1024
    /// The largest value the header may carry: `2^53 - 1`.
    public static let maxLamport: UInt64 = (1 << 53) - 1

    public nonisolated let instance: UUID
    private let store: ClockStore
    public private(set) var lamport: UInt64
    private var mark: UInt64

    /// Resumes the participant the store holds, or begins one. Throws when the
    /// store cannot be read or written: either way a tick could be issued twice.
    public init(store: ClockStore) throws {
        self.store = store
        let state = try store.load() ?? ClockState(instance: UUID(), mark: 0)
        self.instance = state.instance
        self.lamport = state.mark
        let reserved = state.mark + Self.reservation
        try store.save(ClockState(instance: state.instance, mark: reserved))
        self.mark = reserved
    }

    /// The device's participant, in the Keychain.
    #if canImport(Security)
    public static func device() throws -> ParticipantClock {
        try ParticipantClock(store: KeychainClockStore())
    }
    #endif

    /// The participant's clock now, without ticking.
    public var current: ClockStamp { ClockStamp(instance: instance, lamport: lamport) }

    /// A send: tick, and return the header value to stamp on the request.
    public func stampSend() throws -> String {
        try advance(to: lamport + 1)
        return Self.header(current)
    }

    /// A stored message (a batch at creation): tick, and return its body `clock`.
    public func stampStore() throws -> ClockStamp {
        try advance(to: lamport + 1)
        return current
    }

    /// A receive of a response's `RE-Clock` (nil when it carried none). A
    /// malformed header counts as none: the bridge cannot refuse a response.
    public func receive(header: String?) throws {
        let received = header.flatMap(Self.parse)?.lamport ?? 0
        try advance(to: max(lamport, received) + 1)
    }

    private func advance(to next: UInt64) throws {
        guard next <= Self.maxLamport else { throw ClockError.exhausted }
        if next > mark {
            let reserved = min(next + Self.reservation, Self.maxLamport)
            try store.save(ClockState(instance: instance, mark: reserved))
            mark = reserved
        }
        lamport = next
    }

    // MARK: - The header

    public static let headerName = "RE-Clock"

    public static func header(_ stamp: ClockStamp) -> String {
        "instance=\(stamp.instance.uuidString.lowercased()); lamport=\(stamp.lamport)"
    }

    /// Parses `instance=<uuid>; lamport=<n>` exactly as the contract defines it:
    /// both parameters once, in that order, `;` with optional spaces, a
    /// canonical lower-case UUID, a decimal in `[0, 2^53 - 1]` with no sign and
    /// no leading zeros. Anything else is nil.
    public static func parse(_ value: String) -> ClockStamp? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              parts[0].hasPrefix("instance="), parts[1].hasPrefix("lamport=") else { return nil }
        let id = String(parts[0].dropFirst("instance=".count))
        let n = String(parts[1].dropFirst("lamport=".count))
        guard id.count == 36, id == id.lowercased(), let uuid = UUID(uuidString: id),
              uuid.uuidString.lowercased() == id else { return nil }
        guard !n.isEmpty, n.allSatisfy({ $0.isASCII && $0.isNumber }),
              n == "0" || !n.hasPrefix("0"),
              let lamport = UInt64(n), lamport <= maxLamport else { return nil }
        return ClockStamp(instance: uuid, lamport: lamport)
    }
}

/// `{instance, lamport}`: a body `clock` or a parsed `RE-Clock`.
public struct ClockStamp: Codable, Equatable, Sendable {
    public var instance: UUID
    public var lamport: UInt64

    public init(instance: UUID, lamport: UInt64) {
        self.instance = instance
        self.lamport = lamport
    }

    private enum CodingKeys: String, CodingKey { case instance, lamport }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .instance)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .instance, in: c, debugDescription: "not a UUID")
        }
        instance = uuid
        lamport = try c.decode(UInt64.self, forKey: .lamport)
    }

    /// The instance in canonical lower-case hex, as every participant writes it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instance.uuidString.lowercased(), forKey: .instance)
        try c.encode(lamport, forKey: .lamport)
    }
}

public enum ClockError: Error, Equatable, Sendable {
    case exhausted
    case store(String)
}

/// What the store keeps: the participant's UUID and its high-water mark.
public struct ClockState: Codable, Equatable, Sendable {
    public var instance: UUID
    public var mark: UInt64

    public init(instance: UUID, mark: UInt64) {
        self.instance = instance
        self.mark = mark
    }
}

public protocol ClockStore: Sendable {
    func load() throws -> ClockState?
    /// Durable when it returns: a tick up to `mark` may be issued next.
    func save(_ state: ClockState) throws
    /// The user's reset: the next clock is a new participant.
    func reset() throws
}

/// For tests and the simulator: a store that lives as long as the object.
public final class MemoryClockStore: ClockStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ClockState?

    public init(_ state: ClockState? = nil) { self.state = state }

    public func load() throws -> ClockState? {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func save(_ state: ClockState) throws {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        state = nil
    }
}

#if canImport(Security)
/// The device store: one generic-password Keychain item, readable after the
/// first unlock so background delivery can tick while the phone is locked.
/// Keychain items outlive the app, so a reinstall keeps the participant.
public struct KeychainClockStore: ClockStore {
    public let service: String
    public let account: String

    public init(service: String = "org.realityengine.healthkit-bridge.clock", account: String = "participant") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> ClockState? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw ClockError.store("Keychain read failed (\(status))")
        }
        do {
            return try JSONDecoder().decode(ClockState.self, from: data)
        } catch {
            throw ClockError.store("Keychain clock is unreadable")
        }
    }

    public func save(_ state: ClockState) throws {
        let data = try JSONEncoder().encode(state)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClockError.store("Keychain write failed (\(status))") }
    }

    public func reset() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClockError.store("Keychain delete failed (\(status))")
        }
    }
}
#endif
