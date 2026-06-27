import Foundation

/// One log entry captured locally before flush.
internal struct LogEntry {
    let message: String
    let level: HelmLogLevel
    let attributes: [String: String]
    /// Nanoseconds since Unix epoch, required by OTLP as `timeUnixNano`.
    let timestampNanos: UInt64
    /// True once this entry has survived one failed flush; retried entries are
    /// dropped rather than re-queued a second time (mirrors `AnalyticsEvent.retried`).
    var retried: Bool = false

    init(message: String,
         level: HelmLogLevel,
         attributes: [String: String] = [:],
         timestampNanos: UInt64) {
        self.message = message
        self.level = level
        self.attributes = attributes
        self.timestampNanos = timestampNanos
    }

    /// The OTLP log record shape that `LoggingClient` embeds in the envelope.
    /// `timeUnixNano` is sent as a string (OTLP/HTTP JSON spec; the server's
    /// `_build_otlp_payload` reads it as a string).
    func payload() -> [String: Any] {
        let attrs: [[String: Any]] = attributes.map { key, value in
            ["key": key, "value": ["stringValue": value]]
        }
        return [
            "timeUnixNano": "\(timestampNanos)",
            "severityNumber": level.severityNumber,
            "severityText": level.severityText,
            "body": ["stringValue": message],
            "attributes": attrs,
        ]
    }
}

/// Thread-safe in-memory log buffer. Mirrors `EventQueue` — NSLock, flush
/// threshold, cap, drain/requeue. Nothing is persisted to disk.
internal final class LogQueue {

    static let flushThreshold = 20
    static let maxQueued = 200

    private var entries: [LogEntry] = []
    private let lock = NSLock()

    /// Appends an entry. Returns `true` when the queue has reached the flush
    /// threshold and the caller should flush immediately.
    func enqueue(_ entry: LogEntry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > Self.maxQueued {
            entries.removeFirst(entries.count - Self.maxQueued)
        }
        return entries.count >= Self.flushThreshold
    }

    /// Removes and returns all queued entries.
    func drain() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        let drained = entries
        entries = []
        return drained
    }

    /// Puts failed entries back at the front (preserving order), capped at `maxQueued`.
    func requeue(_ failed: [LogEntry]) {
        lock.lock(); defer { lock.unlock() }
        entries = Array((failed + entries).suffix(Self.maxQueued))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
