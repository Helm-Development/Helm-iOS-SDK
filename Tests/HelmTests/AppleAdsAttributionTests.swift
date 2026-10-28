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
    private var attribution: Attribution!

    override func setUp() {
        super.setUp()
        suiteName = "dev.helmcode.helm.tests.appleads.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AttributionStore(defaults: defaults)
        tokens = FakeAppleAdsTokenProvider()
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
                    appleAdsTokenProvider: tokens)
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

    func test_pending_retries_with_a_new_token_up_to_the_limit() async {
        configure { _ in Self.notMatched("pending") }

        // Each call stands in for a later launch or return to the foreground.
        for _ in 0 ..< 6 {
            await attribution._checkAppleAdsAttribution()
        }

        XCTAssertEqual(appleAdsRequests.count, AttributionStore.maxAppleAdsAttempts,
                       "The first try plus 3 more")
        XCTAssertEqual(appleAdsRequests.compactMap { Self.body(of: $0)?["token"] as? String },
                       ["token-1", "token-2", "token-3", "token-4"],
                       "Every attempt asks AdServices for a new token")
        XCTAssertTrue(store.appleAdsFinished)
    }

    func test_pending_then_match_stores_the_attribution() async {
        var answers: [AppleAdsMockURLProtocol.Outcome] = [Self.notMatched("pending"), Self.matched("attr-ads")]
        configure { _ in answers.removeFirst() }

        await attribution._checkAppleAdsAttribution()
        XCTAssertFalse(store.appleAdsFinished)
        await attribution._checkAppleAdsAttribution()

        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertTrue(store.appleAdsFinished)
    }

    func test_transport_failure_retries() async {
        var answers: [AppleAdsMockURLProtocol.Outcome] = [.failure(URLError(.notConnectedToInternet)), Self.matched("attr-ads")]
        configure { _ in answers.removeFirst() }

        await attribution._checkAppleAdsAttribution()
        XCTAssertFalse(store.appleAdsFinished)
        XCTAssertEqual(store.appleAdsAttemptCount, 1)

        await attribution._checkAppleAdsAttribution()
        XCTAssertEqual(store.attributionId, "attr-ads")
        XCTAssertEqual(appleAdsRequests.count, 2)
    }

    func test_an_http_error_counts_as_an_attempt() async {
        configure { _ in Self.json(["error": ["code": "not_found", "message": "no"]], status: 404) }

        await attribution._checkAppleAdsAttribution()

        XCTAssertFalse(store.appleAdsFinished, "The endpoint may not be deployed yet; try again later")
        XCTAssertEqual(store.appleAdsAttemptCount, 1)
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
