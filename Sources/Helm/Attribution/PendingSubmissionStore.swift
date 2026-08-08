import Foundation
import os

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "attribution")

/// A promo-code or transaction submission that failed to reach the backend and
/// is waiting to be replayed.
///
/// Value type so entries cross `Task` boundaries cleanly, matching the
/// `PendingEvent` precedent in `Attribution`.
internal struct PendingSubmission: Codable, Equatable, Sendable {

    internal enum Kind: String, Codable, Sendable {
        case promoCode = "promo_code"
        case transaction
    }

    /// Stable identity so a replayed entry can be removed without relying on
    /// array indices (the queue can be mutated concurrently between reads).
    let id: String
    let kind: Kind
    let userId: String
    /// The promo code, or the StoreKit original transaction id.
    let value: String
    let enqueuedAt: Date

    init(id: String = UUID().uuidString,
         kind: Kind,
         userId: String,
         value: String,
         enqueuedAt: Date) {
        self.id = id
        self.kind = kind
        self.userId = userId
        self.value = value
        self.enqueuedAt = enqueuedAt
    }
}

/// Persists attribution submissions that failed for transport reasons so they
/// can be replayed once connectivity returns (HELM-220).
///
/// Only *transport* failures land here — a backend validation verdict
/// (`invalid_code`, `code_inactive`, `already_linked`, …) is terminal and never
/// queued. Entries older than `retentionWindow` are pruned on every access.
internal final class PendingSubmissionStore: @unchecked Sendable {

    private enum Keys {
        static let pending = "helm_attribution_pending_submissions"
    }

    /// How long a queued submission stays eligible for replay before it is
    /// dropped. Exposed for tests.
    static let retentionWindow: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    /// Hard cap on queue depth; the oldest entry is dropped on overflow so a
    /// permanently offline device can't grow UserDefaults without bound.
    static let maxQueued: Int = 100

    private let defaults: UserDefaults
    private let now: () -> Date

    /// Serializes every read-modify-write so two concurrent enqueues can't
    /// each read the same array and clobber the other's append.
    private let lock = NSLock()

    /// - Parameters:
    ///   - defaults: The UserDefaults suite to persist into. Injectable so test
    ///     suites don't pollute each other.
    ///   - now: Clock source, injectable so retention tests don't have to wait
    ///     30 days.
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Queue API

    /// All queued submissions in FIFO order, with expired entries already
    /// pruned (and the pruning persisted).
    func all() -> [PendingSubmission] {
        lock.lock()
        defer { lock.unlock() }
        return pruneLocked()
    }

    /// Append a submission to the queue.
    ///
    /// Skips the append when an identical `(kind, userId, value)` entry is
    /// already queued — replay is idempotent server-side, so duplicates would
    /// be harmless but wasteful.
    func enqueue(_ submission: PendingSubmission) {
        lock.lock()
        defer { lock.unlock() }

        var entries = pruneLocked()

        let isDuplicate = entries.contains {
            $0.kind == submission.kind && $0.userId == submission.userId && $0.value == submission.value
        }
        if isDuplicate {
            logger.info("pending submission already queued — skipping duplicate (kind=\(submission.kind.rawValue, privacy: .public))")
            return
        }

        entries.append(submission)

        if entries.count > Self.maxQueued {
            let overflow = entries.count - Self.maxQueued
            entries.removeFirst(overflow)
            logger.warning("pending submission queue full — dropped \(overflow, privacy: .public) oldest entries")
        }

        writeLocked(entries)
    }

    /// Remove a single submission by id. No-op when the id isn't queued.
    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = pruneLocked()
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before {
            writeLocked(entries)
        }
    }

    /// Drop the whole queue. Called from `Attribution.reset()` and
    /// `Analytics.clearIdentity()`.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Keys.pending)
    }

    /// Current queue depth (after pruning). Exposed for tests.
    var count: Int {
        all().count
    }

    // MARK: - Internals

    /// Read the queue, drop anything past the retention window, and persist the
    /// pruned array if it changed.
    ///
    /// - Important: must be called with `lock` held.
    private func pruneLocked() -> [PendingSubmission] {
        let entries = readLocked()
        let cutoff = now().addingTimeInterval(-Self.retentionWindow)
        let live = entries.filter { $0.enqueuedAt > cutoff }
        if live.count != entries.count {
            let dropped = entries.count - live.count
            logger.info("dropped \(dropped, privacy: .public) expired pending submission(s) older than 30 days")
            writeLocked(live)
        }
        return live
    }

    private func readLocked() -> [PendingSubmission] {
        guard let data = defaults.data(forKey: Keys.pending) else { return [] }
        do {
            return try Self.decoder.decode([PendingSubmission].self, from: data)
        } catch {
            // Corrupt or forward-incompatible payload: drop it rather than
            // wedging every future enqueue on the same decode failure.
            logger.error("pending submission queue unreadable — resetting: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: Keys.pending)
            return []
        }
    }

    private func writeLocked(_ entries: [PendingSubmission]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Keys.pending)
            return
        }
        do {
            defaults.set(try Self.encoder.encode(entries), forKey: Keys.pending)
        } catch {
            logger.error("failed to persist pending submission queue: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Dates are encoded as `timeIntervalSince1970` so the on-disk format stays
    /// stable and human-inspectable across SDK versions.
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
