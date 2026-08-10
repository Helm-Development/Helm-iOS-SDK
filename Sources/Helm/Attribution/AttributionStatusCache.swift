import Foundation
import os

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "attribution")

/// The last attribution status the backend confirmed for a given user.
internal struct CachedStatus: Codable, Equatable, Sendable {
    let isLinked: Bool
    let influencerCode: String?
    let offeringId: String?
    let fetchedAt: Date
    /// TAS-801: the sandbox marker the status was fetched (or linked) under.
    /// Storage stays keyed per-`userId`; a read whose environment doesn't match
    /// the current configuration is treated as a **miss** rather than served, so
    /// a live paywall never renders an offering confirmed against sandbox data.
    let debug: Bool

    init(isLinked: Bool,
         influencerCode: String?,
         offeringId: String?,
         fetchedAt: Date,
         debug: Bool = false) {
        self.isLinked = isLinked
        self.influencerCode = influencerCode
        self.offeringId = offeringId
        self.fetchedAt = fetchedAt
        self.debug = debug
    }

    private enum CodingKeys: String, CodingKey {
        case isLinked, influencerCode, offeringId, fetchedAt, debug
    }

    /// TAS-801: same reasoning as `PendingSubmission` — a 1.3.0 cache entry has
    /// no `debug` key and must decode as live instead of wiping the whole cache
    /// (`readLocked()` resets on any decode failure).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isLinked = try container.decode(Bool.self, forKey: .isLinked)
        self.influencerCode = try container.decodeIfPresent(String.self, forKey: .influencerCode)
        self.offeringId = try container.decodeIfPresent(String.self, forKey: .offeringId)
        self.fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        self.debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }
}

/// Caches the last successful attribution status **per userId** so a paywall can
/// still render the correct offering while offline (HELM-220).
///
/// Keying by `userId` matters: a device that switches accounts must never serve
/// user A's influencer offering to user B.
///
/// There is no TTL — HELM-218 specifies "last successful status" semantics, and
/// `AttributionStatus.fromCache` is the staleness signal the host app reacts to.
internal final class AttributionStatusCache: @unchecked Sendable {

    private enum Keys {
        static let cache = "helm_attribution_status_cache"
    }

    /// Maximum number of users retained. Beyond this the oldest `fetchedAt`
    /// entry is evicted so a pathological multi-account device can't grow
    /// UserDefaults without bound. Exposed for tests.
    static let maxEntries: Int = 5

    private let defaults: UserDefaults

    /// Serializes the read-modify-write of the userId → status map.
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - API

    /// The cached status for a user, or `nil` when nothing has been cached.
    func status(for userId: String) -> CachedStatus? {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()[userId]
    }

    /// Store (or overwrite) the status for a user.
    func store(_ status: CachedStatus, for userId: String) {
        lock.lock()
        defer { lock.unlock() }

        var map = readLocked()
        map[userId] = status

        if map.count > Self.maxEntries {
            // Evict oldest-first until we're back at the cap.
            let ordered = map.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            for entry in ordered.prefix(map.count - Self.maxEntries) {
                map.removeValue(forKey: entry.key)
            }
            logger.info("attribution status cache full — evicted oldest entries")
        }

        writeLocked(map)
    }

    /// Drop every cached status. Called from `Attribution.reset()` and
    /// `Analytics.clearIdentity()`.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Keys.cache)
    }

    /// Number of cached users. Exposed for tests.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return readLocked().count
    }

    // MARK: - Internals

    private func readLocked() -> [String: CachedStatus] {
        guard let data = defaults.data(forKey: Keys.cache) else { return [:] }
        do {
            return try Self.decoder.decode([String: CachedStatus].self, from: data)
        } catch {
            logger.error("attribution status cache unreadable — resetting: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: Keys.cache)
            return [:]
        }
    }

    private func writeLocked(_ map: [String: CachedStatus]) {
        if map.isEmpty {
            defaults.removeObject(forKey: Keys.cache)
            return
        }
        do {
            defaults.set(try Self.encoder.encode(map), forKey: Keys.cache)
        } catch {
            logger.error("failed to persist attribution status cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
