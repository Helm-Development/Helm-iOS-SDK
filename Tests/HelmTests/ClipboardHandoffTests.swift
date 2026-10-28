import UniformTypeIdentifiers
import XCTest
@testable import Helm

/// HELM-325: clipboard handoff. Path parity, handoff URL parsing, the redeem
/// request body, response handling (including the HELM-335 `primary` rule),
/// the offline queue, the order with `match()`, and `hasClipboardHandoff()`.
///
/// The clipboard is a `FakePasteboard`, so these tests never touch the real
/// one.
final class ClipboardHandoffTests: XCTestCase {

    private static let installationId = "fixed-install-id"
    private static let baseURL = "https://example.invalid"
    private static let code = "AbC123_-xyz9Q"
    private static let handoffURL = URL(string: "https://links.example.com/h/\(code)/")!

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: AttributionStore!
    private var pendingStore: PendingSubmissionStore!
    private var pasteboard: FakePasteboard!
    private var attribution: Attribution!

    override func setUp() {
        super.setUp()
        suiteName = "dev.helmcode.helm.tests.clipboard.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AttributionStore(defaults: defaults)
        pendingStore = PendingSubmissionStore(defaults: defaults)
        pasteboard = FakePasteboard()
        attribution = Attribution(store: store,
                                  pendingStore: pendingStore,
                                  statusCache: AttributionStatusCache(defaults: defaults),
                                  installationId: { Self.installationId },
                                  pasteboard: pasteboard)
        Configuration.shared = nil
        ClipboardMockURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        pendingStore = nil
        pasteboard = nil
        attribution = nil
        Configuration.shared = nil
        ClipboardMockURLProtocol.reset()
        Analytics.shared.testHook_clearAttributionToken()
        super.tearDown()
    }

    // MARK: - Helpers

