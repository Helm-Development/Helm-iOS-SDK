import Foundation

/// One analytics event captured locally before flush.
internal struct AnalyticsEvent {
    let eventName: String
    let occurredAt: Date
    let sessionId: String
    let properties: [String: Any]
    /// HELM-241: the `debug` and `environment` values in force when this event
    /// was created, not when the batch is flushed. An event queued under one
    /// configuration keeps its own values even if the app is reconfigured before
    /// the flush — the same rule TAS-801 applies to queued attribution
    /// submissions in PendingSubmissionStore. Defaulted so tests and any other
    /// caller can construct an event without naming them.
    var debug: Bool = false
    var environment: String = "production"
    /// True once this event has survived one failed flush; retried events
    /// are dropped rather than re-queued a second time (spec §6).
    var retried: Bool = false

    /// The JSON shape `POST /api/v1/analytics/events/` expects per event.
    func payload() -> [String: Any] {
        // ISO8601DateFormatter is not thread-safe; create per call rather
        // than sharing a static instance across threads.
        let iso8601 = ISO8601DateFormatter()
        return [
            "event_name": eventName,
            "occurred_at": iso8601.string(from: occurredAt),
            "session_id": sessionId,
            "properties": properties,
            "debug": debug,
            "environment": environment,
        ]
    }
}

/// Thread-safe in-memory event buffer. Flush-on-background durability (spec §2):
/// nothing is persisted to disk.
internal final class EventQueue {

    static let flushThreshold = 50
    static let maxQueued = 500

    private var events: [AnalyticsEvent] = []
    private let lock = NSLock()

    /// Appends an event. Returns `true` when the queue has reached the
    /// flush threshold and the caller should flush.
    func enqueue(_ event: AnalyticsEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if events.count > Self.maxQueued {
            events.removeFirst(events.count - Self.maxQueued)
        }
        return events.count >= Self.flushThreshold
    }

    /// Removes and returns everything queued.
    func drain() -> [AnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        let drained = events
        events = []
        return drained
    }

    /// Puts failed events back at the front (preserving order), capped at `maxQueued`.
    func requeue(_ failed: [AnalyticsEvent]) {
        lock.lock(); defer { lock.unlock() }
        events = Array((failed + events).suffix(Self.maxQueued))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }
}
