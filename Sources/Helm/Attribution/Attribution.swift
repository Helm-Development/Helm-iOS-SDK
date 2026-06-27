import Foundation
import os

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "attribution")

/// Handles attribution matching and event tracking for Helm.
public final class Attribution: @unchecked Sendable {

    internal static let shared = Attribution()

    private let store: AttributionStore
    /// Source of the unified device identity (Keychain installation id).
    /// Injected so tests can supply a fixed id without Keychain access.
    private let installationId: () -> String
    /// Source of the bound user identity. Returns `nil` when anonymous.
    /// Injected so tests can supply a fixed hash without touching `.standard`
    /// UserDefaults or `Analytics.shared`.
    private let userHash: () -> String?

    // HELM-187: event queue + match-in-flight flag.
    //
    // The queue stores already-encoded entries (event_type + serialized
    // metadata) so each pending event is `Sendable`-safe. It's bounded at
    // `maxPendingEvents`; the oldest entry drops on overflow so a stuck
    // match can't grow the queue without bound.
    private let queueLock = NSLock()
    private var pendingEvents: [PendingEvent] = []
    private var matchInFlight: Bool = false
    private static let maxPendingEvents: Int = 100

    /// A queued event waiting for `match()` to resolve. Stored as
    /// already-encoded JSON `Data` for the metadata so the entry crosses
    /// Task / strict-concurrency boundaries cleanly.
    ///
    /// `userHash` is non-nil only for `incrementAuthenticated` events; plain
    /// `increment` events always carry `nil` so `user_hash` is never added to
    /// their request bodies.
    private struct PendingEvent: Sendable {
        let eventType: String
        let metadataData: Data?
        let userHash: String?
    }

    private init() {
        self.store = AttributionStore()
        self.installationId = { Analytics.shared.installationIdValue }
        self.userHash = { Analytics.shared.currentUserHash }
    }

    /// Internal initializer for tests. Allows injecting an `AttributionStore`
    /// backed by a non-`.standard` UserDefaults suite so suites don't
    /// pollute each other, an `installationId` closure to avoid Keychain
    /// access in unit tests, and a `userHash` closure to control identity
    /// without writing to `.standard` UserDefaults.
    internal init(store: AttributionStore,
                  installationId: @escaping () -> String = { Analytics.shared.installationIdValue },
                  userHash: @escaping () -> String? = { Analytics.shared.currentUserHash }) {
        self.store = store
        self.installationId = installationId
        self.userHash = userHash
    }

    // MARK: - Match

    /// Attempt to match the current device to an attribution source.
    ///
    /// This method returns immediately and performs work in the background.
    /// It is safe to call on every app launch -- if a match check has already
    /// been performed, subsequent calls are no-ops.
    public func match() {
        Task {
            await _match()
        }
    }

    /// Async variant of `match()`. Internal so tests can `await` the
    /// completion of a single match cycle. The public `match()` keeps the
    /// fire-and-forget shape integrators rely on.
    internal func _match() async {
        guard !store.hasChecked else {
            logger.info("match() skipped — already checked")
            return
        }

        // HELM-184: respect the bounded retry budget. Once exhausted, mark
        // checked so we stop hitting the server on every launch.
        guard store.canRetry else {
            logger.info("match() skipped — retry budget exhausted")
            store.markChecked()
            return
        }

        // HELM-187: any increment() calls that arrive between now and the
        // end of this method get queued so they can pick up the resolved
        // attribution_id (or null) instead of posting with no context.
        setMatchInFlight(true)
        defer { setMatchInFlight(false) }

        do {
            let deviceId = installationId()
            let signals = await DeviceSignals.collect()

            logger.info("match() starting — device_id=\(deviceId, privacy: .public) signals=\(signals.screenWidth)x\(signals.screenHeight)")

            var body = signals.toDict()
            body["device_id"] = deviceId

            let response = try await HelmHTTPClient.post(
                path: APIPath.attributionMatch,
                body: body
            )

            logger.info("match() response: \(response, privacy: .private)")

            if let matched = response["matched"] as? Bool, matched {
                let attributionId = response["attribution_id"] as? String ?? ""
                store.storeMatch(attributionId: attributionId)
                // Forward the token to analytics so the next registration carries
                // attribution_token and the server closes the pairing (HELM-203 #1b).
                Analytics.shared.onAttributionMatched(attributionId)
                logger.info("match() SUCCESS — attribution_id=\(attributionId, privacy: .private)")
            } else {
                store.storeUnmatched()
                logger.info("match() no match found")
            }

            store.markChecked()
            store.resetRetryBudget()
            await flushPendingEvents()
        } catch {
            logger.error("Attribution match failed: \(error.localizedDescription, privacy: .public)")
            store.recordFailedAttempt()
            if !store.canRetry {
                logger.info("match() retry budget exhausted — marking checked")
                store.markChecked()
                await flushPendingEvents()
            }
        }
    }

    // MARK: - Events

