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
    private let attributionStore: AttributionStore
    /// HELM-220: cleared on `clearIdentity()` so a logout leaves no
    /// host-supplied `userId` on device.
    private let pendingSubmissionStore: PendingSubmissionStore
    private let statusCache: AttributionStatusCache
    private let stateLock = NSLock()
    private var started = false
    /// The attribution_token forwarded from a successful `match()` response.
    /// Guarded by `stateLock`. Mirrors Android's `@Volatile attributionToken`.
    private var attributionToken: String?
    private var flushTimer: DispatchSourceTimer?
    private var observerTokens: [NSObjectProtocol] = []
    private static let flushInterval: TimeInterval = 30

    internal init(installationStore: InstallationStore = InstallationStore(),
                  identityStore: IdentityStore = IdentityStore(),
                  sessionManager: SessionManager = SessionManager(),
                  queue: EventQueue = EventQueue(),
                  attributionStore: AttributionStore = AttributionStore(),
                  pendingSubmissionStore: PendingSubmissionStore = PendingSubmissionStore(),
                  statusCache: AttributionStatusCache = AttributionStatusCache()) {
        self.installationStore = installationStore
        self.identityStore = identityStore
        self.sessionManager = sessionManager
        self.queue = queue
        self.attributionStore = attributionStore
        self.pendingSubmissionStore = pendingSubmissionStore
        self.statusCache = statusCache
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
        // Seed the attribution token inside the same lock so the first register()
        // call below already carries the token from a prior match() (Android §92).
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        attributionToken = attributionStore.attributionId
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
    ///
    /// HELM-220: also drops the offline attribution submission queue and the
    /// per-user attribution status cache. Both hold the host-supplied `userId`,
    /// so leaving them behind would let the next user on this device replay the
    /// previous user's promo code or read their offering.
    public func clearIdentity() {
        identityStore.clear()
        pendingSubmissionStore.clearAll()
        statusCache.clearAll()
    }

    /// Called by `Attribution._match()` on a successful attribution match.
    /// Stores the token and, if analytics has started, re-registers so the
    /// server closes the Attribution → Installation join via
    /// `_close_attribution_pairing`. Robust to launch ordering: if `start()`
    /// hasn't been called yet the token is seeded later in `start()`.
    internal func onAttributionMatched(_ attributionId: String) {
        stateLock.lock()
        attributionToken = attributionId.isEmpty ? nil : attributionId
        stateLock.unlock()
        if isStarted { register() }
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

    /// The Keychain-backed installation id. Exposed internally so `Attribution`
    /// can use it as the unified `device_id` instead of the old UserDefaults UUID.
    internal var installationIdValue: String { installationStore.installationId }

    /// The stored user hash, or `nil` when anonymous. Exposed internally so
    /// `Attribution.incrementAuthenticated` can attach identity to event bodies.
    internal var currentUserHash: String? { identityStore.userHash }

    /// Test hook: current attribution token (nil if none set).
    internal var testHook_attributionToken: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return attributionToken
    }

    /// Test hook: clear the attribution token between tests to prevent cross-test
    /// pollution when `Analytics.shared` is used in `AttributionTests`.
    internal func testHook_clearAttributionToken() {
        stateLock.lock()
        attributionToken = nil
        stateLock.unlock()
    }

    private var isStarted: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return started
    }

    private func register() {
        let installationId = installationStore.installationId
        let userHash = identityStore.userHash ?? ""
        stateLock.lock()
        let token = attributionToken
        stateLock.unlock()
        Task {
            do {
                try await AnalyticsClient.registerInstallation(installationId: installationId,
                                                               userHash: userHash,
                                                               attributionToken: token)
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
