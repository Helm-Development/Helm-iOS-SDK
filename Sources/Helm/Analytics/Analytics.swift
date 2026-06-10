import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "analytics")

/// Product analytics: installation registration, sessions, event batching,
/// and the identity headers for the app's own API traffic.
///
/// Usage:
/// ```
/// Helm.configure(publishableKey: "pk_...", baseURL: "https://helmcode.dev")
/// Helm.analytics.start()
/// // after login:
/// Helm.analytics.identify(userHash: response.helmUserHash)
/// // in your API client:
/// Helm.analytics.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
/// ```
public final class Analytics: @unchecked Sendable {

    internal static let shared = Analytics()

    private let installationStore: InstallationStore
    private let identityStore: IdentityStore
    private let sessionManager: SessionManager
    private let queue: EventQueue
    private let stateLock = NSLock()
    private var started = false
    private var flushTimer: DispatchSourceTimer?
    private var observerTokens: [NSObjectProtocol] = []
    private static let flushInterval: TimeInterval = 30

    internal init(installationStore: InstallationStore = InstallationStore(),
                  identityStore: IdentityStore = IdentityStore(),
                  sessionManager: SessionManager = SessionManager(),
                  queue: EventQueue = EventQueue()) {
        self.installationStore = installationStore
        self.identityStore = identityStore
        self.sessionManager = sessionManager
        self.queue = queue
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver(_:))
        flushTimer?.cancel()
    }

    // MARK: - Public API

    /// Activates analytics: registers the installation with Helm and begins
    /// session/lifecycle tracking and timed flushes. Call once after `Helm.configure`.
    public func start() {
        guard Configuration.shared != nil else {
            logger.warning("start() before Helm.configure(...) — ignored")
            return
        }
        // Check-and-set under the lock so concurrent double-start is impossible.
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()
        observeLifecycle()
        startFlushTimer()
        register()
    }

    /// Bind the user identity from the login response's `helm_user_hash`.
    public func identify(userHash: String) {
        identityStore.store(userHash: userHash)
        if isStarted { register() } // re-registration binds the hash server-side
    }

    /// Drop the identity on logout. The installation stays bound server-side
    /// to its last-known user (spec §5).
    public func clearIdentity() {
        identityStore.clear()
    }

    /// Queue a custom event. Flushes automatically at 50 events / 30 s / background.
    public func track(_ name: String, properties: [String: Any] = [:]) {
        guard isStarted else {
            logger.warning("track(\"\(name, privacy: .public)\") before start() — dropped")
            return
        }
        let event = AnalyticsEvent(eventName: name,
                                   occurredAt: Date(),
                                   sessionId: sessionManager.sessionId,
                                   properties: properties)
        if queue.enqueue(event) {
            flush()
        }
    }

    /// Identity headers for the app's own backend traffic.
    public var headers: [String: String] {
        var headers = [
            "X-Helm-Installation-Id": installationStore.installationId,
            "X-Helm-Session-Id": sessionManager.sessionId,
            "X-Helm-App-Version": AnalyticsClient.appVersion(),
            "X-Helm-Platform": AnalyticsClient.platformName(),
        ]
        if let userHash = identityStore.userHash {
            headers["X-Helm-User-Hash"] = userHash
        }
        return headers
    }

    /// Sends queued events now. Called automatically; public for app-background hooks.
    public func flush() {
        Task { await flushNow() }
    }

    // MARK: - Internals

    /// Test hook: current queue depth.
    internal var queuedEventCount: Int { queue.count }

    private var isStarted: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return started
    }

    private func register() {
        let installationId = installationStore.installationId
        let userHash = identityStore.userHash ?? ""
        Task {
            do {
                try await AnalyticsClient.registerInstallation(installationId: installationId,
                                                               userHash: userHash)
            } catch {
                // Registration retries on next launch; never surfaces (spec §6).
                logger.error("registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushNow() async {
        let batch = queue.drain()
        guard !batch.isEmpty else { return }
        do {
            try await AnalyticsClient.sendEvents(installationId: installationStore.installationId,
                                                 events: batch)
        } catch let HelmError.serverError(code, body) {
            if code == 429 || code >= 500 {
                requeueOnce(batch) // next timer tick (≥30 s) provides the backoff
            } else {
                logger.error("events rejected (\(code)): \(body, privacy: .public) — dropped")
            }
        } catch {
            requeueOnce(batch) // network error
        }
    }

    private func requeueOnce(_ batch: [AnalyticsEvent]) {
        let retryable = batch.filter { !$0.retried }.map { event -> AnalyticsEvent in
            var copy = event
            copy.retried = true
            return copy
        }
        if retryable.count < batch.count {
            logger.warning("dropped \(batch.count - retryable.count) events after second failure")
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
            self?.sessionManager.appDidEnterBackground()
            self?.flush() // flush-on-background durability (spec §2)
        }
        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessionManager.appWillEnterForeground()
        }
        observerTokens.append(contentsOf: [background, foreground])
        #endif
    }
}
