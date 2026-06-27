import XCTest
@testable import Helm

/// Integration-style tests that exercise `Attribution._match()` against a
/// mock `URLSession` so we can verify retry-budget behavior (HELM-184),
/// event queueing across the match boundary (HELM-187), and reset (HELM-189)
/// end-to-end.
final class AttributionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: AttributionStore!
    private var attribution: Attribution!

    override func setUp() {
        super.setUp()
        let suiteName = "dev.helmcode.helm.tests.attribution.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AttributionStore(defaults: defaults)
        attribution = Attribution(store: store)

        Configuration.shared = nil
        AttributionMockURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        store = nil
        attribution = nil
        Configuration.shared = nil
        AttributionMockURLProtocol.reset()
        // Clear any token written on Analytics.shared by the handshake tests.
        Analytics.shared.testHook_clearAttributionToken()
        super.tearDown()
    }

    // MARK: - Helpers

    private func configureSDK(responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AttributionMockURLProtocol.self]
        let session = URLSession(configuration: config)
        AttributionMockURLProtocol.responder = responder
        Helm.configure(
            publishableKey: "test-key",
            baseURL: "https://example.invalid",
            session: session
        )
    }

    private static func successResponse(matched: Bool, attributionId: String = "attr-123") -> (HTTPURLResponse, Data) {
        let json: [String: Any] = matched
            ? ["matched": true, "attribution_id": attributionId]
            : ["matched": false]
        let body = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.invalid/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    private static func failureResponse() -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.invalid/")!,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data())
    }

    // MARK: - HELM-184: bounded retry budget

    /// Five consecutive failures must mark the store as checked so subsequent
    /// launches stop hitting the backend.
    func test_all_failures_eventually_mark_checked() async {
        configureSDK { _ in Self.failureResponse() }

        for _ in 0 ..< AttributionStore.maxAttempts {
            await attribution._match()
        }

        XCTAssertEqual(store.attemptCount, AttributionStore.maxAttempts)
        XCTAssertFalse(store.canRetry)
        XCTAssertTrue(store.hasChecked, "After exhausting the retry budget, hasChecked must be true")
    }

    /// A failure followed by a success must reset the attempt counter and
    /// flip `hasChecked` to true via the normal success path.
    func test_failure_then_success_resets_counter() async {
        // First attempt: failure.
        configureSDK { _ in Self.failureResponse() }
        await attribution._match()
        XCTAssertEqual(store.attemptCount, 1)
        XCTAssertFalse(store.hasChecked)

        // Second attempt: success.
        configureSDK { _ in Self.successResponse(matched: true) }
        await attribution._match()

        XCTAssertEqual(store.attemptCount, 0, "Successful match must reset the retry counter")
        XCTAssertTrue(store.canRetry)
        XCTAssertTrue(store.hasChecked)
        XCTAssertEqual(store.attributionId, "attr-123")
    }

    // MARK: - HELM-187: events queue until match resolves

    /// Fire `increment(...)` calls while a match is in flight; they should
    /// all post with the resolved `attribution_id` once the match returns.
    func test_increment_calls_during_match_are_queued_and_flushed() async throws {
        let matchedId = "attr-queued-flush"

        // Gate the match responder so the test can keep the match in flight
        // while it fires 5 increments. Releasing the semaphore lets the
        // match complete.
        let matchGate = DispatchSemaphore(value: 0)

        configureSDK { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains("/attribution/match") {
                // Block here until the test releases the gate. This runs on
                // a URLProtocol worker thread, not the test's Task.
                matchGate.wait()
                return Self.successResponse(matched: true, attributionId: matchedId)
            } else {
                let body = try! JSONSerialization.data(withJSONObject: ["ok": true])
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, body)
            }
        }

        // Set matchInFlight directly via test hook, then fire 5 events (they
        // queue), then call _match which will: see existing matchInFlight,
        // run its work, complete, flush the queue. Wait -- _match() sets
        // matchInFlight itself. To exercise the real code path, kick off
        // _match() and use the gate so it remains in flight while we fire
        // increments.
        let attribution = self.attribution!
        let matchTask = Task.detached(priority: .userInitiated) {
            await attribution._match()
        }

        // Yield so the detached task gets a chance to run before we poll.
        await Task.yield()

        // Wait until matchInFlight is observably true. Poll up to 2s.
        var inFlight = false
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            if attribution.testHook_isMatchInFlight {
                inFlight = true
                break
            }
        }
        XCTAssertTrue(inFlight, "Match should set matchInFlight=true within 2s of starting")

        // Fire 5 events while the match is still gated. They should queue.
        for i in 0 ..< 5 {
            attribution.increment("evt_\(i)")
        }

        // Sanity: queue should hold 5 entries before the match releases.
        XCTAssertEqual(attribution.testHook_pendingEventCount, 5,
                       "All 5 events should be queued while match is in flight")

        // Release the match.
        matchGate.signal()
        await matchTask.value

        // Drain time: each queued event is posted sequentially via the
        // mock URLSession. Poll up to 2s for them to arrive.
        var eventRequests: [URLRequest] = []
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            eventRequests = AttributionMockURLProtocol.receivedRequests.filter {
                ($0.url?.absoluteString ?? "").contains("/attribution/event")
            }
            if eventRequests.count >= 5 { break }
        }

        XCTAssertEqual(eventRequests.count, 5,
                       "All 5 queued events must be posted after the match resolves")

        // Each event must carry the resolved attribution_id, not null.
        for req in eventRequests {
            let body = bodyFromRequest(req) ?? [:]
            XCTAssertEqual(body["attribution_id"] as? String, matchedId,
                           "Queued event must post with the resolved attribution_id")
        }
    }

    // MARK: - HELM-189 / HELM-203: reset returns SDK to first-launch state

    /// After reset(), attribution flags and `attribution_id` are cleared, but
    /// the `device_id` (now the Keychain installation id) is STABLE — it must
    /// be the same value in both match calls.
    func test_reset_device_id_is_stable() async {
        let fixedInstallId = "stable-install-id-helm203"
        let localAttribution = Attribution(store: store, installationId: { fixedInstallId })

        // First match: capture the device_id from the request body.
        var firstDeviceId: String?
        configureSDK { request in
            if let body = self.bodyFromRequest(request),
               let id = body["device_id"] as? String {
                firstDeviceId = id
            }
            return Self.successResponse(matched: true)
        }
        await localAttribution._match()

        XCTAssertEqual(firstDeviceId, fixedInstallId, "First match must send the injected installation id")
        XCTAssertTrue(store.hasChecked)

        // Reset: must clear attribution flags but must NOT rotate device identity.
        localAttribution.reset()

        XCTAssertFalse(store.hasChecked, "reset() must clear hasChecked")
        XCTAssertNil(store.attributionId, "reset() must clear attributionId")

        // Second match: device_id must be identical — identity lives in Keychain.
        var secondDeviceId: String?
        AttributionMockURLProtocol.reset()
        configureSDK { request in
            if let body = self.bodyFromRequest(request),
               let id = body["device_id"] as? String {
                secondDeviceId = id
            }
            return Self.successResponse(matched: true)
        }
        await localAttribution._match()

        XCTAssertNotNil(secondDeviceId)
        XCTAssertEqual(firstDeviceId, secondDeviceId,
                       "device_id must be stable across reset() — identity lives in the Keychain, not attribution state")
    }

    /// `match()` must send the injected installation id as `device_id` in the
    /// request body, confirming attribution and analytics share one identity.
    func test_match_sends_installation_id_as_device_id() async {
        let expectedId = "injected-install-id-xyz-helm203"
        let localAttribution = Attribution(store: store, installationId: { expectedId })

        var capturedDeviceId: String?
        configureSDK { request in
            if let body = self.bodyFromRequest(request),
               let id = body["device_id"] as? String {
                capturedDeviceId = id
            }
            return Self.successResponse(matched: false)
        }

        await localAttribution._match()

        XCTAssertEqual(capturedDeviceId, expectedId,
                       "match() must send the Keychain installation id as device_id")
    }

    // MARK: - HELM-203 #1b: attribution_token handshake

    /// A successful `_match()` must forward the resolved `attribution_id` to
    /// `Analytics.shared` via `onAttributionMatched`. Verified by reading the
    /// test hook on the shared singleton (Analytics is not started here so the
    /// re-registration branch is not triggered — that path is covered in
    /// `AnalyticsTests.testOnAttributionMatchedWhileStartedTriggersReRegistrationWithToken`).
    func test_match_success_forwards_attribution_id_to_analytics() async {
        let expectedId = "attr-forwarded-helm203"

        configureSDK { _ in Self.successResponse(matched: true, attributionId: expectedId) }

        await attribution._match()

        XCTAssertEqual(Analytics.shared.testHook_attributionToken, expectedId,
                       "Successful _match() must forward attribution_id to Analytics.shared via onAttributionMatched")
    }

    // MARK: - HELM-203 #2: incrementAuthenticated

    /// `incrementAuthenticated` must post to the attribution event endpoint
    /// with `user_hash` present in the request body.
    func test_incrementAuthenticated_sends_user_hash_in_body() async throws {
        let expectedHash = "test-user-hash-helm203"
        let localAttribution = Attribution(store: store, userHash: { expectedHash })

        configureSDK { request in
            let body = try! JSONSerialization.data(withJSONObject: ["ok": true])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        localAttribution.incrementAuthenticated("trial_start")

        // Poll up to 2 s for the event request to arrive.
        var eventRequests: [URLRequest] = []
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            eventRequests = AttributionMockURLProtocol.receivedRequests.filter {
                ($0.url?.absoluteString ?? "").contains("/attribution/event")
            }
            if !eventRequests.isEmpty { break }
        }

        XCTAssertEqual(eventRequests.count, 1, "incrementAuthenticated must post exactly one event")
        let body = bodyFromRequest(eventRequests[0]) ?? [:]
        XCTAssertEqual(body["user_hash"] as? String, expectedHash,
                       "incrementAuthenticated must include user_hash in the event body")
        XCTAssertEqual(body["event_type"] as? String, "trial_start")
    }

    /// Plain `increment` must NOT include `user_hash` in the event body, even
    /// when a user is identified.
    func test_increment_does_not_send_user_hash() async throws {
        // Provide a user hash via the closure — increment() must ignore it.
        let localAttribution = Attribution(store: store, userHash: { "should-not-appear" })

        configureSDK { request in
            let body = try! JSONSerialization.data(withJSONObject: ["ok": true])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        localAttribution.increment("page_view")

        var eventRequests: [URLRequest] = []
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            eventRequests = AttributionMockURLProtocol.receivedRequests.filter {
                ($0.url?.absoluteString ?? "").contains("/attribution/event")
            }
            if !eventRequests.isEmpty { break }
        }

        XCTAssertEqual(eventRequests.count, 1, "increment must post exactly one event")
        let body = bodyFromRequest(eventRequests[0]) ?? [:]
        XCTAssertNil(body["user_hash"],
                     "Plain increment must NOT include user_hash in the event body")
    }

    /// An `incrementAuthenticated` call queued while a match is in flight must
    /// flush after the match resolves with `user_hash` intact.
    func test_incrementAuthenticated_queued_during_match_flushes_with_user_hash() async throws {
        let expectedHash = "queued-user-hash-helm203"
        let matchedId = "attr-auth-queued"

        let matchGate = DispatchSemaphore(value: 0)

        configureSDK { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains("/attribution/match") {
                matchGate.wait()
                return Self.successResponse(matched: true, attributionId: matchedId)
            } else {
                let body = try! JSONSerialization.data(withJSONObject: ["ok": true])
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, body)
            }
        }

        let localAttribution = Attribution(store: store, userHash: { expectedHash })

        let matchTask = Task.detached(priority: .userInitiated) {
            await localAttribution._match()
        }

        await Task.yield()

        var inFlight = false
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if localAttribution.testHook_isMatchInFlight {
                inFlight = true
                break
            }
        }
        XCTAssertTrue(inFlight, "Match should set matchInFlight=true before we queue the auth event")

        // Queue one authenticated event while the match is gated.
        localAttribution.incrementAuthenticated("purchase")

        XCTAssertEqual(localAttribution.testHook_pendingEventCount, 1,
                       "Auth event must be queued while match is in flight")

        matchGate.signal()
        await matchTask.value

        // Wait for the flushed event to arrive.
        var eventRequests: [URLRequest] = []
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            eventRequests = AttributionMockURLProtocol.receivedRequests.filter {
                ($0.url?.absoluteString ?? "").contains("/attribution/event")
            }
            if !eventRequests.isEmpty { break }
        }

        XCTAssertEqual(eventRequests.count, 1, "Queued auth event must be flushed after match")
        let body = bodyFromRequest(eventRequests[0]) ?? [:]
        XCTAssertEqual(body["user_hash"] as? String, expectedHash,
                       "Flushed auth event must preserve user_hash captured at enqueue time")
        XCTAssertEqual(body["attribution_id"] as? String, matchedId,
                       "Flushed auth event must carry the resolved attribution_id")
    }

    // MARK: - HELM-195: isConfigured and re-config warning

    func test_is_configured_reflects_configuration_state() {
        Configuration.shared = nil
        XCTAssertFalse(Helm.isConfigured)

        Helm.configure(publishableKey: "k", baseURL: "https://example.invalid")
        XCTAssertTrue(Helm.isConfigured)

        Configuration.shared = nil
        XCTAssertFalse(Helm.isConfigured)
    }

    // MARK: - Helpers

    private func bodyFromRequest(_ request: URLRequest) -> [String: Any]? {
        // URLSession strips httpBody when handing the request to URLProtocol;
        // bodyStream survives.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if let body = request.httpBody {
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
        return nil
    }
}

// MARK: - AttributionMockURLProtocol

/// Test-only URLProtocol that captures requests and returns canned responses.
/// Kept separate from `HelmHTTPClientTests`' MockURLProtocol because the
/// `Attribution` tests need to inspect bodies and run multiple requests per
/// test.
private final class AttributionMockURLProtocol: URLProtocol {

    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        receivedRequests = []
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.receivedRequests.append(request)
        let responder = Self.responder
        Self.lock.unlock()

        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
