import XCTest
@testable import Helm

/// HELM-336: the Apple Ads check. Path parity, the request body, each
/// response, the retry limits, the `primary` rule, and the configure flag.
///
/// The AdServices token comes from a `FakeAppleAdsTokenProvider`, so these
/// tests never call the real framework. The configuration is set directly
/// rather than through `Helm.configure(...)`, so the shared instance never
/// starts its own check during these tests.
final class AppleAdsAttributionTests: XCTestCase {

    private static let installationId = "fixed-install-id"
    private static let baseURL = "https://example.invalid"

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: AttributionStore!
    private var tokens: FakeAppleAdsTokenProvider!
    private var waits: WaitRecorder!
    private var attribution: Attribution!

    override func setUp() {
        super.setUp()
        suiteName = "dev.helmcode.helm.tests.appleads.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AttributionStore(defaults: defaults)
        tokens = FakeAppleAdsTokenProvider()
        waits = WaitRecorder()
        attribution = makeAttribution()
        Configuration.shared = nil
        AppleAdsMockURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        tokens = nil
        waits = nil
        attribution = nil
        Configuration.shared = nil
        AppleAdsMockURLProtocol.reset()
        Analytics.shared.testHook_clearAttributionToken()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A new `Attribution` over the same stored state, standing in for the
    /// next app launch.
    private func makeAttribution() -> Attribution {
        Attribution(store: store,
                    pendingStore: PendingSubmissionStore(defaults: defaults),
                    statusCache: AttributionStatusCache(defaults: defaults),
                    installationId: { Self.installationId },
                    appleAdsTokenProvider: tokens,
                    appleAdsWait: { [waits] seconds in waits!.record(seconds) })
    }

    private func configure(appleAdsAttribution: Bool = true,
                           debug: Bool = false,
                           responder: @escaping (URLRequest) -> AppleAdsMockURLProtocol.Outcome) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppleAdsMockURLProtocol.self]
        AppleAdsMockURLProtocol.responder = responder
        Configuration.shared = Configuration(publishableKey: "test-key",
                                             baseURL: Self.baseURL,
                                             debug: debug,
                                             appleAdsAttribution: appleAdsAttribution,
                                             session: URLSession(configuration: config))
    }

    private static func json(_ object: [String: Any], status: Int = 200) -> AppleAdsMockURLProtocol.Outcome {
        let response = HTTPURLResponse(url: URL(string: baseURL)!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return .response(response, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func matched(_ id: String = "attr-ads", primary: Bool? = true) -> AppleAdsMockURLProtocol.Outcome {
        var body: [String: Any] = ["matched": true, "attribution_id": id]
        if let primary { body["primary"] = primary }
        return json(body)
    }

    private static func notMatched(_ reason: String) -> AppleAdsMockURLProtocol.Outcome {
        json(["matched": false, "reason": reason])
    }

    private var appleAdsRequests: [URLRequest] {
        AppleAdsMockURLProtocol.receivedRequests.filter {
            ($0.url?.absoluteString ?? "") == Self.baseURL + APIPath.attributionAppleAds
        }
    }

    private static func data(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func body(of request: URLRequest) -> [String: Any]? {
        guard let data = data(of: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Path and body

    func test_apple_ads_path_matches_the_backend_exactly() {
        XCTAssertEqual(APIPath.attributionAppleAds, "/api/client/v1/attribution/apple-ads/")
    }

    func test_body_carries_token_device_id_and_debug() async throws {
        configure(debug: true) { _ in Self.notMatched("not_apple_ads") }

        await attribution._checkAppleAdsAttribution()

        let request = try XCTUnwrap(appleAdsRequests.first)
        let body = try XCTUnwrap(Self.body(of: request))
        XCTAssertEqual(body["token"] as? String, "token-1")
        XCTAssertEqual(body["device_id"] as? String, Self.installationId)
        XCTAssertEqual(Set(body.keys), ["token", "device_id", "debug"])
        let raw = String(decoding: try XCTUnwrap(Self.data(of: request)), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"debug\":true"), "debug must be a JSON boolean: \(raw)")
    }

    // MARK: - Responses

    func test_primary_match_stores_the_attribution_and_finishes() async {
        configure { _ in Self.matched("attr-ads") }
        store.storeMatch(attributionId: "attr-fingerprint")

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertEqual(store.exactMethod, .appleAds)
        XCTAssertEqual(Analytics.shared.testHook_attributionToken, "attr-ads")
        XCTAssertTrue(store.appleAdsFinished)

        await attribution._checkAppleAdsAttribution()
        XCTAssertEqual(appleAdsRequests.count, 1, "A finished check never runs again")
    }

    func test_match_that_is_not_primary_keeps_the_stored_attribution() async {
        configure { _ in Self.matched("attr-ads", primary: false) }
        store.storeExactMatch(attributionId: "attr-clip", method: .clipboard)

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-clip")
        XCTAssertEqual(store.exactMethod, .clipboard)
        XCTAssertNil(Analytics.shared.testHook_attributionToken)
        XCTAssertTrue(store.appleAdsFinished)
    }

    func test_a_response_without_primary_is_treated_as_primary() async {
        configure { _ in Self.matched("attr-ads", primary: nil) }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-ads")
    }

    func test_not_apple_ads_finishes_the_check_and_stores_nothing() async {
        configure { _ in Self.notMatched("not_apple_ads") }

        await attribution._checkAppleAdsAttribution()
        await makeAttribution()._checkAppleAdsAttribution()

        XCTAssertTrue(store.appleAdsFinished)
        XCTAssertNil(store.attributionId)
        XCTAssertEqual(appleAdsRequests.count, 1)
    }

    func test_invalid_token_finishes_the_check() async {
        configure { _ in Self.notMatched("invalid_token") }

        await attribution._checkAppleAdsAttribution()

        XCTAssertTrue(store.appleAdsFinished)
        XCTAssertNil(store.attributionId)
    }

    // MARK: - Retries

    private var sentTokens: [String] {
        appleAdsRequests.compactMap { Self.body(of: $0)?["token"] as? String }
    }

    func test_pending_pending_matched_within_one_launch() async {
        var answers: [AppleAdsMockURLProtocol.Outcome] = [
            Self.notMatched("pending"), Self.notMatched("pending"), Self.matched("attr-ads"),
        ]
        configure { _ in answers.removeFirst() }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertTrue(store.appleAdsFinished)
        XCTAssertEqual(store.appleAdsAttemptCount, 0, "A final answer uses no attempt")
        XCTAssertEqual(sentTokens, ["token-1", "token-2", "token-3"],
                       "Every send asks AdServices for a new token")
        XCTAssertEqual(waits.recorded, [AttributionStore.appleAdsSendInterval, AttributionStore.appleAdsSendInterval],
                       "5 seconds before the second and third sends")
    }

    func test_three_pendings_use_one_attempt_of_the_budget() async {
        configure { _ in Self.notMatched("pending") }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(appleAdsRequests.count, AttributionStore.maxAppleAdsSendsPerAttempt)
        XCTAssertEqual(store.appleAdsAttemptCount, 1)
        XCTAssertFalse(store.appleAdsFinished)
    }

    func test_pending_stops_after_the_budget_of_attempts() async {
        configure { _ in Self.notMatched("pending") }

        // Each call stands in for a later launch or return to the foreground.
        for _ in 0 ..< 6 {
            await attribution._checkAppleAdsAttribution()
        }

        XCTAssertEqual(store.appleAdsAttemptCount, AttributionStore.maxAppleAdsAttempts,
                       "The first attempt plus 3 more")
        XCTAssertEqual(appleAdsRequests.count,
                       AttributionStore.maxAppleAdsAttempts * AttributionStore.maxAppleAdsSendsPerAttempt)
        XCTAssertEqual(Set(sentTokens).count, appleAdsRequests.count, "No token is sent twice")
        XCTAssertTrue(store.appleAdsFinished)
    }

    func test_a_later_launch_can_still_match() async {
        var answers: [AppleAdsMockURLProtocol.Outcome] = Array(repeating: Self.notMatched("pending"), count: 3)
            + [Self.matched("attr-ads")]
        configure { _ in answers.removeFirst() }

        await attribution._checkAppleAdsAttribution()
        XCTAssertFalse(store.appleAdsFinished)
        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertEqual(store.appleAdsAttemptCount, 1)
        XCTAssertTrue(store.appleAdsFinished)
    }

    func test_transport_failure_is_retried_within_the_launch() async {
        var answers: [AppleAdsMockURLProtocol.Outcome] = [.failure(URLError(.notConnectedToInternet)), Self.matched("attr-ads")]
        configure { _ in answers.removeFirst() }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertEqual(appleAdsRequests.count, 2)
        XCTAssertEqual(store.appleAdsAttemptCount, 0)
    }

    func test_an_http_error_is_retried_and_counts_as_one_attempt() async {
        configure { _ in Self.json(["error": ["code": "not_found", "message": "no"]], status: 404) }

        await attribution._checkAppleAdsAttribution()

        XCTAssertFalse(store.appleAdsFinished, "The endpoint may not be deployed yet; try again later")
        XCTAssertEqual(appleAdsRequests.count, AttributionStore.maxAppleAdsSendsPerAttempt)
        XCTAssertEqual(store.appleAdsAttemptCount, 1)
    }

    func test_going_to_the_background_stops_the_sends() async {
        configure { _ in Self.notMatched("pending") }
        let attribution = self.attribution!
        waits.onWait = { attribution.setAppInBackground(true) }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(appleAdsRequests.count, 1, "No send after the app went to the background")
        XCTAssertEqual(store.appleAdsAttemptCount, 1)

        // Back in the foreground: the next attempt sends again.
        attribution.setAppInBackground(false)
        waits.onWait = nil
        await attribution._checkAppleAdsAttribution()
        XCTAssertEqual(appleAdsRequests.count, 1 + AttributionStore.maxAppleAdsSendsPerAttempt)
    }

    func test_a_token_error_after_a_pending_send_counts_the_attempt() async {
        configure { _ in Self.notMatched("pending") }
        let tokens = self.tokens!
        waits.onWait = { tokens.failNext = true }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(appleAdsRequests.count, 1)
        XCTAssertEqual(store.appleAdsAttemptCount, 1)
        XCTAssertFalse(store.appleAdsFinished)
    }

    func test_the_check_stops_24_hours_after_the_first_try() async {
        configure { _ in Self.notMatched("pending") }
        store.stampAppleAdsFirstAttemptIfNeeded(Date().addingTimeInterval(-AttributionStore.appleAdsRetryWindow - 60))

        await attribution._checkAppleAdsAttribution()

        XCTAssertTrue(appleAdsRequests.isEmpty)
        XCTAssertTrue(store.appleAdsFinished)
    }

    func test_a_token_error_stops_for_this_launch_only() async {
        configure { _ in Self.matched("attr-ads") }
        tokens.failNext = true

        await attribution._checkAppleAdsAttribution()
        await attribution._checkAppleAdsAttribution()

        XCTAssertTrue(appleAdsRequests.isEmpty)
        XCTAssertEqual(tokens.calls, 1, "No second token request in the same launch")
        XCTAssertFalse(store.appleAdsFinished)
        XCTAssertEqual(store.appleAdsAttemptCount, 0)

        // Next launch.
        await makeAttribution()._checkAppleAdsAttribution()
        XCTAssertEqual(store.attributionId, "attr-ads")
    }

    func test_unavailable_adservices_finishes_the_check() async {
        configure { _ in Self.matched() }
        tokens.unavailable = true

        await attribution._checkAppleAdsAttribution()

        XCTAssertTrue(appleAdsRequests.isEmpty)
        XCTAssertTrue(store.appleAdsFinished)
    }

    // MARK: - Configure flag

    func test_the_check_does_not_run_when_turned_off() async {
        configure(appleAdsAttribution: false) { _ in Self.matched() }

        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(tokens.calls, 0)
        XCTAssertTrue(appleAdsRequests.isEmpty)
        XCTAssertFalse(store.appleAdsFinished)
    }

    func test_apple_ads_attribution_defaults_to_on() {
        let configuration = Configuration(publishableKey: "k", baseURL: Self.baseURL)
        XCTAssertTrue(configuration.appleAdsAttribution)
    }

    // MARK: - Order with match()

    func test_match_after_an_apple_ads_attribution_is_skipped() async {
        configure { request in
            (request.url?.absoluteString ?? "").hasSuffix(APIPath.attributionMatch)
                ? Self.json(["matched": true, "attribution_id": "attr-fingerprint"])
                : Self.matched("attr-ads")
        }

        await attribution._checkAppleAdsAttribution()
        await attribution._match()

        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertEqual(AppleAdsMockURLProtocol.receivedRequests.count, 1, "match() sends nothing")
    }

    // MARK: - Reset

    func test_reset_clears_the_apple_ads_state() async {
        configure { _ in Self.notMatched("pending") }
        await attribution._checkAppleAdsAttribution()
        store.markAppleAdsFinished()

        attribution.reset()

        XCTAssertFalse(store.appleAdsFinished)
        XCTAssertEqual(store.appleAdsAttemptCount, 0)
        XCTAssertNil(store.appleAdsFirstAttempt)
    }
}

// MARK: - WaitRecorder

/// Stands in for the 5-second wait between sends. Records each wait and
/// returns at once; `onWait` lets a test act during the wait.
final class WaitRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var _recorded: [TimeInterval] = []
    private var _onWait: (() -> Void)?

    var recorded: [TimeInterval] { locked { _recorded } }
    var onWait: (() -> Void)? {
        get { locked { _onWait } }
        set { locked { _onWait = newValue } }
    }

    func record(_ seconds: TimeInterval) {
        let action: (() -> Void)? = locked {
            _recorded.append(seconds)
            return _onWait
        }
        action?()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - FakeAppleAdsTokenProvider

/// Hands out `token-1`, `token-2`, … so tests can see that every attempt
/// asks for a new token.
final class FakeAppleAdsTokenProvider: AppleAdsTokenProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var _calls = 0
    private var _failNext = false
    private var _unavailable = false

    var calls: Int { locked { _calls } }
    var failNext: Bool {
        get { locked { _failNext } }
        set { locked { _failNext = newValue } }
    }
    var unavailable: Bool {
        get { locked { _unavailable } }
        set { locked { _unavailable = newValue } }
    }

    func attributionToken() throws -> String? {
        try locked {
            _calls += 1
            if _failNext {
                _failNext = false
                throw URLError(.notConnectedToInternet)
            }
            return _unavailable ? nil : "token-\(_calls)"
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - AppleAdsMockURLProtocol

private final class AppleAdsMockURLProtocol: URLProtocol {

    enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _receivedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var _responder: ((URLRequest) -> Outcome)?

    static var receivedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedRequests
    }

    static var responder: ((URLRequest) -> Outcome)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _responder
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _responder = newValue
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _receivedRequests = []
        _responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._receivedRequests.append(request)
        let responder = Self._responder
        Self.lock.unlock()

        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch responder(request) {
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
