import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "logging")

/// Ephemeral structured logging: batches `LogEntry` records and ships them to
/// Helm's OTLP ingest endpoint (`POST /api/v1/logs`) using an `hlit_…` ingest
/// token. **Preview / non-production only** — when no ingest token is configured
/// every call is a silent no-op, so production builds are unaffected.
///
/// Usage (preview / staging only):
/// ```swift
/// Helm.configure(publishableKey: "pk_…", baseURL: "https://helmcode.dev")
/// Helm.logging.configure(ingestToken: "hlit_…",
///                        environment: "preview",
///                        serviceName: "MyApp")
/// Helm.logging.start()
///
/// // Later:
/// Helm.logging.log("User tapped sign-in", level: .info, attributes: ["screen": "auth"])
/// ```
public final class Logging: @unchecked Sendable {

    internal static let shared = Logging()

    private let queue: LogQueue
    private let stateLock = NSLock()

    // MARK: - Configuration (guarded by stateLock)
    private var ingestToken: String?
    private var environment: String = "preview"
    private var serviceName: String = "helm-ios"
    private var commitSha: String?

    // MARK: - Lifecycle state (guarded by stateLock)
    private var started = false
    private var flushTimer: DispatchSourceTimer?
    private var observerTokens: [NSObjectProtocol] = []

    private static let flushInterval: TimeInterval = 30

    internal init(queue: LogQueue = LogQueue()) {
        self.queue = queue
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver(_:))
        flushTimer?.cancel()
    }

    // MARK: - Public API

    /// Configure the logging module with an ingest token and service metadata.
    ///
    /// Must be called before `start()`. When called without an ingest token
    /// (or with an empty string) logging remains a no-op.
    ///
    /// - Parameters:
    ///   - ingestToken: The `hlit_…` ingest token from the Helm dashboard.
    ///     Distinct from the publishable key — scoped to preview/non-prod.
    ///   - environment: The deployment environment (e.g. "preview", "staging").
    ///   - serviceName: The service/app name sent as the OTLP `service.name`
    ///     resource attribute.
    ///   - commitSha: Optional VCS commit SHA, sent as `helm.commit.sha`.
    public func configure(ingestToken: String,
                          environment: String,
                          serviceName: String,
                          commitSha: String? = nil) {
        stateLock.lock()
        self.ingestToken = ingestToken.isEmpty ? nil : ingestToken
        self.environment = environment
        self.serviceName = serviceName
        self.commitSha = commitSha
        stateLock.unlock()
    }

    /// Activates periodic flushing and background-flush lifecycle hooks.
    ///
    /// Requires `configure(ingestToken:…)` to have been called first with a
    /// non-empty token; otherwise this is a no-op.
    /// Requires `Helm.configure(…)` to have been called (for the base URL +
    /// session); ignored with a warning if it has not.
    public func start() {
        guard Configuration.shared != nil else {
            logger.warning("Logging.start() before Helm.configure(...) — ignored")
            return
        }
        guard hasToken else {
            logger.debug("Logging.start() with no ingest token — logging is disabled")
            return
        }
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()
        observeLifecycle()
        startFlushTimer()
    }

    /// Queue a log message. Auto-flushes at 20 entries / 30 s / background entry.
    ///
    /// Silent no-op when no ingest token is configured.
    public func log(_ message: String,
                    level: HelmLogLevel = .info,
                    attributes: [String: String] = [:]) {
        guard hasToken else { return }
        let nanos = UInt64(max(0, Date().timeIntervalSince1970) * 1_000_000_000)
        let entry = LogEntry(message: message,
                             level: level,
                             attributes: attributes,
                             timestampNanos: nanos)
        if queue.enqueue(entry) {
            flush()
        }
    }

    /// Trigger an immediate async flush. Called automatically; exposed for
    /// app-background hooks and as a test convenience via `flushNow()`.
    public func flush() {
        Task { await flushNow() }
    }

    // MARK: - Internals (test hooks)

    /// Current queue depth. Exposed for `XCTest` assertions.
    internal var queuedLogCount: Int { queue.count }

    /// `await`-able flush for deterministic testing. Unlike `flush()`, callers
    /// can `await` this directly to know when the network round-trip completes.
    internal func flushNow() async {
        // Snapshot config under the lock in a synchronous context to avoid the
        // Swift 6 "NSLock unavailable from async contexts" diagnostic.
        let (token, env, svc, sha) = currentFlushConfig()
        guard let token else { return }

        let batch = queue.drain()
        guard !batch.isEmpty else { return }

        do {
            try await LoggingClient.sendLogs(ingestToken: token,
                                             environment: env,
                                             serviceName: svc,
                                             commitSha: sha,
                                             entries: batch)
        } catch let HelmError.serverError(code, body) {
            if code == 429 || code >= 500 {
                requeueOnce(batch)  // next timer tick (≥30 s) provides the backoff
            } else {
                logger.error("logs rejected (\(code)): \(body, privacy: .public) — dropped")
            }
        } catch {
            requeueOnce(batch) // network / encoding error
        }
    }

    // MARK: - Private

    private var hasToken: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return ingestToken != nil
    }

    /// Snapshot the flush-relevant configuration fields under the lock.
    /// Called from the synchronous entry point before `await` so that the
    /// `NSLock` is not held across a suspension point (Swift 6 safe).
    private func currentFlushConfig() -> (token: String?, env: String, svc: String, sha: String?) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (ingestToken, environment, serviceName, commitSha)
    }

    private func requeueOnce(_ batch: [LogEntry]) {
        let retryable = batch.filter { !$0.retried }.map { entry -> LogEntry in
            var copy = entry
            copy.retried = true
            return copy
        }
        if retryable.count < batch.count {
            logger.warning("dropped \(batch.count - retryable.count) log entries after second failure")
        }
        queue.requeue(retryable)
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        stateLock.lock()
        flushTimer = timer
        stateLock.unlock()
    }

    private func observeLifecycle() {
        #if canImport(UIKit) && os(iOS)
        let background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        }
        stateLock.lock()
        observerTokens.append(background)
        stateLock.unlock()
        #endif
    }
}
