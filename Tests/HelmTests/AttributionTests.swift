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

    // MARK: - HELM-189: reset returns SDK to first-launch state

    /// A simulated match, then reset, then another simulated match — the
    /// second match must produce a NEW device_id.
    func test_reset_regenerates_device_id() async {
        // First match: capture the device_id from the request body.
        var firstDeviceId: String?
        configureSDK { request in
            if let body = self.bodyFromRequest(request),
               let id = body["device_id"] as? String {
                firstDeviceId = id
            }
            return Self.successResponse(matched: true)
        }
        await attribution._match()

        XCTAssertNotNil(firstDeviceId, "First match must include a device_id")
        XCTAssertTrue(store.hasChecked)

        // Reset.
        attribution.reset()

        XCTAssertFalse(store.hasChecked, "reset() must clear hasChecked")
        XCTAssertNil(store.attributionId, "reset() must clear attributionId")

        // Second match: capture the NEW device_id.
        var secondDeviceId: String?
        AttributionMockURLProtocol.reset()
        configureSDK { request in
            if let body = self.bodyFromRequest(request),
               let id = body["device_id"] as? String {
                secondDeviceId = id
            }
            return Self.successResponse(matched: true)
        }
        await attribution._match()

        XCTAssertNotNil(secondDeviceId)
        XCTAssertNotEqual(firstDeviceId, secondDeviceId,
                          "After reset(), a new device_id must be generated")
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
