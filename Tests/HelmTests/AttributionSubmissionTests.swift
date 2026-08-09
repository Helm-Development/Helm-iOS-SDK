import XCTest
@testable import Helm

/// HELM-220 integration matrix for the influencer-attribution methods:
/// path parity, request-body composition, terminal-vs-transport classification,
/// offline queue replay, and status-cache fallback.
final class AttributionSubmissionTests: XCTestCase {

    private static let installationId = "fixed-install-id"
    /// Opaque, SHA-256-shaped id — must be passed through verbatim.
    private static let userId = "9f2c1b7a4e6d8c0f13a5b7d9e1f3a5c79b1d3f5a7c9e1b3d5f7a9c1e3b5d7f90"

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: AttributionStore!
    private var pendingStore: PendingSubmissionStore!
    private var statusCache: AttributionStatusCache!
    private var attribution: Attribution!

    override func setUp() {
        super.setUp()
        suiteName = "dev.helmcode.helm.tests.attributionsubmission.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AttributionStore(defaults: defaults)
        pendingStore = PendingSubmissionStore(defaults: defaults)
        statusCache = AttributionStatusCache(defaults: defaults)
        attribution = makeAttribution()

        Configuration.shared = nil
        SubmissionMockURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        pendingStore = nil
        statusCache = nil
        attribution = nil
        Configuration.shared = nil
        SubmissionMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAttribution(pendingStore: PendingSubmissionStore? = nil) -> Attribution {
        Attribution(store: store,
                    pendingStore: pendingStore ?? self.pendingStore,
                    statusCache: statusCache,
                    installationId: { Self.installationId })
    }

    private func configureSDK(responder: @escaping (URLRequest) -> SubmissionMockURLProtocol.Outcome) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubmissionMockURLProtocol.self]
        let session = URLSession(configuration: config)
        SubmissionMockURLProtocol.responder = responder
        Helm.configure(publishableKey: "test-key",
                       baseURL: Self.baseURL,
                       session: session)
    }

    private static func json(_ object: [String: Any], status: Int = 200) -> SubmissionMockURLProtocol.Outcome {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/")!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return .response(response, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func errorEnvelope(code: String, message: String = "nope", status: Int = 400) -> SubmissionMockURLProtocol.Outcome {
        json(["error": ["code": code, "message": message]], status: status)
    }

    private static func serverFailure(status: Int = 500) -> SubmissionMockURLProtocol.Outcome {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/")!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return .response(response, Data())
    }

    private static let linkedSuccess: [String: Any] = [
        "linked": true,
        "influencer_code": "elysia",
        "offering_id": "inf_monthly",
    ]

    private static let baseURL = "https://example.invalid"

    /// The request's path *including* its trailing slash. `URL.path` strips the
    /// trailing slash, which would defeat the whole point of these assertions.
    private static func path(of request: URLRequest) -> String {
        guard let absolute = request.url?.absoluteString else { return "" }
        return String(absolute.dropFirst(baseURL.count))
    }

    /// Bodies of every request that hit the given path, in arrival order.
    private func bodies(forPath path: String) -> [[String: Any]] {
        SubmissionMockURLProtocol.receivedRequests
            .filter { Self.path(of: $0) == path }
            .compactMap { bodyFromRequest($0) }
    }

    private func requestedPaths() -> [String] {
        SubmissionMockURLProtocol.receivedRequests.map { Self.path(of: $0) }
    }

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

    /// Poll until `condition` holds or ~2 s elapse.
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. Path parity with the backend (HELM-183 lesson)

    /// These literals are a contract with the backend router. A single
    /// character of drift is a silent 404 for every integrator.
    func test_attribution_paths_match_the_backend_exactly() {
        XCTAssertEqual(APIPath.attributionPromoCode, "/api/client/v1/attribution/promo-code/")
        XCTAssertEqual(APIPath.attributionStatus, "/api/client/v1/attribution/status/")
        XCTAssertEqual(APIPath.attributionTransaction, "/api/client/v1/attribution/transaction/")
    }

    // MARK: - 2. Request-body composition

    func test_promo_code_body_carries_user_id_code_platform_and_device_id() async throws {
        configureSDK { _ in Self.json(Self.linkedSuccess) }

        _ = try await attribution.submitPromoCode(userId: Self.userId, code: "Elysia")

        let body = try XCTUnwrap(bodies(forPath: APIPath.attributionPromoCode).first)
        XCTAssertEqual(body["user_id"] as? String, Self.userId,
                       "userId must be passed through verbatim — no normalization or hashing")
        XCTAssertEqual(body["code"] as? String, "Elysia",
                       "The code is sent verbatim; the server normalizes case")
        XCTAssertEqual(body["platform"] as? String, AnalyticsClient.platformName())
        XCTAssertEqual(body["device_id"] as? String, Self.installationId)
        #if os(iOS)
        XCTAssertEqual(body["platform"] as? String, "ios")
        #endif
    }

    func test_status_body_carries_user_id_platform_and_device_id_but_no_code() async throws {
        configureSDK { _ in Self.json(["linked": false]) }

        _ = try await attribution.fetchAttributionStatus(userId: Self.userId)

        let body = try XCTUnwrap(bodies(forPath: APIPath.attributionStatus).first)
        XCTAssertEqual(body["user_id"] as? String, Self.userId)
        XCTAssertEqual(body["platform"] as? String, AnalyticsClient.platformName())
        XCTAssertEqual(body["device_id"] as? String, Self.installationId)
        XCTAssertNil(body["code"])
    }

    func test_transaction_body_carries_original_transaction_id() async throws {
        configureSDK { _ in Self.json(["ok": true]) }

        await attribution._submitOriginalTransactionId(userId: Self.userId,
                                                       originalTransactionId: "2000000123456789")

        let body = try XCTUnwrap(bodies(forPath: APIPath.attributionTransaction).first)
        XCTAssertEqual(body["user_id"] as? String, Self.userId)
        XCTAssertEqual(body["original_transaction_id"] as? String, "2000000123456789")
        XCTAssertEqual(body["platform"] as? String, AnalyticsClient.platformName())
        XCTAssertEqual(body["device_id"] as? String, Self.installationId)
    }

    // MARK: - 3. submitPromoCode success

    func test_submit_promo_code_success_returns_linked_and_primes_the_cache() async throws {
        configureSDK { _ in Self.json(Self.linkedSuccess) }

        let result = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")

        XCTAssertEqual(result, .linked(influencerCode: "elysia", offeringId: "inf_monthly"))
        XCTAssertEqual(pendingStore.count, 0, "A successful submission must not be queued")

        let cached = try XCTUnwrap(statusCache.status(for: Self.userId))
        XCTAssertTrue(cached.isLinked)
        XCTAssertEqual(cached.influencerCode, "elysia")
        XCTAssertEqual(cached.offeringId, "inf_monthly")
    }

    func test_submit_promo_code_success_without_offering_id_returns_nil_offering() async throws {
        configureSDK { _ in Self.json(["linked": true, "influencer_code": "elysia"]) }

        let result = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")

        XCTAssertEqual(result, .linked(influencerCode: "elysia", offeringId: nil))
    }

    func test_submit_promo_code_success_without_influencer_code_falls_back_to_submitted_code() async throws {
        configureSDK { _ in Self.json(["linked": true]) }

        let result = try await attribution.submitPromoCode(userId: Self.userId, code: "ELYSIA")

        XCTAssertEqual(result, .linked(influencerCode: "ELYSIA", offeringId: nil))
    }

    func test_submit_promo_code_with_unparseable_success_body_throws_invalid_response() async {
        configureSDK { _ in Self.json(["unexpected": "shape"]) }

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")
            XCTFail("A 2xx without `linked` must throw .invalidResponse")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .invalidResponse)
        }
        XCTAssertEqual(pendingStore.count, 0, "An unparseable success is terminal, not queued")
    }

    // MARK: - 4. Terminal vs transport classification

    func test_invalid_code_is_terminal_and_never_queued() async {
        configureSDK { _ in Self.errorEnvelope(code: "invalid_code") }

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "nope")
            XCTFail("invalid_code must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .invalidCode)
        }
        XCTAssertEqual(pendingStore.count, 0)
    }

    func test_code_inactive_is_terminal() async {
        configureSDK { _ in Self.errorEnvelope(code: "code_inactive") }

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "expired")
            XCTFail("code_inactive must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .codeInactive)
        }
        XCTAssertEqual(pendingStore.count, 0)
    }

    func test_already_linked_is_terminal() async {
        configureSDK { _ in Self.errorEnvelope(code: "already_linked") }

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "other")
            XCTFail("already_linked must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .alreadyLinked)
        }
        XCTAssertEqual(pendingStore.count, 0)
    }

    func test_unknown_backend_code_passes_through_as_server_error() async {
        configureSDK { _ in Self.errorEnvelope(code: "promo_codes_disabled", message: "not on this plan") }

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "x")
            XCTFail("An unknown code must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError,
                           .server(code: "promo_codes_disabled", message: "not on this plan"))
        }
    }

    func test_unparseable_4xx_body_becomes_a_server_error_keyed_by_status() async {
        configureSDK { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.invalid/")!,
                                           statusCode: 403,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return .response(response, Data("Forbidden".utf8))
        }

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "x")
            XCTFail("A 403 must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError,
                           .server(code: "http_403", message: "Forbidden"))
        }
        XCTAssertEqual(pendingStore.count, 0, "4xx is terminal by spec — including 408/429")
    }

    func test_server_5xx_queues_the_submission_and_returns_queued() async throws {
        configureSDK { _ in Self.serverFailure(status: 503) }

        let result = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")

        XCTAssertEqual(result, .queued)
        let queued = pendingStore.all()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.kind, .promoCode)
        XCTAssertEqual(queued.first?.userId, Self.userId)
        XCTAssertEqual(queued.first?.value, "elysia")
    }

    func test_connectivity_failure_queues_the_submission_and_returns_queued() async throws {
        configureSDK { _ in .failure(URLError(.notConnectedToInternet)) }

        let result = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")

        XCTAssertEqual(result, .queued)
        XCTAssertEqual(pendingStore.count, 1)
    }

    // MARK: - 5. Queue replay

    func test_queued_submission_replays_once_the_network_returns() async throws {
        configureSDK { _ in Self.serverFailure() }
        let queuedResult = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")
        XCTAssertEqual(queuedResult, .queued)

        SubmissionMockURLProtocol.reset()
        configureSDK { _ in Self.json(Self.linkedSuccess) }

        await attribution._replayPendingSubmissions()

        let replayed = bodies(forPath: APIPath.attributionPromoCode)
        XCTAssertEqual(replayed.count, 1, "The queued submission must be replayed exactly once")
        XCTAssertEqual(replayed.first?["code"] as? String, "elysia")
        XCTAssertEqual(replayed.first?["user_id"] as? String, Self.userId)
        XCTAssertEqual(pendingStore.count, 0, "A successful replay must dequeue the entry")
        XCTAssertEqual(statusCache.status(for: Self.userId)?.offeringId, "inf_monthly",
                       "A replayed promo code must update the status cache")
    }

    func test_queued_transaction_replays_to_the_transaction_endpoint() async throws {
        configureSDK { _ in .failure(URLError(.timedOut)) }
        await attribution._submitOriginalTransactionId(userId: Self.userId,
                                                       originalTransactionId: "2000000123456789")
        XCTAssertEqual(pendingStore.all().first?.kind, .transaction)

        SubmissionMockURLProtocol.reset()
        configureSDK { _ in Self.json(["ok": true]) }

        await attribution._replayPendingSubmissions()

        let replayed = bodies(forPath: APIPath.attributionTransaction)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed.first?["original_transaction_id"] as? String, "2000000123456789")
        XCTAssertEqual(pendingStore.count, 0)
    }

    // MARK: - 6. Replay-before-call trigger

    func test_pending_submission_replays_before_a_status_read() async throws {
        pendingStore.enqueue(PendingSubmission(kind: .promoCode,
                                               userId: Self.userId,
                                               value: "elysia",
                                               enqueuedAt: Date()))

        configureSDK { request in
            if Self.path(of: request) == APIPath.attributionPromoCode {
                return Self.json(Self.linkedSuccess)
            }
            return Self.json(["linked": true, "influencer_code": "elysia", "offering_id": "inf_monthly"])
        }

        _ = try await attribution.fetchAttributionStatus(userId: Self.userId)

        XCTAssertEqual(requestedPaths(),
                       [APIPath.attributionPromoCode, APIPath.attributionStatus],
                       "A queued promo code must land before the status read that follows it")
    }

    // MARK: - 7. Replay terminal outcome

    func test_replay_of_a_now_invalid_code_drops_the_entry_silently() async throws {
        pendingStore.enqueue(PendingSubmission(kind: .promoCode,
                                               userId: Self.userId,
                                               value: "elysia",
                                               enqueuedAt: Date()))
        configureSDK { _ in Self.errorEnvelope(code: "invalid_code") }

        // Must not throw — the caller that submitted this has long since returned.
        await attribution._replayPendingSubmissions()

        XCTAssertEqual(pendingStore.count, 0, "A terminal replay verdict must dequeue the entry")
        XCTAssertNil(statusCache.status(for: Self.userId),
                     "A rejected replay must not write a linked status")
    }

    // MARK: - 8. Replay transport outcome

    func test_replay_halts_at_the_first_transport_failure_and_keeps_every_entry() async throws {
        pendingStore.enqueue(PendingSubmission(kind: .promoCode, userId: Self.userId,
                                               value: "elysia", enqueuedAt: Date()))
        pendingStore.enqueue(PendingSubmission(kind: .transaction, userId: Self.userId,
                                               value: "2000000123456789", enqueuedAt: Date()))
        configureSDK { _ in Self.serverFailure() }

        await attribution._replayPendingSubmissions()

        XCTAssertEqual(pendingStore.count, 2, "Both entries must survive a still-down network")
        XCTAssertEqual(requestedPaths().count, 1,
                       "Replay must stop at the first transport failure, not hammer the rest")
    }

    // MARK: - 9. Retention on replay

    func test_expired_entry_is_dropped_without_a_network_attempt() async throws {
        let now = Date()
        let expiringStore = PendingSubmissionStore(defaults: defaults, now: { now })
        expiringStore.enqueue(PendingSubmission(
            kind: .promoCode,
            userId: Self.userId,
            value: "stale",
            enqueuedAt: now.addingTimeInterval(-(PendingSubmissionStore.retentionWindow + 1))
        ))
        let localAttribution = makeAttribution(pendingStore: expiringStore)

        configureSDK { _ in Self.json(Self.linkedSuccess) }
        await localAttribution._replayPendingSubmissions()

        XCTAssertTrue(bodies(forPath: APIPath.attributionPromoCode).isEmpty,
                      "An entry past the 30-day retention window must never reach the network")
        XCTAssertEqual(expiringStore.count, 0)
    }

    // MARK: - 10. fetchAttributionStatus fresh

    func test_fetch_status_unlinked_returns_fresh_values_and_caches_them() async throws {
        configureSDK { _ in Self.json(["linked": false]) }

        let status = try await attribution.fetchAttributionStatus(userId: Self.userId)

        XCTAssertFalse(status.isLinked)
        XCTAssertNil(status.influencerCode)
        XCTAssertNil(status.offeringId)
        XCTAssertFalse(status.fromCache, "A server response must never be flagged fromCache")
        XCTAssertEqual(statusCache.status(for: Self.userId)?.isLinked, false)
    }

    func test_fetch_status_linked_returns_code_and_offering() async throws {
        configureSDK { _ in Self.json(Self.linkedSuccess) }

        let status = try await attribution.fetchAttributionStatus(userId: Self.userId)

        XCTAssertTrue(status.isLinked)
        XCTAssertEqual(status.influencerCode, "elysia")
        XCTAssertEqual(status.offeringId, "inf_monthly")
        XCTAssertFalse(status.fromCache)
    }

    func test_fetch_status_with_missing_linked_key_throws_invalid_response() async {
        configureSDK { _ in Self.json(["influencer_code": "elysia"]) }

        do {
            _ = try await attribution.fetchAttributionStatus(userId: Self.userId)
            XCTFail("A status response without `linked` must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .invalidResponse)
        }
    }

    // MARK: - 11. Status cache fallback

    func test_transport_failure_serves_the_cached_status_flagged_from_cache() async throws {
        configureSDK { _ in Self.json(Self.linkedSuccess) }
        _ = try await attribution.fetchAttributionStatus(userId: Self.userId)

        SubmissionMockURLProtocol.reset()
        configureSDK { _ in .failure(URLError(.notConnectedToInternet)) }

        let status = try await attribution.fetchAttributionStatus(userId: Self.userId)

        XCTAssertTrue(status.isLinked)
        XCTAssertEqual(status.influencerCode, "elysia")
        XCTAssertEqual(status.offeringId, "inf_monthly")
        XCTAssertTrue(status.fromCache, "An offline read must be flagged so paywalls know it is stale")
    }

    func test_transport_failure_with_no_cached_status_throws_network() async {
        configureSDK { _ in .failure(URLError(.notConnectedToInternet)) }

        do {
            _ = try await attribution.fetchAttributionStatus(userId: "user-with-no-cache")
            XCTFail("With nothing cached, a transport failure must throw .network")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .network)
        }
    }

    func test_cached_status_is_not_served_to_a_different_user() async throws {
        configureSDK { _ in Self.json(Self.linkedSuccess) }
        _ = try await attribution.fetchAttributionStatus(userId: Self.userId)

        SubmissionMockURLProtocol.reset()
        configureSDK { _ in .failure(URLError(.notConnectedToInternet)) }

        do {
            _ = try await attribution.fetchAttributionStatus(userId: "a-different-user")
            XCTFail("User A's cached status must never satisfy user B's read")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .network)
        }
    }

    func test_terminal_error_is_thrown_even_when_a_cached_status_exists() async throws {
        configureSDK { _ in Self.json(Self.linkedSuccess) }
        _ = try await attribution.fetchAttributionStatus(userId: Self.userId)

        SubmissionMockURLProtocol.reset()
        configureSDK { _ in Self.errorEnvelope(code: "unknown_user", status: 404) }

        do {
            _ = try await attribution.fetchAttributionStatus(userId: Self.userId)
            XCTFail("A real 4xx must surface, not be masked by the cache")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .server(code: "unknown_user", message: "nope"))
        }
    }

    // MARK: - 12. submitOriginalTransactionId

    func test_transaction_submission_success_posts_once_and_queues_nothing() async throws {
        configureSDK { _ in Self.json(["ok": true]) }

        await attribution._submitOriginalTransactionId(userId: Self.userId,
                                                       originalTransactionId: "2000000123456789")

        XCTAssertEqual(bodies(forPath: APIPath.attributionTransaction).count, 1)
        XCTAssertEqual(pendingStore.count, 0)
    }

    func test_transaction_submission_transport_failure_enqueues_a_transaction_entry() async {
        configureSDK { _ in .failure(URLError(.networkConnectionLost)) }

        await attribution._submitOriginalTransactionId(userId: Self.userId,
                                                       originalTransactionId: "2000000123456789")

        let queued = pendingStore.all()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.kind, .transaction)
        XCTAssertEqual(queued.first?.value, "2000000123456789")
    }

    func test_transaction_submission_terminal_failure_drops_without_queueing() async {
        configureSDK { _ in Self.errorEnvelope(code: "unknown_transaction", status: 400) }

        // Must not throw — the method is fire-and-forget by contract.
        await attribution._submitOriginalTransactionId(userId: Self.userId,
                                                       originalTransactionId: "bogus")

        XCTAssertEqual(pendingStore.count, 0,
                       "A backend rejection is terminal and must never be queued")
    }

    func test_public_transaction_submission_returns_immediately_and_posts_in_background() async throws {
        configureSDK { _ in Self.json(["ok": true]) }

        attribution.submitOriginalTransactionId(userId: Self.userId,
                                                originalTransactionId: "2000000123456789")

        try await waitUntil { [weak self] in
            (self?.bodies(forPath: APIPath.attributionTransaction).count ?? 0) >= 1
        }

        XCTAssertEqual(bodies(forPath: APIPath.attributionTransaction).count, 1,
                       "The fire-and-forget overload must still post exactly once")
    }

    // MARK: - 13. notConfigured

    func test_submit_promo_code_before_configure_throws_not_configured_and_queues_nothing() async {
        Configuration.shared = nil

        do {
            _ = try await attribution.submitPromoCode(userId: Self.userId, code: "elysia")
            XCTFail("submitPromoCode before configure must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .notConfigured)
        }
        XCTAssertEqual(pendingStore.count, 0, "Misconfiguration is not a transient failure")
    }

    func test_fetch_status_before_configure_throws_not_configured() async {
        Configuration.shared = nil

        do {
            _ = try await attribution.fetchAttributionStatus(userId: Self.userId)
            XCTFail("fetchAttributionStatus before configure must throw")
        } catch {
            XCTAssertEqual(error as? HelmAttributionError, .notConfigured)
        }
    }

    func test_transaction_submission_before_configure_drops_without_queueing() async {
        Configuration.shared = nil

        await attribution._submitOriginalTransactionId(userId: Self.userId,
                                                       originalTransactionId: "2000000123456789")

        XCTAssertEqual(pendingStore.count, 0,
                       "A fire-and-forget call before configure is dropped, not queued")
        XCTAssertTrue(SubmissionMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: - 14. No internal error type leaks across the public boundary

    func test_every_thrown_error_is_a_helm_attribution_error() async {
        let outcomes: [SubmissionMockURLProtocol.Outcome] = [
            Self.errorEnvelope(code: "invalid_code"),
            Self.errorEnvelope(code: "code_inactive"),
            Self.errorEnvelope(code: "already_linked"),
            Self.errorEnvelope(code: "something_new", status: 422),
            Self.json(["unexpected": true]),
        ]

        for outcome in outcomes {
            SubmissionMockURLProtocol.reset()
            configureSDK { _ in outcome }
            do {
                _ = try await attribution.submitPromoCode(userId: Self.userId, code: "x")
                XCTFail("Expected a throw for outcome \(outcome)")
            } catch {
                XCTAssertTrue(error is HelmAttributionError,
                              "HelmError must never cross the public boundary; got \(type(of: error))")
                XCTAssertFalse(error is HelmError)
            }
        }
    }

    // MARK: - 15. reset() / clearIdentity() wipe the queue and cache

    func test_reset_clears_the_pending_queue_and_status_cache() throws {
        pendingStore.enqueue(PendingSubmission(kind: .promoCode, userId: Self.userId,
                                               value: "elysia", enqueuedAt: Date()))
        statusCache.store(CachedStatus(isLinked: true, influencerCode: "elysia",
                                       offeringId: "inf_monthly", fetchedAt: Date()),
                          for: Self.userId)

        attribution.reset()

        XCTAssertEqual(pendingStore.count, 0)
        XCTAssertNil(statusCache.status(for: Self.userId))
        XCTAssertFalse(store.hasChecked, "reset() must keep clearing the pre-existing attribution state")
    }

    func test_analytics_clear_identity_clears_the_pending_queue_and_status_cache() {
        pendingStore.enqueue(PendingSubmission(kind: .transaction, userId: Self.userId,
                                               value: "2000000123456789", enqueuedAt: Date()))
        statusCache.store(CachedStatus(isLinked: true, influencerCode: "elysia",
                                       offeringId: "inf_monthly", fetchedAt: Date()),
                          for: Self.userId)

        let analytics = Analytics(installationStore: InstallationStore(defaults: defaults, useKeychain: false),
                                  identityStore: IdentityStore(defaults: defaults),
                                  attributionStore: store,
                                  pendingSubmissionStore: pendingStore,
                                  statusCache: statusCache)

        analytics.clearIdentity()

        XCTAssertEqual(pendingStore.count, 0, "Logout must not leave the previous user's queued code behind")
        XCTAssertNil(statusCache.status(for: Self.userId))
    }
}

// MARK: - SubmissionMockURLProtocol

/// Test-only `URLProtocol` for the HELM-220 submission tests. Unlike the mock in
/// `AttributionTests`, its responder can also fail the request with a `URLError`
/// so transport-vs-terminal classification is exercised for real.
private final class SubmissionMockURLProtocol: URLProtocol {

    enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(URLError)
    }

    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> Outcome)?
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
