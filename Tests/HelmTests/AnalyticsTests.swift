import XCTest
@testable import Helm

final class AnalyticsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "dev.helmcode.helm.tests.analytics.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        Configuration.shared = Configuration(publishableKey: "pk_test", baseURL: "https://example.invalid")
        AnalyticsMockURLProtocol.reset()
    }

    override func tearDown() {
        Configuration.shared = nil
        AnalyticsMockURLProtocol.reset()
        // Clear any token set on the shared singleton by attribution-handshake tests.
        Analytics.shared.testHook_clearAttributionToken()
        super.tearDown()
    }

    private func makeAnalytics(attributionStore: AttributionStore? = nil) -> Analytics {
        Analytics(installationStore: InstallationStore(defaults: defaults, useKeychain: false),
                  identityStore: IdentityStore(defaults: defaults),
                  sessionManager: SessionManager(),
                  queue: EventQueue(),
                  attributionStore: attributionStore ?? AttributionStore(defaults: defaults))
    }

    // MARK: - Helpers

    private func configureWithMockSession(debug: Bool = false, environment: String = "production") {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalyticsMockURLProtocol.self]
        let session = URLSession(configuration: config)
        AnalyticsMockURLProtocol.responder = { request in
            let body = try! JSONSerialization.data(withJSONObject: ["ok": true])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        Helm.configure(publishableKey: "pk_test",
                       baseURL: "https://example.invalid",
                       debug: debug,
                       environment: environment,
                       session: session)
    }

    private func bodyFromRequest(_ request: URLRequest) -> [String: Any]? {
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

    func testHeadersWhenAnonymous() {
        let analytics = makeAnalytics()
        let headers = analytics.headers
        XCTAssertNotNil(UUID(uuidString: headers["X-Helm-Installation-Id"] ?? ""))
        XCTAssertNotNil(UUID(uuidString: headers["X-Helm-Session-Id"] ?? ""))
        XCTAssertEqual(headers["X-Helm-Platform"], AnalyticsClient.platformName())
        XCTAssertEqual(headers["X-Helm-App-Version"], AnalyticsClient.appVersion())
        XCTAssertNil(headers["X-Helm-User-Hash"], "no identity header when anonymous")
    }

    func testHeadersAfterIdentify() {
        let analytics = makeAnalytics()
        analytics.identify(userHash: String(repeating: "b", count: 32))
        XCTAssertEqual(analytics.headers["X-Helm-User-Hash"], String(repeating: "b", count: 32))
        analytics.clearIdentity()
        XCTAssertNil(analytics.headers["X-Helm-User-Hash"])
    }

    func testTrackBeforeStartIsSafeNoop() {
        let analytics = makeAnalytics()
        analytics.track("ignored") // must not crash, must not queue
        XCTAssertEqual(analytics.queuedEventCount, 0)
    }

    func testTrackAfterStartQueues() {
        let analytics = makeAnalytics()
        analytics.start()
        analytics.track("tapped", properties: ["screen": "home"])
        XCTAssertEqual(analytics.queuedEventCount, 1)
    }

    func testStartTwiceIsIdempotent() {
        let analytics = makeAnalytics()
        analytics.start()
        analytics.start() // must not crash, must not double-queue
        analytics.track("once")
        XCTAssertEqual(analytics.queuedEventCount, 1)
    }

    func testHelmFacadeExposesAnalytics() {
        XCTAssertTrue(Helm.analytics === Analytics.shared)
    }

    // MARK: - HELM-241: debug and environment on registration and events

    /// A build configured with `debug: true, environment: "staging"` must send
    /// both on registration.
    func testRegistrationCarriesConfiguredDebugAndEnvironment() async throws {
        configureWithMockSession(debug: true, environment: "staging")
        let analytics = makeAnalytics()
        analytics.start()

        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !AnalyticsMockURLProtocol.receivedRequests.isEmpty { break }
        }

        let body = bodyFromRequest(try XCTUnwrap(AnalyticsMockURLProtocol.receivedRequests.first))
        XCTAssertEqual(body?["debug"] as? Bool, true)
        XCTAssertEqual(body?["environment"] as? String, "staging")
    }

    /// An event queued before a reconfiguration keeps the values in force when
    /// it was created, not the ones in force at flush time.
    func testQueuedEventKeepsTheValuesItWasCreatedWith() async throws {
        configureWithMockSession(debug: true, environment: "staging")
        let analytics = makeAnalytics()
        analytics.start()
        analytics.track("tapped")

        // Reconfigure to a live production build before the batch is flushed.
        configureWithMockSession(debug: false, environment: "production")

        analytics.flush()

        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if AnalyticsMockURLProtocol.receivedRequests.contains(where: {
                $0.url?.absoluteString.contains(APIPath.analyticsEvents) == true
            }) { break }
        }

        let eventsRequest = try XCTUnwrap(
            AnalyticsMockURLProtocol.receivedRequests.last(where: { $0.url?.absoluteString.contains(APIPath.analyticsEvents) == true }),
            "the flush must have posted an events batch"
        )
        let body = bodyFromRequest(eventsRequest)
        let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["debug"] as? Bool, true,
                       "the event was tracked by a debug build and must stay debug")
        XCTAssertEqual(events[0]["environment"] as? String, "staging",
                       "the event was tracked on staging and must stay staging")
    }

    // MARK: - HELM-203 #1b: attribution_token handshake

    /// `onAttributionMatched` while analytics is started must trigger a
    /// re-registration whose captured request body carries `attribution_token`.
    func testOnAttributionMatchedWhileStartedTriggersReRegistrationWithToken() async throws {
        configureWithMockSession()
        let analytics = makeAnalytics()

        // Start: fires the initial registration (we don't care about its body here).
        analytics.start()

        // Wait for the initial registration request to arrive.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
            if !AnalyticsMockURLProtocol.receivedRequests.isEmpty { break }
        }
        let countAfterStart = AnalyticsMockURLProtocol.receivedRequests.count
        XCTAssertGreaterThan(countAfterStart, 0, "start() must trigger a registration")

        // Trigger the handshake.
        analytics.onAttributionMatched("attr-token-xyz")

        // Wait for the re-registration.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if AnalyticsMockURLProtocol.receivedRequests.count > countAfterStart { break }
        }

        XCTAssertGreaterThan(AnalyticsMockURLProtocol.receivedRequests.count, countAfterStart,
                             "onAttributionMatched must fire a re-registration")

        let lastRequest = AnalyticsMockURLProtocol.receivedRequests.last!
        let body = bodyFromRequest(lastRequest)
        XCTAssertEqual(body?["attribution_token"] as? String, "attr-token-xyz",
                       "Re-registration body must include attribution_token")
    }

    /// `start()` must seed `attributionToken` from a pre-stored `AttributionStore` entry
    /// so the very first registration carries the token even when `match()` ran before
    /// `start()`.
    func testStartSeedsPreStoredAttributionToken() async throws {
        let attributionStore = AttributionStore(defaults: defaults)
        attributionStore.storeMatch(attributionId: "pre-match-token")

        configureWithMockSession()
        let analytics = makeAnalytics(attributionStore: attributionStore)

        // start() seeds from the attribution store and registers.
        analytics.start()

        // Wait for the registration request.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !AnalyticsMockURLProtocol.receivedRequests.isEmpty { break }
        }

        XCTAssertFalse(AnalyticsMockURLProtocol.receivedRequests.isEmpty,
                       "start() must fire a registration")
        let request = AnalyticsMockURLProtocol.receivedRequests.first!
        let body = bodyFromRequest(request)
        XCTAssertEqual(body?["attribution_token"] as? String, "pre-match-token",
                       "start() must seed attribution_token from the AttributionStore")
    }
}

// MARK: - AnalyticsMockURLProtocol

/// Test-only URLProtocol for `AnalyticsTests` that captures registration requests
/// and returns canned 200 responses. Kept separate from `AttributionMockURLProtocol`
/// because they serve distinct test classes with different concurrency needs.
private final class AnalyticsMockURLProtocol: URLProtocol {

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
