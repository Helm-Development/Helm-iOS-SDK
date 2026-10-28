import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "attribution")

/// Handles attribution matching and event tracking for Helm.
public final class Attribution: @unchecked Sendable {

    internal static let shared = Attribution()

    private let store: AttributionStore
    /// HELM-220: transport-failed promo-code / transaction submissions waiting
    /// for connectivity.
    private let pendingStore: PendingSubmissionStore
    /// HELM-220: last server-confirmed attribution status, per userId.
    private let statusCache: AttributionStatusCache
    /// Source of the unified device identity (Keychain installation id).
    /// Injected so tests can supply a fixed id without Keychain access.
    private let installationId: () -> String
    /// Source of the bound user identity. Returns `nil` when anonymous.
    /// Injected so tests can supply a fixed hash without touching `.standard`
    /// UserDefaults or `Analytics.shared`.
    private let userHash: () -> String?
    /// HELM-325: the clipboard, reached only through calls that do not show
    /// the paste prompt. Injected so tests never touch the real clipboard.
    private let pasteboard: PasteboardAccess
    /// HELM-336: the AdServices attribution token. Injected so tests never
    /// call the real framework.
    private let appleAdsTokenProvider: AppleAdsTokenProviding

    // HELM-336: one Apple Ads check at a time, and none for the rest of this
    // launch after AdServices fails to make a token.
    private let appleAdsLock = NSLock()
    private var appleAdsInFlight = false
    private var appleAdsStoppedForThisLaunch = false

    // HELM-187: event queue + match-in-flight state.
    //
    // The queue stores already-encoded entries (event_type + serialized
    // metadata) so each pending event is `Sendable`-safe. It's bounded at
    // `maxPendingEvents`; the oldest entry drops on overflow so a stuck
    // match can't grow the queue without bound.
    //
    // HELM-325: `match()` and a clipboard handoff redeem can both be deciding
    // the attribution at the same time, so this is a count rather than a flag.
    // Events stay queued until the count is back to zero, and the queue is
    // flushed then if any of the finished requests reached a final answer.
    private let queueLock = NSLock()
    private var pendingEvents: [PendingEvent] = []
    private var resolutionsInFlight: Int = 0
    private var flushWhenIdle: Bool = false
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

    // HELM-220: guards the replay-in-flight flag only. A separate lock from
    // `queueLock` so a replay can never contend with event queueing.
    private let replayLock = NSLock()
    private var replayInFlight = false

    /// Foreground-notification observers. Registered only by the private
    /// singleton `init()` so test-constructed instances stay observer-free.
    private var observerTokens: [NSObjectProtocol] = []

    // HELM-325: clipboard watching. Starts on the first
    // `hasClipboardHandoff()` call, and only on the shared instance (or when a
    // test asks for it), so apps that never use the clipboard handoff never
    // have the clipboard checked.
    private let clipboardLock = NSLock()
    private let watchesClipboard: Bool
    private var clipboardWatchStarted = false
    private var lastClipboardAvailability: Bool?

    private init() {
        self.store = AttributionStore()
        self.pendingStore = PendingSubmissionStore()
        self.statusCache = AttributionStatusCache()
        self.installationId = { Analytics.shared.installationIdValue }
        self.userHash = { Analytics.shared.currentUserHash }
        self.pasteboard = DefaultPasteboard.make()
        // The SDK ships for iOS; the macOS build exists so `swift test` can
        // run. Only iOS asks AdServices, so test runs on a Mac never do.
        #if os(iOS)
        self.appleAdsTokenProvider = SystemAppleAdsTokenProvider()
        #else
        self.appleAdsTokenProvider = UnavailableAppleAdsTokenProvider()
        #endif
        self.watchesClipboard = true
        observeForeground()
    }