    private func configureSDK(debug: Bool = false,
                              responder: @escaping (URLRequest) -> ClipboardMockURLProtocol.Outcome) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClipboardMockURLProtocol.self]
        ClipboardMockURLProtocol.responder = responder
        Helm.configure(publishableKey: "test-key",
                       baseURL: Self.baseURL,
                       debug: debug,
                       appleAdsAttribution: false,
                       session: URLSession(configuration: config))
    }

    private static func json(_ object: [String: Any], status: Int = 200) -> ClipboardMockURLProtocol.Outcome {
        let response = HTTPURLResponse(url: URL(string: baseURL)!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return .response(response, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func matched(_ id: String = "attr-clip", primary: Bool? = true) -> ClipboardMockURLProtocol.Outcome {
        var body: [String: Any] = ["matched": true, "attribution_id": id]
        if let primary { body["primary"] = primary }
        return json(body)
    }

    private static func path(of request: URLRequest) -> String {
        String((request.url?.absoluteString ?? "").dropFirst(baseURL.count))
    }

    private func requests(forPath path: String) -> [URLRequest] {
        ClipboardMockURLProtocol.receivedRequests.filter { Self.path(of: $0) == path }
    }

    private func body(of request: URLRequest) -> [String: Any]? {
        guard let data = Self.data(of: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func data(of request: URLRequest) -> Data? {
        // URLSession strips httpBody when handing the request to URLProtocol;
        // bodyStream survives.
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

    private func redeem(_ url: URL? = ClipboardHandoffTests.handoffURL) async -> ClipboardHandoffResult {
        await attribution._redeemClipboardHandoff(url, changeCountAtPaste: pasteboard.changeCount)
    }

    // MARK: - Path parity

    func test_clipboard_path_matches_the_backend_exactly() {
        XCTAssertEqual(APIPath.attributionClipboard, "/api/client/v1/attribution/clipboard/")
    }

    // MARK: - Handoff URL parsing

    func test_code_is_read_from_a_handoff_url() {
        XCTAssertEqual(ClipboardHandoffCode.code(from: Self.handoffURL), Self.code)
        XCTAssertEqual(ClipboardHandoffCode.code(from: URL(string: "https://helmcode.dev/h/abcdefghijkl/")!),
                       "abcdefghijkl", "Exactly 12 characters is the minimum")
        XCTAssertEqual(ClipboardHandoffCode.code(from: URL(string: "HTTPS://Links.Example.com/h/\(Self.code)/?utm=x#y")!),
                       Self.code, "Scheme case, query and fragment do not matter")
    }

    func test_other_urls_are_ignored() {
        let rejected = [
            "http://links.example.com/h/\(Self.code)/",       // not https
            "https://links.example.com/h/\(Self.code)",       // no trailing slash
            "https://links.example.com/h/abcdefghijk/",       // 11 characters
            "https://links.example.com/h/abc.defghijkl/",     // character outside the set
            "https://links.example.com/h/abcdef%2Fghijkl/",   // encoded slash
            "https://links.example.com/h/\(Self.code)/more/", // extra segment
            "https://links.example.com/x/h/\(Self.code)/",    // prefix segment
            "https://links.example.com/H/\(Self.code)/",      // wrong case of h
            "https://links.example.com/\(Self.code)/",        // no /h/
            "helm:///h/\(Self.code)/",                        // no host, wrong scheme
        ]
        for string in rejected {
            XCTAssertNil(ClipboardHandoffCode.code(from: URL(string: string)!), string)
        }
    }

    func test_a_non_handoff_url_sends_nothing_and_reports_not_matched() async {
        configureSDK { _ in Self.matched() }

        let result = await redeem(URL(string: "https://example.com/recipes/42/")!)

        XCTAssertEqual(result, .notMatched(reason: "not_handoff_url"))
        XCTAssertTrue(requests(forPath: APIPath.attributionClipboard).isEmpty)
        XCTAssertEqual(store.clipboardDismissedChangeCount, pasteboard.changeCount)
    }

    func test_a_paste_without_a_url_reports_not_matched() async {
        configureSDK { _ in Self.matched() }

        let result = await redeem(nil)

        XCTAssertEqual(result, .notMatched(reason: "not_handoff_url"))
        XCTAssertTrue(ClipboardMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: - Request body

    func test_redeem_body_carries_code_device_id_and_debug() async throws {
        configureSDK(debug: true) { _ in Self.matched() }

        _ = await redeem()

        let request = try XCTUnwrap(requests(forPath: APIPath.attributionClipboard).first)
        let body = try XCTUnwrap(body(of: request))
        XCTAssertEqual(body["code"] as? String, Self.code)
        XCTAssertEqual(body["device_id"] as? String, Self.installationId)
        XCTAssertEqual(Set(body.keys), ["code", "device_id", "debug"])
        let raw = String(decoding: try XCTUnwrap(Self.data(of: request)), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"debug\":true"), "debug must be a JSON boolean: \(raw)")
    }

    // MARK: - Responses

    func test_primary_match_stores_the_attribution_and_clears_the_clipboard() async {
        configureSDK { _ in Self.matched("attr-clip") }
        store.storeMatch(attributionId: "attr-fingerprint")
        let changeCountBefore = pasteboard.changeCount

        let result = await redeem()

        XCTAssertEqual(result, .matched)
        XCTAssertEqual(store.attributionId, "attr-clip", "Replaces an earlier match() result")
        XCTAssertEqual(store.exactMethod, .clipboard)
        XCTAssertTrue(store.clipboardRedeemed)
        XCTAssertEqual(Analytics.shared.testHook_attributionToken, "attr-clip")
        XCTAssertEqual(pasteboard.clearCount, 1)
        XCTAssertNotEqual(pasteboard.changeCount, changeCountBefore)
    }

    func test_a_response_without_primary_is_treated_as_primary() async {
        configureSDK { _ in Self.matched("attr-clip", primary: nil) }

        _ = await redeem()

        XCTAssertEqual(store.attributionId, "attr-clip")
    }

    func test_match_that_is_not_primary_keeps_the_stored_attribution() async {
        configureSDK { _ in Self.matched("attr-clip", primary: false) }
        store.storeMatch(attributionId: "attr-apple-ads")

        let result = await redeem()

        XCTAssertEqual(result, .matched)
        XCTAssertEqual(store.attributionId, "attr-apple-ads")
        XCTAssertNil(store.exactMethod)
        XCTAssertTrue(store.clipboardRedeemed, "The code is used up either way")
        XCTAssertNil(Analytics.shared.testHook_attributionToken)
    }

    func test_clipboard_is_not_cleared_when_it_changed_since_the_paste() async {
        configureSDK { _ in Self.matched() }
        let changeCountAtPaste = pasteboard.changeCount
        pasteboard.simulateCopy(hasURL: false)

        _ = await attribution._redeemClipboardHandoff(Self.handoffURL, changeCountAtPaste: changeCountAtPaste)

        XCTAssertEqual(pasteboard.clearCount, 0, "The user copied something else; leave it alone")
    }

    func test_unmatched_response_stores_nothing_new() async {
        configureSDK { _ in Self.json(["matched": false, "reason": "expired"]) }
        store.storeMatch(attributionId: "attr-fingerprint")

        let result = await redeem()

        XCTAssertEqual(result, .notMatched(reason: "expired"))
        XCTAssertEqual(store.attributionId, "attr-fingerprint")
        XCTAssertNil(store.exactMethod)
        XCTAssertFalse(store.clipboardRedeemed)
        XCTAssertEqual(pasteboard.clearCount, 0)
        XCTAssertNil(Analytics.shared.testHook_attributionToken)
    }

    func test_transport_failure_queues_the_code_and_replay_redeems_it() async throws {
        configureSDK { _ in .failure(URLError(.notConnectedToInternet)) }

        let result = await redeem()

        XCTAssertEqual(result, .failed)
        let queued = try XCTUnwrap(pendingStore.all().first)
        XCTAssertEqual(queued.kind, .clipboardHandoff)
        XCTAssertEqual(queued.value, Self.code)
        XCTAssertEqual(queued.userId, "")
        XCTAssertNil(store.attributionId)

        // Back online: the replay sends the same body and applies the answer.
        ClipboardMockURLProtocol.responder = { _ in Self.matched("attr-replayed") }
        await attribution._replayPendingSubmissions()

        XCTAssertEqual(pendingStore.count, 0)
        XCTAssertEqual(store.attributionId, "attr-replayed")
        XCTAssertTrue(store.clipboardRedeemed)
        XCTAssertEqual(pasteboard.clearCount, 0, "A replay never clears the clipboard")
        let replayed = try XCTUnwrap(requests(forPath: APIPath.attributionClipboard).last)
        XCTAssertEqual(body(of: replayed)?["code"] as? String, Self.code)
    }

    func test_a_5xx_is_queued_but_a_4xx_is_not() async {
        configureSDK { _ in Self.json(["error": ["code": "invalid_token", "message": "no"]], status: 401) }

        let result = await redeem()

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(pendingStore.count, 0, "A 4xx is an answer, not an outage")

        ClipboardMockURLProtocol.responder = { _ in Self.json([:], status: 503) }
        _ = await redeem()
        XCTAssertEqual(pendingStore.count, 1, "A 5xx is queued")
    }

    func test_redeem_before_configure_fails_without_queueing() async {
        let result = await redeem()

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(pendingStore.count, 0)
    }

    // MARK: - Order with match()

    func test_match_after_a_clipboard_attribution_is_skipped() async {
        configureSDK { request in
            Self.path(of: request) == APIPath.attributionMatch
                ? Self.json(["matched": true, "attribution_id": "attr-fingerprint"])
                : Self.matched("attr-clip")
        }

        _ = await redeem()
        await attribution._match()

        XCTAssertEqual(store.attributionId, "attr-clip")
        XCTAssertTrue(requests(forPath: APIPath.attributionMatch).isEmpty)
        XCTAssertTrue(store.hasChecked)
    }

    func test_clipboard_wins_when_match_finishes_last() async throws {
        configureSDK { request in
            Self.path(of: request) == APIPath.attributionMatch
                ? .delayed(0.5, Self.json(["matched": true, "attribution_id": "attr-fingerprint"]))
                : Self.matched("attr-clip")
        }

        let attribution = self.attribution!
        let matchTask = Task.detached { await attribution._match() }
        try await waitUntil { !self.requests(forPath: APIPath.attributionMatch).isEmpty }

        _ = await redeem()
        await matchTask.value

        XCTAssertEqual(store.attributionId, "attr-clip")
        XCTAssertEqual(Analytics.shared.testHook_attributionToken, "attr-clip")
    }

    func test_clipboard_wins_when_match_finished_first() async {
        configureSDK { request in
            Self.path(of: request) == APIPath.attributionMatch
                ? Self.json(["matched": true, "attribution_id": "attr-fingerprint"])
                : Self.matched("attr-clip")
        }

        await attribution._match()
        _ = await redeem()

        XCTAssertEqual(store.attributionId, "attr-clip")
    }

    func test_events_recorded_during_the_redeem_carry_the_clipboard_attribution() async throws {
        configureSDK { request in
            switch Self.path(of: request) {
            case APIPath.attributionClipboard: return .delayed(0.3, Self.matched("attr-clip"))
            default: return Self.json(["ok": true])
            }
        }

        let attribution = self.attribution!
        let pasteboard = self.pasteboard!
        let redeemTask = Task.detached {
            await attribution._redeemClipboardHandoff(Self.handoffURL, changeCountAtPaste: pasteboard.changeCount)
        }
        try await waitUntil { attribution.testHook_isMatchInFlight }
        attribution.increment("signup")
        XCTAssertEqual(attribution.testHook_pendingEventCount, 1)

        _ = await redeemTask.value
        try await waitUntil { !self.requests(forPath: APIPath.attributionEvent).isEmpty }

        let event = try XCTUnwrap(requests(forPath: APIPath.attributionEvent).first)
        XCTAssertEqual(body(of: event)?["attribution_id"] as? String, "attr-clip")
    }

    // MARK: - hasClipboardHandoff()

    func test_has_clipboard_handoff_follows_the_clipboard() async {
        pasteboard.simulateCopy(hasURL: false)
        let empty = await attribution.hasClipboardHandoff()
        XCTAssertFalse(empty)

        pasteboard.simulateCopy(hasURL: true)
        let withURL = await attribution.hasClipboardHandoff()
        XCTAssertTrue(withURL)
    }

    func test_has_clipboard_handoff_is_false_once_attributed() async {
        configureSDK { _ in Self.matched() }
        pasteboard.simulateCopy(hasURL: true)

        _ = await redeem()
        pasteboard.simulateCopy(hasURL: true)

        let available = await attribution.hasClipboardHandoff()
        XCTAssertFalse(available)
    }

    func test_has_clipboard_handoff_is_false_while_a_code_is_queued() async {
        configureSDK { _ in .failure(URLError(.timedOut)) }
        pasteboard.simulateCopy(hasURL: true)

        _ = await redeem()

        let available = await attribution.hasClipboardHandoff()
        XCTAssertFalse(available)
    }

    func test_has_clipboard_handoff_is_false_until_a_rejected_paste_is_replaced() async {
        configureSDK { _ in Self.json(["matched": false, "reason": "redeemed"]) }
        pasteboard.simulateCopy(hasURL: true)

        _ = await redeem()
        let afterRejection = await attribution.hasClipboardHandoff()
        XCTAssertFalse(afterRejection, "The same clipboard contents were already tried")

        pasteboard.simulateCopy(hasURL: true)
        let afterNewCopy = await attribution.hasClipboardHandoff()
        XCTAssertTrue(afterNewCopy)
    }

    func test_availability_change_is_posted_after_a_redeem() async throws {
        configureSDK { _ in Self.matched() }
        pasteboard.simulateCopy(hasURL: true)
        let initial = await attribution.hasClipboardHandoff()
        XCTAssertTrue(initial)

        let posted = expectation(forNotification: .helmClipboardHandoffAvailabilityDidChange,
                                 object: attribution) { notification in
            notification.userInfo?["available"] as? Bool == false
        }
        _ = await redeem()

        await fulfillment(of: [posted], timeout: 2)
    }

    func test_recheck_does_nothing_until_the_app_asks() async {
        pasteboard.simulateCopy(hasURL: true)

        await attribution._recheckClipboardHandoff()

        XCTAssertEqual(pasteboard.probeCount, 0, "The clipboard is never checked for apps that do not use the feature")
    }

    // MARK: - Reset

    func test_reset_clears_clipboard_state() async {
        configureSDK { _ in Self.matched() }
        _ = await redeem()
        store.storeClipboardDismissed(changeCount: 7)

        attribution.reset()

        XCTAssertFalse(store.clipboardRedeemed)
        XCTAssertNil(store.exactMethod)
        XCTAssertNil(store.clipboardDismissedChangeCount)
        XCTAssertNil(store.attributionId)
    }

    // MARK: - Pasted items (URL or plain text)

    /// Item providers built in memory, standing in for what a Paste button
    /// hands over. They never touch the real clipboard.
    private static func urlItem(_ string: String) -> NSItemProvider {
        NSItemProvider(object: URL(string: string)! as NSURL)
    }

    /// A plain-text item only, like a web page's text copy. Built from data
    /// rather than `NSItemProvider(object: NSString)`, which on macOS also
    /// registers `public.url` for text that looks like a URL.
    private static func textItem(_ string: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                            visibility: .all) { completion in
            completion(Data(string.utf8), nil)
            return nil
        }
        return provider
    }

    func test_loader_reads_a_url_item() async {
        let url = await PastedItemLoader.url(from: [Self.urlItem(Self.handoffURL.absoluteString)])
        XCTAssertEqual(url, Self.handoffURL)
    }

    func test_loader_reads_a_text_item_and_trims_whitespace() async {
        let url = await PastedItemLoader.url(from: [Self.textItem("  \(Self.handoffURL.absoluteString)\n")])
        XCTAssertEqual(url, Self.handoffURL)
    }

    func test_loader_prefers_a_url_item_over_a_text_item() async {
        let fromURLItem = "https://links.example.com/h/fromTheUrlItem/"
        let url = await PastedItemLoader.url(from: [
            Self.textItem("https://links.example.com/h/fromTheTextItem/"),
            Self.urlItem(fromURLItem),
        ])
        XCTAssertEqual(url?.absoluteString, fromURLItem)
    }

    func test_loader_returns_nil_for_no_items_or_blank_text() async {
        let none = await PastedItemLoader.url(from: [])
        XCTAssertNil(none)
        let blank = await PastedItemLoader.url(from: [Self.textItem("  \n ")])
        XCTAssertNil(blank)
    }

    func test_pasted_text_with_a_handoff_url_is_redeemed() async throws {
        configureSDK { _ in Self.matched("attr-clip") }

        let result = await attribution._handlePaste(itemProviders: [Self.textItem(" \(Self.handoffURL.absoluteString) ")],
                                                    changeCountAtPaste: pasteboard.changeCount)

        XCTAssertEqual(result, .matched)
        XCTAssertEqual(store.attributionId, "attr-clip")
        let request = try XCTUnwrap(requests(forPath: APIPath.attributionClipboard).first)
        XCTAssertEqual(body(of: request)?["code"] as? String, Self.code)
    }

    func test_pasted_text_that_is_not_a_handoff_url_sends_nothing() async {
        configureSDK { _ in Self.matched() }

        for text in ["hello world", "https://example.com/recipes/42/", "\(Self.code)"] {
            let result = await attribution._handlePaste(itemProviders: [Self.textItem(text)],
                                                        changeCountAtPaste: pasteboard.changeCount)
            XCTAssertEqual(result, .notMatched(reason: "not_handoff_url"), text)
        }
        XCTAssertTrue(ClipboardMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: - Polling

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met within 2 s")
    }
}

// MARK: - FakePasteboard

/// A clipboard for tests. `simulateCopy` stands in for the user copying
/// something in another app.
final class FakePasteboard: PasteboardAccess, @unchecked Sendable {

    private let lock = NSLock()
    private var _changeCount = 100
    private var _hasURL = false
    private var _clearCount = 0
    private var _probeCount = 0

    var changeCount: Int { locked { _changeCount } }
    var clearCount: Int { locked { _clearCount } }
    var probeCount: Int { locked { _probeCount } }

    func simulateCopy(hasURL: Bool) {
        locked {
            _changeCount += 1
            _hasURL = hasURL
        }
    }

    func hasProbableWebURL() async -> Bool {
        probe()
    }

    func clear() {
        locked {
            _clearCount += 1
            _changeCount += 1
            _hasURL = false
        }
    }

    private func probe() -> Bool {
        locked {
            _probeCount += 1
            return _hasURL
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - ClipboardMockURLProtocol

/// Test-only `URLProtocol` for the clipboard handoff tests. A response can be
/// delayed without blocking the loading thread, so two requests can be in
/// flight at once.
private final class ClipboardMockURLProtocol: URLProtocol {

    indirect enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(URLError)
        case delayed(TimeInterval, Outcome)
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
        deliver(responder(request))
    }

    private func deliver(_ outcome: Outcome) {
        switch outcome {
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .delayed(let seconds, let inner):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                deliver(inner)
            }
        }
    }

    override func stopLoading() {}
}