    /// Record an attribution event (fire-and-forget).
    ///
    /// - Parameters:
    ///   - eventType: The event name (e.g. "signup", "purchase").
    ///   - metadata: Optional key-value metadata attached to the event.
    public func increment(_ eventType: String, metadata: [String: Any]? = nil) {
        // Serialize metadata to JSON `Data` here so we cross the Task
        // boundary with a Sendable value. `[String: Any]` is not Sendable,
        // but `Data` is, and the caller's dictionary is treated as immutable
        // after this point.
        let metadataData: Data?
        if let metadata = metadata,
           let data = try? JSONSerialization.data(withJSONObject: metadata) {
            metadataData = data
        } else {
            metadataData = nil
        }

        // HELM-187: if a match is in flight, queue the event so it picks
        // up the resolved attribution_id (or null) once the match returns.
        // Otherwise fire immediately as before.
        queueLock.lock()
        if matchInFlight {
            pendingEvents.append(PendingEvent(eventType: eventType, metadataData: metadataData, userHash: nil))
            if pendingEvents.count > Self.maxPendingEvents {
                // Drop the oldest entry so the queue stays bounded.
                pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents)
            }
            queueLock.unlock()
            return
        }
        queueLock.unlock()

        Task {
            await _increment(eventType, metadataData: metadataData, userHash: nil)
        }
    }

    /// Record an attribution event tied to the authenticated user identity
    /// (fire-and-forget).
    ///
    /// Mirrors `increment()` but attaches `user_hash` to the event body so the
    /// server can associate the event with a known user when the endpoint gains
    /// first-party identity support. The `user_hash` is read from the value
    /// stored by `Analytics.identify(userHash:)` at call time; if no user is
    /// identified the method behaves identically to `increment()`.
    ///
    /// > **Server note:** the attribution-event endpoint does not yet consume
    /// > `user_hash` directly — identity is already associated at the
    /// > installation level via `identify()` → register. The field is included
    /// > for forward-compatibility and parity with the Android SDK; server-side
    /// > consumption is a follow-up task.
    ///
    /// - Parameters:
    ///   - eventType: The event name (e.g. "purchase", "trial_start").
    ///   - metadata: Optional key-value metadata attached to the event.
    public func incrementAuthenticated(_ eventType: String, metadata: [String: Any]? = nil) {
        let metadataData: Data?
        if let metadata = metadata,
           let data = try? JSONSerialization.data(withJSONObject: metadata) {
            metadataData = data
        } else {
            metadataData = nil
        }

        // Capture the user hash at call time (not at flush time) so the
        // identity snapshot is consistent with the event's logical moment.
        let hash = userHash()

        queueLock.lock()
        if matchInFlight {
            pendingEvents.append(PendingEvent(eventType: eventType, metadataData: metadataData, userHash: hash))
            if pendingEvents.count > Self.maxPendingEvents {
                pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents)
            }
            queueLock.unlock()
            return
        }
        queueLock.unlock()

        Task {
            await _increment(eventType, metadataData: metadataData, userHash: hash)
        }
    }

    private func _increment(_ eventType: String, metadataData: Data?, userHash: String?) async {
        do {
            let rawId = store.rawAttributionId

            var body: [String: Any] = [
                "event_type": eventType
            ]

            // Send null when no attribution, otherwise send the stored ID.
            if rawId.isEmpty {
                body["attribution_id"] = NSNull()
            } else {
                body["attribution_id"] = rawId
            }

            if let metadataData = metadataData,
               let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] {
                body["metadata"] = metadata
            }

            // Include user_hash only for authenticated events (non-nil hash).
            // Plain increment() always passes nil so user_hash is never sent.
            if let userHash = userHash {
                body["user_hash"] = userHash
            }

            _ = try await HelmHTTPClient.post(
                path: APIPath.attributionEvent,
                body: body
            )
        } catch {
            logger.error("Attribution increment failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drain the pending-event queue, posting each event with the now-resolved
    /// attribution context. Called from `_match()` once the SDK has a final
    /// attribution decision (success path or budget-exhausted failure path).
    private func flushPendingEvents() async {
        let drained = drainPendingEvents()
        for entry in drained {
            await _increment(entry.eventType, metadataData: entry.metadataData, userHash: entry.userHash)
        }
    }

    /// Drain the queue under the lock and return its contents. Kept
    /// synchronous so the `NSLock` lock/unlock pair never spans an `await`
    /// suspension point (Swift 6 forbids `NSLock.unlock` from async
    /// contexts).
    private func drainPendingEvents() -> [PendingEvent] {
        queueLock.lock()
        defer { queueLock.unlock() }
        let drained = pendingEvents
        pendingEvents.removeAll()
        return drained
    }

    /// Set the match-in-flight flag under the lock. Synchronous for the
    /// same Swift 6 reason as `drainPendingEvents()`.
    private func setMatchInFlight(_ value: Bool) {
        queueLock.lock()
        defer { queueLock.unlock() }
        matchInFlight = value
    }

    // MARK: - Test Hooks

    /// Internal accessor for tests that need to observe the in-flight flag.
    internal var testHook_isMatchInFlight: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return matchInFlight
    }

    /// Internal accessor for tests that need to observe queue depth.
    internal var testHook_pendingEventCount: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return pendingEvents.count
    }

    // MARK: - Reset

    /// Reset all SDK attribution state so the next `match()` runs as if this
    /// were a fresh install: a new `device_id` is generated, `hasChecked`
    /// flips back to false, the stored `attribution_id` is cleared, the
    /// retry budget is cleared, and any pending events queued by HELM-187
    /// are dropped.
    ///
    /// Call this when the host app logs the user out and a different user
    /// logs in on the same device, or when an account-deletion flow needs
    /// to remove SDK-stored identifiers (App Review Guideline 5.1.1(v)).
    public func reset() {
        // Drop any queued events and clear the match-in-flight flag so a
        // post-reset `match()` starts cleanly.
        queueLock.lock()
        pendingEvents.removeAll()
        matchInFlight = false
        queueLock.unlock()

        store.clearAll()
    }

}