    /// Internal initializer for tests. Allows injecting an `AttributionStore`
    /// backed by a non-`.standard` UserDefaults suite so suites don't
    /// pollute each other, an `installationId` closure to avoid Keychain
    /// access in unit tests, and a `userHash` closure to control identity
    /// without writing to `.standard` UserDefaults.
    ///
    /// HELM-220 adds matching seams for the pending-submission queue and the
    /// attribution status cache. Deliberately does **not** register the
    /// foreground observer — replay triggers are exercised through
    /// `_replayPendingSubmissions()` directly.
    ///
    /// HELM-325 adds a `pasteboard` seam. Clipboard watching stays off unless
    /// `watchesClipboard` is `true`; re-checks are exercised through
    /// `recheckClipboardHandoff()` directly.
    ///
    /// HELM-336 adds an `appleAdsTokenProvider` seam. The default reports
    /// that AdServices is unavailable, so test instances never call it.
    internal init(store: AttributionStore,
                  pendingStore: PendingSubmissionStore = PendingSubmissionStore(),
                  statusCache: AttributionStatusCache = AttributionStatusCache(),
                  installationId: @escaping () -> String = { Analytics.shared.installationIdValue },
                  userHash: @escaping () -> String? = { Analytics.shared.currentUserHash },
                  pasteboard: PasteboardAccess = NoPasteboard(),
                  watchesClipboard: Bool = false,
                  appleAdsTokenProvider: AppleAdsTokenProviding = UnavailableAppleAdsTokenProvider()) {
        self.store = store
        self.pendingStore = pendingStore
        self.statusCache = statusCache
        self.installationId = installationId
        self.userHash = userHash
        self.pasteboard = pasteboard
        self.watchesClipboard = watchesClipboard
        self.appleAdsTokenProvider = appleAdsTokenProvider
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver(_:))
    }

    /// Replay the offline submission queue whenever the app returns to the
    /// foreground — the moment connectivity is most likely to have returned.
    /// Mirrors `Analytics.observeLifecycle()`.
    ///
    /// HELM-336: also retry an unfinished Apple Ads check.
    private func observeForeground() {
        #if canImport(UIKit) && os(iOS)
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.replayPendingSubmissions()
            self?.startAppleAdsCheck()
        }
        observerTokens.append(token)
        #endif
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

        // HELM-325 / HELM-336: an exact attribution (clipboard handoff or
        // Apple Ads) always wins over `match()`, so there is nothing left for
        // `match()` to decide.
        guard !store.hasExactAttribution else {
            logger.info("match() skipped — an exact attribution is already stored")
            store.markChecked()
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
        beginResolution()
        // Whether this call reached a final answer, so queued events can be
        // sent. A failure that will be retried leaves them queued.
        var resolved = false

        do {
            let deviceId = installationId()
            let signals = await DeviceSignals.collect()

            logger.info("match() starting — device_id=\(deviceId, privacy: .public) signals=\(signals.screenWidth)x\(signals.screenHeight)")

            var body = signals.toDict()
            body["device_id"] = deviceId
            // HELM-241: `match` sends `debug` like the three influencer
            // endpoints already do, so a debug build's match attempt is marked
            // as sandbox data rather than live activity.
            body["debug"] = currentDebug()

            let response = try await HelmHTTPClient.post(
                path: APIPath.attributionMatch,
                body: body
            )

            logger.info("match() response: \(response, privacy: .private)")

            if store.hasExactAttribution {
                // HELM-325 / HELM-336: a clipboard handoff or Apple Ads match
                // finished while this request was in flight. It wins whichever
                // finishes last.
                logger.info("match() result ignored — an exact attribution arrived first")
            } else if let matched = response["matched"] as? Bool, matched {
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
            resolved = true
        } catch {
            logger.error("Attribution match failed: \(error.localizedDescription, privacy: .public)")
            store.recordFailedAttempt()
            if !store.canRetry {
                logger.info("match() retry budget exhausted — marking checked")
                store.markChecked()
                resolved = true
            }
        }

        await endResolution(resolved: resolved)
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
        if resolutionsInFlight > 0 {
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
        if resolutionsInFlight > 0 {
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
                "event_type": eventType,
                // HELM-241: same `debug` marker the three influencer endpoints
                // already send.
                "debug": currentDebug(),
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
    /// attribution context. Called through `endResolution(resolved:)` once the
    /// SDK has a final attribution decision (success path or budget-exhausted
    /// failure path) and nothing else is still deciding it.
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

    /// Record that a request deciding the attribution (`match()` or a
    /// clipboard handoff redeem) has started. Synchronous for the same Swift 6
    /// reason as `drainPendingEvents()`.
    private func beginResolution() {
        queueLock.lock()
        defer { queueLock.unlock() }
        resolutionsInFlight += 1
    }

    /// Record that a request deciding the attribution has finished, and send
    /// the queued events once nothing else is still deciding it.
    ///
    /// - Parameter resolved: whether this request reached a final answer. A
    ///   failure that will be retried passes `false`, which leaves the events
    ///   queued unless another request has already reached a final answer.
    private func endResolution(resolved: Bool) async {
        if finishResolution(resolved: resolved) {
            await flushPendingEvents()
        }
    }

    /// The locked half of `endResolution(resolved:)`. Returns `true` when the
    /// caller should flush the queue now.
    private func finishResolution(resolved: Bool) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        resolutionsInFlight = max(0, resolutionsInFlight - 1)
        if resolved { flushWhenIdle = true }
        guard resolutionsInFlight == 0, flushWhenIdle else { return false }
        flushWhenIdle = false
        return true
    }

    // MARK: - Clipboard handoff (HELM-325)

    /// Whether the app should show the Paste button (`HelmPasteButton`, or the
    /// control from `makePasteControl(configuration:onResult:)`) so the user
    /// can hand over the code Helm's download page copied.
    ///
    /// Checks the clipboard without showing the paste prompt or the "pasted
    /// from" notice: it only asks iOS whether the clipboard probably holds a
    /// web URL. It never reads the clipboard's contents.
    ///
    /// Returns `false`:
    /// - on iOS 15 and on macOS, which have no Paste button;
    /// - once a clipboard handoff code has been redeemed for this installation,
    ///   or while a redeem is waiting to be sent again;
    /// - when the user already pasted the current clipboard contents and they
    ///   did not attribute the install.
    ///
    /// After the first call, the SDK checks again when the app returns to the
    /// foreground and when the clipboard changes, and posts
    /// `Notification.Name.helmClipboardHandoffAvailabilityDidChange` when the
    /// answer changes.
    public func hasClipboardHandoff() async -> Bool {
        startClipboardWatchIfNeeded()
        let available = await evaluateClipboardHandoff()
        recordClipboardAvailability(available, notify: false)
        return available
    }

    /// The answer to `hasClipboardHandoff()`, without starting the watch or
    /// recording the result.
    internal func evaluateClipboardHandoff() async -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        if store.clipboardRedeemed { return false }
        if hasQueuedClipboardHandoff { return false }
        if let dismissed = store.clipboardDismissedChangeCount,
           dismissed == pasteboard.changeCount {
            return false
        }
        return await pasteboard.hasProbableWebURL()
    }

    /// Whether a clipboard handoff code is in the offline queue.
    private var hasQueuedClipboardHandoff: Bool {
        pendingStore.all().contains { $0.kind == .clipboardHandoff }
    }

    /// The clipboard's change count right now. Read by the Paste button views
    /// at the moment of the paste. Reading it does not prompt.
    internal var pasteboardChangeCount: Int {
        pasteboard.changeCount
    }

    /// Called by the Paste button views with the items the user pasted.
    /// Loads a URL from them and redeems it in the background, then reports
    /// the result on the main actor.
    ///
    /// - Parameters:
    ///   - itemProviders: The pasted items (URLs or plain text).
    ///   - changeCountAtPaste: `pasteboardChangeCount` read when the paste
    ///     happened, so the clipboard is cleared only if it still holds the
    ///     pasted code.
    ///   - onResult: The app's completion handler.
    internal func handlePaste(itemProviders: [NSItemProvider],
                              changeCountAtPaste: Int,
                              onResult: (@MainActor (ClipboardHandoffResult) -> Void)?) {
        Task {
            let result = await _handlePaste(itemProviders: itemProviders, changeCountAtPaste: changeCountAtPaste)
            if let onResult {
                await MainActor.run { onResult(result) }
            }
        }
    }

    /// Async variant of `handlePaste(itemProviders:changeCountAtPaste:onResult:)`.
    /// Internal so tests can `await` the result.
    internal func _handlePaste(itemProviders: [NSItemProvider],
                               changeCountAtPaste: Int) async -> ClipboardHandoffResult {
        let url = await PastedItemLoader.url(from: itemProviders)
        return await _redeemClipboardHandoff(url, changeCountAtPaste: changeCountAtPaste)
    }

    /// Redeem a pasted clipboard handoff URL with Helm.
    ///
    /// - A URL whose path is not `/h/<code>/` is ignored: nothing is sent and
    ///   the result is `.notMatched(reason: "not_handoff_url")`.
    /// - `matched: true` marks the code as redeemed. When the response says
    ///   the attribution is `primary`, its ID replaces any stored attribution
    ///   ID (including a `match()` result) and is passed to analytics. The
    ///   clipboard is then cleared if it has not changed since the paste.
    /// - `matched: false` stores nothing new.
    /// - A transport failure queues the code for replay.
    internal func _redeemClipboardHandoff(_ url: URL?, changeCountAtPaste: Int) async -> ClipboardHandoffResult {
        guard let url, let code = ClipboardHandoffCode.code(from: url) else {
            logger.info("pasted value is not a clipboard handoff URL — ignored")
            store.storeClipboardDismissed(changeCount: changeCountAtPaste)
            await _recheckClipboardHandoff()
            return .notMatched(reason: "not_handoff_url")
        }

        guard Configuration.shared != nil else {
            logger.error("clipboard handoff pasted before Helm.configure(...) — not sent")
            return .failed
        }

        await _replayPendingSubmissions()

        // TAS-801: snapshot the marker once so the request body and any queued
        // entry that follows a transport failure agree on the environment.
        let debug = currentDebug()

        // Events recorded while the redeem is in flight wait for its answer,
        // so they carry the clipboard attribution ID when there is one.
        beginResolution()

        let result: ClipboardHandoffResult
        do {
            let response = try await HelmHTTPClient.post(
                path: APIPath.attributionClipboard,
                body: clipboardBody(code: code, debug: debug)
            )
            result = applyClipboardResponse(response, changeCountAtPaste: changeCountAtPaste)
        } catch {
            switch AttributionErrorMapper.classify(error) {
            case .transport:
                pendingStore.enqueue(PendingSubmission(kind: .clipboardHandoff,
                                                       userId: "",
                                                       value: code,
                                                       enqueuedAt: Date(),
                                                       debug: debug))
                logger.info("clipboard handoff queued for replay — transport failure")
            case .terminal(let mapped):
                logger.error("clipboard handoff rejected: \(mapped.localizedDescription, privacy: .public)")
            }
            result = .failed
        }

        // Every outcome is final for the events queued meanwhile: they are
        // sent with whatever attribution ID is now stored.
        await endResolution(resolved: true)
        await _recheckClipboardHandoff()
        return result
    }

    /// Apply a `200` response from the clipboard redeem endpoint.
    ///
    /// - Parameter changeCountAtPaste: the clipboard change count at the
    ///   paste, or `nil` for a replayed code, whose paste happened in an
    ///   earlier launch. The clipboard is never cleared for a replay, because
    ///   the change count may not mean the same thing after a restart.
    @discardableResult
    private func applyClipboardResponse(_ response: [String: Any],
                                        changeCountAtPaste: Int?) -> ClipboardHandoffResult {
        guard let matched = response["matched"] as? Bool else {
            logger.error("clipboard handoff response has no `matched` field")
            return .failed
        }

        guard matched else {
            let reason = response["reason"] as? String ?? "unknown"
            logger.info("clipboard handoff not matched — reason=\(reason, privacy: .public)")
            if let changeCountAtPaste {
                store.storeClipboardDismissed(changeCount: changeCountAtPaste)
            }
            return .notMatched(reason: reason)
        }

        guard let attributionId = response["attribution_id"] as? String, !attributionId.isEmpty else {
            logger.error("clipboard handoff matched without an attribution_id")
            return .failed
        }

        store.markClipboardRedeemed()

        // HELM-335: an installation can have both a clipboard and an Apple Ads
        // attribution. The server marks the one with the later touch as
        // primary, and only that one becomes the stored attribution ID. A
        // response without `primary` comes from a server that predates the
        // rule, and is treated as primary.
        let primary = response["primary"] as? Bool ?? true
        if primary {
            store.storeExactMatch(attributionId: attributionId, method: .clipboard)
            Analytics.shared.onAttributionMatched(attributionId)
            logger.info("clipboard handoff matched — attribution_id=\(attributionId, privacy: .private)")
        } else {
            logger.info("clipboard handoff matched but not primary — stored attribution kept")
        }

        if let changeCountAtPaste, pasteboard.changeCount == changeCountAtPaste {
            pasteboard.clear()
        }
        return .matched
    }

    private func clipboardBody(code: String, debug: Bool) -> [String: Any] {
        [
            "code": code,
            "device_id": installationId(),
            "debug": debug,
        ]
    }

    /// Start re-checking on foreground and on clipboard changes. Runs once,
    /// and only on an instance that watches the clipboard (the shared one).
    private func startClipboardWatchIfNeeded() {
        #if canImport(UIKit) && os(iOS)
        guard watchesClipboard else { return }
        clipboardLock.lock()
        if clipboardWatchStarted {
            clipboardLock.unlock()
            return
        }
        clipboardWatchStarted = true
        clipboardLock.unlock()

        let center = NotificationCenter.default
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.recheckClipboardHandoff()
        }
        let changed = center.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.recheckClipboardHandoff()
        }

        clipboardLock.lock()
        observerTokens.append(contentsOf: [foreground, changed])
        clipboardLock.unlock()
        #endif
    }

    /// Fire-and-forget re-check.
    private func recheckClipboardHandoff() {
        Task {
            await _recheckClipboardHandoff()
        }
    }

    /// Check the clipboard again and post
    /// `helmClipboardHandoffAvailabilityDidChange` if the answer changed.
    /// Does nothing until the app has called `hasClipboardHandoff()`, so the
    /// clipboard is never checked for apps that do not use the feature.
    internal func _recheckClipboardHandoff() async {
        guard clipboardHandoffInUse else { return }

        let available = await evaluateClipboardHandoff()
        recordClipboardAvailability(available, notify: true)
    }

    /// Whether the app has called `hasClipboardHandoff()`. Synchronous so the
    /// lock never spans an `await` (Swift 6).
    private var clipboardHandoffInUse: Bool {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }
        return lastClipboardAvailability != nil
    }

    private func recordClipboardAvailability(_ available: Bool, notify: Bool) {
        clipboardLock.lock()
        let changed = lastClipboardAvailability != available
        lastClipboardAvailability = available
        clipboardLock.unlock()

        guard notify, changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .helmClipboardHandoffAvailabilityDidChange,
                                            object: self,
                                            userInfo: ["available": available])
        }
    }

    // MARK: - Apple Ads (HELM-336)

    /// Start the Apple Ads check in the background. Called from
    /// `Helm.configure(...)` and when the app returns to the foreground. Does
    /// nothing when `appleAdsAttribution` is off or the check has finished.
    internal func startAppleAdsCheck() {
        guard Configuration.shared?.appleAdsAttribution == true,
              !store.appleAdsFinished else { return }
        // Off the main thread: `AAAttribution.attributionToken()` can block.
        Task.detached(priority: .utility) { [self] in
            await _checkAppleAdsAttribution()
        }
    }

    /// Check once per installation whether the install came from Apple Ads.
    ///
    /// - Gets a new AdServices token. If AdServices throws, stops for this
    ///   launch and tries again on the next one. If AdServices is not
    ///   available, the check is finished.
    /// - Sends `POST attribution/apple-ads/` with `token`, `device_id` and
    ///   `debug`.
    /// - `matched: true` finishes the check. When the response says the
    ///   attribution is `primary`, its ID replaces the stored attribution ID
    ///   and is passed to analytics.
    /// - `not_apple_ads`, `invalid_token` or any other final reason finishes
    ///   the check and stores nothing.
    /// - `pending`, a failed request or an unusable response counts as one
    ///   attempt. The next launch or return to the foreground tries again
    ///   with a new token, up to `AttributionStore.maxAppleAdsAttempts`
    ///   attempts within 24 hours of the first try. Then the check is
    ///   finished.
    internal func _checkAppleAdsAttribution() async {
        guard Configuration.shared?.appleAdsAttribution == true else { return }
        guard !store.appleAdsFinished else { return }
        guard beginAppleAdsCheck() else { return }
        defer { endAppleAdsCheck() }

        let now = Date()
        store.stampAppleAdsFirstAttemptIfNeeded(now)
        if store.appleAdsRetriesExhausted(now: now) {
            logger.info("Apple Ads check finished — retries used up")
            store.markAppleAdsFinished()
            return
        }

        let token: String?
        do {
            token = try appleAdsTokenProvider.attributionToken()
        } catch {
            logger.info("Apple Ads token unavailable — trying again next launch: \(error.localizedDescription, privacy: .public)")
            stopAppleAdsForThisLaunch()
            return
        }
        guard let token, !token.isEmpty else {
            logger.info("Apple Ads check finished — AdServices is not available")
            store.markAppleAdsFinished()
            return
        }

        do {
            let response = try await HelmHTTPClient.post(
                path: APIPath.attributionAppleAds,
                body: appleAdsBody(token: token, debug: currentDebug())
            )
            applyAppleAdsResponse(response)
        } catch {
            logger.error("Apple Ads request failed: \(error.localizedDescription, privacy: .public)")
            recordAppleAdsRetry()
        }
    }

    private func applyAppleAdsResponse(_ response: [String: Any]) {
        guard let matched = response["matched"] as? Bool else {
            logger.error("Apple Ads response has no `matched` field")
            recordAppleAdsRetry()
            return
        }

        if matched {
            guard let attributionId = response["attribution_id"] as? String, !attributionId.isEmpty else {
                logger.error("Apple Ads matched without an attribution_id")
                recordAppleAdsRetry()
                return
            }
            // HELM-335: when the installation also has a clipboard
            // attribution, the later touch is primary. Only the primary one
            // becomes the stored attribution ID. A response without `primary`
            // is treated as primary.
            if response["primary"] as? Bool ?? true {
                store.storeExactMatch(attributionId: attributionId, method: .appleAds)
                Analytics.shared.onAttributionMatched(attributionId)
                logger.info("Apple Ads matched — attribution_id=\(attributionId, privacy: .private)")
            } else {
                logger.info("Apple Ads matched but not primary — stored attribution kept")
            }
            store.markAppleAdsFinished()
            return
        }

        let reason = response["reason"] as? String ?? ""
        if reason == "pending" {
            logger.info("Apple Ads record not ready — trying again later")
            recordAppleAdsRetry()
        } else {
            logger.info("Apple Ads check finished — reason=\(reason, privacy: .public)")
            store.markAppleAdsFinished()
        }
    }

    /// Count an attempt without a final answer, and finish the check once the
    /// attempts or the 24-hour window are used up.
    private func recordAppleAdsRetry() {
        store.recordAppleAdsAttempt()
        if store.appleAdsRetriesExhausted() {
            logger.info("Apple Ads check finished — retries used up")
            store.markAppleAdsFinished()
        }
    }

    private func appleAdsBody(token: String, debug: Bool) -> [String: Any] {
        [
            "token": token,
            "device_id": installationId(),
            "debug": debug,
        ]
    }

    /// Claim the Apple Ads slot. Synchronous so the lock never spans an
    /// `await` (Swift 6).
    private func beginAppleAdsCheck() -> Bool {
        appleAdsLock.lock()
        defer { appleAdsLock.unlock() }
        if appleAdsInFlight || appleAdsStoppedForThisLaunch { return false }
        appleAdsInFlight = true
        return true
    }

    private func endAppleAdsCheck() {
        appleAdsLock.lock()
        defer { appleAdsLock.unlock() }
        appleAdsInFlight = false
    }

    private func stopAppleAdsForThisLaunch() {
        appleAdsLock.lock()
        defer { appleAdsLock.unlock() }
        appleAdsStoppedForThisLaunch = true
    }

    // MARK: - Influencer promo codes (HELM-220)

    /// Submit an influencer promo code for the given user.
    ///
    /// - Parameters:
    ///   - userId: Your app's identifier for the signed-in user. Helm treats it
    ///     as an opaque string and passes it through verbatim — it is never
    ///     validated, normalized, or hashed. **It MUST be exactly the same
    ///     string your app sets as the RevenueCat app user ID** (the value you
    ///     pass to `Purchases.logIn(_:)` / `Purchases.configure(appUserID:)`).
    ///     Helm's revenue matching joins on that equality; if the two drift,
    ///     purchases will not attribute to the influencer.
    ///   - code: The promo code the user entered, sent verbatim. The backend
    ///     normalizes case.
    /// - Returns: `.linked` when the backend linked the code, or `.queued` when
    ///   the network was unreachable and the submission was persisted for
    ///   automatic replay. Discarding the result loses the `.queued` signal, so
    ///   prefer to inspect it when you show UI.
    /// - Throws: `HelmAttributionError` — `.invalidCode`, `.codeInactive`,
    ///   `.alreadyLinked`, `.notConfigured`, `.server`, or `.invalidResponse`.
    ///   Validation verdicts are terminal and are never queued.
    @discardableResult
    public func submitPromoCode(userId: String, code: String) async throws -> PromoCodeResult {
        guard Configuration.shared != nil else {
            logger.error("submitPromoCode() before Helm.configure(...) — throwing notConfigured")
            throw HelmAttributionError.notConfigured
        }

        // Land anything already queued first, so a pending code is linked
        // before this call's own verdict is computed.
        await _replayPendingSubmissions()

        // TAS-801: snapshot the marker once so the request body and any queued
        // entry that follows a transport failure agree on the environment.
        let debug = currentDebug()

        do {
            let response = try await HelmHTTPClient.post(
                path: APIPath.attributionPromoCode,
                body: promoCodeBody(userId: userId, code: code, debug: debug)
            )
            return try promoCodeResult(from: response, userId: userId, submittedCode: code, debug: debug)
        } catch let error as HelmAttributionError {
            // Thrown by response parsing — already public-surface shaped.
            throw error
        } catch {
            switch AttributionErrorMapper.classify(error) {
            case .transport:
                pendingStore.enqueue(PendingSubmission(kind: .promoCode,
                                                       userId: userId,
                                                       value: code,
                                                       enqueuedAt: Date(),
                                                       debug: debug))
                logger.info("promo-code submission queued for replay — transport failure")
                return .queued
            case .terminal(let mapped):
                throw mapped
            }
        }
    }

    /// Fetch the user's influencer-attribution status so the paywall can choose
    /// the right offering.
    ///
    /// On a transport failure this returns the last status the backend confirmed
    /// for `userId` with `fromCache: true` rather than throwing, so an offline
    /// paywall still renders the influencer offering. It only throws
    /// `.network` when there is nothing cached for that user.
    ///
    /// - Parameter userId: The same opaque identifier described on
    ///   `submitPromoCode(userId:code:)` — it MUST equal your RevenueCat app
    ///   user ID.
    /// - Throws: `HelmAttributionError`. Backend 4xx verdicts are surfaced even
    ///   when a cached status exists.
    public func fetchAttributionStatus(userId: String) async throws -> AttributionStatus {
        guard Configuration.shared != nil else {
            logger.error("fetchAttributionStatus() before Helm.configure(...) — throwing notConfigured")
            throw HelmAttributionError.notConfigured
        }

        await _replayPendingSubmissions()

        let debug = currentDebug()

        do {
            let response = try await HelmHTTPClient.post(
                path: APIPath.attributionStatus,
                body: statusBody(userId: userId, debug: debug)
            )
            guard let isLinked = response["linked"] as? Bool else {
                throw HelmAttributionError.invalidResponse
            }
            let influencerCode = response["influencer_code"] as? String
            let offeringId = response["offering_id"] as? String
            statusCache.store(CachedStatus(isLinked: isLinked,
                                           influencerCode: influencerCode,
                                           offeringId: offeringId,
                                           fetchedAt: Date(),
                                           debug: debug),
                              for: userId)
            return AttributionStatus(isLinked: isLinked,
                                     influencerCode: influencerCode,
                                     offeringId: offeringId,
                                     fromCache: false)
        } catch let error as HelmAttributionError {
            throw error
        } catch {
            switch AttributionErrorMapper.classify(error) {
            case .transport:
                // TAS-801: a cached entry from the other environment is a miss.
                // Serving a sandbox-confirmed status to a live build (or the
                // reverse) would put the wrong offering in front of the user.
                if let cached = statusCache.status(for: userId), cached.debug == debug {
                    logger.info("attribution status served from cache — network unreachable")
                    return AttributionStatus(isLinked: cached.isLinked,
                                             influencerCode: cached.influencerCode,
                                             offeringId: cached.offeringId,
                                             fromCache: true)
                }
                throw HelmAttributionError.network
            case .terminal(let mapped):
                throw mapped
            }
        }
    }

    /// Report the StoreKit original transaction id for a purchase so Helm can
    /// attribute revenue to the influencer (fire-and-forget).
    ///
    /// Returns immediately and never throws — purchase UX must never block on
    /// Helm. Transport failures are queued and replayed automatically; backend
    /// validation failures are logged and dropped.
    ///
    /// - Parameters:
    ///   - userId: The same opaque identifier described on
    ///     `submitPromoCode(userId:code:)` — it MUST equal your RevenueCat app
    ///     user ID.
    ///   - originalTransactionId: `Transaction.originalID` (StoreKit 2) or the
    ///     `original_transaction_id` from the receipt, as a string.
    public func submitOriginalTransactionId(userId: String, originalTransactionId: String) {
        Task {
            await _submitOriginalTransactionId(userId: userId, originalTransactionId: originalTransactionId)
        }
    }

    /// Async variant of `submitOriginalTransactionId(userId:originalTransactionId:)`.
    /// Internal so tests can `await` one submission cycle; the public method
    /// keeps the fire-and-forget shape integrators rely on.
    internal func _submitOriginalTransactionId(userId: String, originalTransactionId: String) async {
        guard Configuration.shared != nil else {
            // A fire-and-forget method cannot throw, and misconfiguration is
            // not a transient failure, so this is dropped rather than queued.
            logger.error("submitOriginalTransactionId() before Helm.configure(...) — dropped")
            return
        }

        await _replayPendingSubmissions()

        let debug = currentDebug()

        do {
            _ = try await HelmHTTPClient.post(
                path: APIPath.attributionTransaction,
                body: transactionBody(userId: userId,
                                      originalTransactionId: originalTransactionId,
                                      debug: debug)
            )
        } catch {
            switch AttributionErrorMapper.classify(error) {
            case .transport:
                pendingStore.enqueue(PendingSubmission(kind: .transaction,
                                                       userId: userId,
                                                       value: originalTransactionId,
                                                       enqueuedAt: Date(),
                                                       debug: debug))
                logger.info("transaction submission queued for replay — transport failure")
            case .terminal(let mapped):
                logger.error("transaction submission rejected — dropped: \(mapped.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Offline replay (HELM-220)

    /// Fire-and-forget replay trigger. Called from `Helm.configure(...)` and on
    /// `willEnterForeground`; a no-op when the queue is empty.
    internal func replayPendingSubmissions() {
        Task {
            await _replayPendingSubmissions()
        }
    }

    /// Drain the pending-submission queue in FIFO order.
    ///
    /// Stops at the first transport failure — the network is still down, so
    /// hammering the remaining entries would only burn battery. Terminal
    /// verdicts remove the entry (a deferred `invalid_code` cannot be surfaced
    /// to a caller that has long since returned; per HELM-218 the deferred-failure
    /// UX is the host app's concern).
    ///
    /// Concurrency: if a replay is already running, this returns immediately.
    /// A queued entry may therefore post *after* a concurrent fresh call's
    /// request; all three endpoints are idempotent, so ordering is not
    /// load-bearing.
    internal func _replayPendingSubmissions() async {
        guard Configuration.shared != nil else { return }
        guard beginReplay() else { return }
        var replayedClipboardHandoff = false
        defer {
            endReplay()
            if replayedClipboardHandoff {
                // The queued code no longer blocks `hasClipboardHandoff()`.
                recheckClipboardHandoff()
            }
        }

        // `all()` has already pruned entries past the 30-day retention window,
        // so expired submissions never reach the network.
        replayLoop: for entry in pendingStore.all() {
            let path: String
            let body: [String: Any]
            switch entry.kind {
            case .promoCode:
                path = APIPath.attributionPromoCode
                // TAS-801: `entry.debug`, never `currentDebug()` — the queued
                // submission keeps the environment it was created in.
                body = promoCodeBody(userId: entry.userId, code: entry.value, debug: entry.debug)
            case .transaction:
                path = APIPath.attributionTransaction
                body = transactionBody(userId: entry.userId,
                                       originalTransactionId: entry.value,
                                       debug: entry.debug)
            case .clipboardHandoff:
                path = APIPath.attributionClipboard
                body = clipboardBody(code: entry.value, debug: entry.debug)
            }

            do {
                let response = try await HelmHTTPClient.post(path: path, body: body)
                pendingStore.remove(id: entry.id)
                if entry.kind == .promoCode {
                    // The replayed code is now linked — record it so an offline
                    // paywall read picks up the right offering.
                    let influencerCode = response["influencer_code"] as? String ?? entry.value
                    statusCache.store(CachedStatus(isLinked: true,
                                                   influencerCode: influencerCode,
                                                   offeringId: response["offering_id"] as? String,
                                                   fetchedAt: Date(),
                                                   debug: entry.debug),
                                      for: entry.userId)
                }
                if entry.kind == .clipboardHandoff {
                    // HELM-325: same handling as a fresh redeem, except that
                    // the clipboard is not cleared (see the method).
                    applyClipboardResponse(response, changeCountAtPaste: nil)
                    replayedClipboardHandoff = true
                }
                logger.info("replayed queued \(entry.kind.rawValue, privacy: .public) submission")
            } catch {
                switch AttributionErrorMapper.classify(error) {
                case .transport:
                    logger.info("replay halted — network still unavailable; \(entry.kind.rawValue, privacy: .public) submission stays queued")
                    break replayLoop
                case .terminal(let mapped):
                    pendingStore.remove(id: entry.id)
                    logger.error("queued \(entry.kind.rawValue, privacy: .public) submission rejected on replay — dropped: \(mapped.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Try to claim the replay slot. Synchronous so the lock never spans an
    /// `await` (Swift 6).
    private func beginReplay() -> Bool {
        replayLock.lock()
        defer { replayLock.unlock() }
        if replayInFlight { return false }
        replayInFlight = true
        return true
    }

    private func endReplay() {
        replayLock.lock()
        defer { replayLock.unlock() }
        replayInFlight = false
    }

    // MARK: - Request bodies (HELM-220)

    /// `platform` and `device_id` are auto-included on all three attribution
    /// submission endpoints so the backend can reconcile a submission with the
    /// install that made it.
    ///
    /// TAS-801: `debug` is included on all three bodies, always, as a real
    /// boolean — the backend reads `data.get('debug') is True`, so a string or a
    /// number would silently register as live. Fresh calls pass
    /// `currentDebug()`; a replay passes the marker the entry was enqueued with.
    private func promoCodeBody(userId: String, code: String, debug: Bool) -> [String: Any] {
        [
            "user_id": userId,
            "code": code,
            "platform": AnalyticsClient.platformName(),
            "device_id": installationId(),
            "debug": debug,
        ]
    }

    private func statusBody(userId: String, debug: Bool) -> [String: Any] {
        [
            "user_id": userId,
            "platform": AnalyticsClient.platformName(),
            "device_id": installationId(),
            "debug": debug,
        ]
    }

    private func transactionBody(userId: String, originalTransactionId: String, debug: Bool) -> [String: Any] {
        [
            "user_id": userId,
            "original_transaction_id": originalTransactionId,
            "platform": AnalyticsClient.platformName(),
            "device_id": installationId(),
            "debug": debug,
        ]
    }

    /// TAS-801: the sandbox marker of the *current* configuration. Read at call
    /// time (never cached) and `false` whenever the SDK is unconfigured, so the
    /// production-safe default holds on every path.
    private func currentDebug() -> Bool {
        Configuration.shared?.debug ?? false
    }

    private func promoCodeResult(from response: [String: Any],
                                 userId: String,
                                 submittedCode: String,
                                 debug: Bool) throws -> PromoCodeResult {
        guard let linked = response["linked"] as? Bool, linked else {
            throw HelmAttributionError.invalidResponse
        }
        let influencerCode = response["influencer_code"] as? String ?? submittedCode
        let offeringId = response["offering_id"] as? String
        statusCache.store(CachedStatus(isLinked: true,
                                       influencerCode: influencerCode,
                                       offeringId: offeringId,
                                       fetchedAt: Date(),
                                       debug: debug),
                          for: userId)
        return .linked(influencerCode: influencerCode, offeringId: offeringId)
    }

    // MARK: - Test Hooks

    /// Internal accessor for tests that need to observe the in-flight flag.
    internal var testHook_isMatchInFlight: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return resolutionsInFlight > 0
    }

    /// Internal accessor for tests that need to observe queue depth.
    internal var testHook_pendingEventCount: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return pendingEvents.count
    }

    /// Internal accessor for tests that need to observe the HELM-220 offline
    /// submission queue depth.
    internal var testHook_pendingSubmissionCount: Int {
        pendingStore.count
    }

    // MARK: - Reset

    /// Reset all SDK attribution state so the next `match()` runs as if this
    /// were a fresh install: a new `device_id` is generated, `hasChecked`
    /// flips back to false, the stored `attribution_id` is cleared, the
    /// retry budget is cleared, and any pending events queued by HELM-187
    /// are dropped.
    ///
    /// HELM-220: also drops the offline promo-code / transaction submission
    /// queue and the per-user attribution status cache, so no identifier
    /// supplied by the previous user survives on-device.
    ///
    /// HELM-325 / HELM-336: also clears the clipboard handoff state and the
    /// Apple Ads check state, so the Apple Ads check runs again on the next
    /// launch.
    ///
    /// Call this when the host app logs the user out and a different user
    /// logs in on the same device, or when an account-deletion flow needs
    /// to remove SDK-stored identifiers (App Review Guideline 5.1.1(v)).
    public func reset() {
        // Drop any queued events and clear the match-in-flight flag so a
        // post-reset `match()` starts cleanly.
        queueLock.lock()
        pendingEvents.removeAll()
        resolutionsInFlight = 0
        flushWhenIdle = false
        queueLock.unlock()

        store.clearAll()
        pendingStore.clearAll()
        statusCache.clearAll()
    }

}
