import XCTest
@testable import Helm

/// Integration tests for the `Logging` class — lifecycle, enqueue, flush,
/// network contract (header + path), no-op without token, batch threshold.
final class LoggingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Configuration.shared = Configuration(publishableKey: "pk_test",
                                             baseURL: "https://example.invalid")
        LoggingMockURLProtocol.reset()
    }

    override func tearDown() {
        Configuration.shared = nil
        LoggingMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build a `Logging` instance with an isolated `LogQueue`.
    private func makeLogging(queue: LogQueue = LogQueue()) -> Logging {
        Logging(queue: queue)
    }

    /// Configure `Helm` with a session that routes requests through
    /// `LoggingMockURLProtocol` and returns a canned 200 JSON response.
    private func configureWithMockSession() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoggingMockURLProtocol.self]
        let session = URLSession(configuration: config)
        LoggingMockURLProtocol.responder = { request in
            let body = try! JSONSerialization.data(withJSONObject: ["ok": true])
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }
        Helm.configure(publishableKey: "pk_test",
                       baseURL: "https://example.invalid",
                       session: session)
    }

    /// Read the request body from a captured `URLRequest` (supports httpBodyStream).
    private func bodyFromRequest(_ request: URLRequest) -> [String: Any]? {
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: 1024)
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

    // MARK: - No-op when no ingest token

    func testLogIsNoopWithoutIngestToken() {
        let logging = makeLogging()
        // No configure() call — no ingest token.
        logging.log("should be dropped", level: .info)
        XCTAssertEqual(logging.queuedLogCount, 0,
                       "log() must not enqueue when no ingest token is set")
    }

    func testStartIsNoopWithoutIngestToken() {
        let logging = makeLogging()
        // start() without a token must not crash.
        logging.start()
        logging.log("ignored")
        XCTAssertEqual(logging.queuedLogCount, 0)
    }

    func testEmptyIngestTokenIsNoop() {
        let logging = makeLogging()
        logging.configure(ingestToken: "", environment: "preview", serviceName: "App")
        logging.log("ignored")
        XCTAssertEqual(logging.queuedLogCount, 0,
                       "Empty ingest token must be treated as no token")
    }

    // MARK: - Enqueue

    func testLogEnqueuesWhenTokenIsSet() {
        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_test", environment: "preview", serviceName: "App")
        logging.log("hello")
        XCTAssertEqual(logging.queuedLogCount, 1)
    }

    func testMultipleLogsEnqueue() {
        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_test", environment: "preview", serviceName: "App")
        logging.log("one")
        logging.log("two", level: .warn)
        logging.log("three", level: .error, attributes: ["k": "v"])
        XCTAssertEqual(logging.queuedLogCount, 3)
    }

    // MARK: - Flush posts to correct path with hlit_ bearer

    func testFlushPostsToLogsPathWithIngestTokenBearer() async throws {
        configureWithMockSession()
        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_abc123",
                          environment: "preview",
                          serviceName: "TestApp")
        logging.log("flush me")
        XCTAssertEqual(logging.queuedLogCount, 1)

        await logging.flushNow()

        XCTAssertEqual(logging.queuedLogCount, 0, "Queue must be empty after flush")
        XCTAssertEqual(LoggingMockURLProtocol.receivedRequests.count, 1,
                       "Exactly one POST must have been made")

        let request = LoggingMockURLProtocol.receivedRequests[0]

        // Assert path ends with /api/v1/logs (no trailing slash).
        let urlString = request.url?.absoluteString ?? ""
        XCTAssertTrue(urlString.hasSuffix("/api/v1/logs"),
                      "Must POST to /api/v1/logs (no trailing slash), got: \(urlString)")

        // Assert Authorization header uses the hlit_ token, NOT the publishable key.
        let auth = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer hlit_abc123",
                       "Authorization must use the ingest token, got: \(auth ?? "nil")")
    }

    func testFlushSendsOTLPEnvelopeWithCorrectShape() async throws {
        configureWithMockSession()
        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_x",
                          environment: "staging",
                          serviceName: "MyService")
        logging.log("test log", level: .warn, attributes: ["env": "ci"])

        await logging.flushNow()

        let request = LoggingMockURLProtocol.receivedRequests.first!
        let envelope = bodyFromRequest(request)
        XCTAssertNotNil(envelope, "Request body must be parseable JSON")

        let resourceLogs = envelope?["resourceLogs"] as? [[String: Any]]
        XCTAssertNotNil(resourceLogs, "resourceLogs key must exist")

        let resource = resourceLogs?[0]["resource"] as? [String: Any]
        let attrs = resource?["attributes"] as? [[String: Any]]
        let attrMap = keyedAttributes(from: attrs ?? [])
        XCTAssertEqual(attrMap["helm.environment"], "staging")
        XCTAssertEqual(attrMap["service.name"], "MyService")

        let scopeLogs = resourceLogs?[0]["scopeLogs"] as? [[String: Any]]
        let records = scopeLogs?[0]["logRecords"] as? [[String: Any]]
        XCTAssertEqual(records?.count, 1)

        let record = records![0]
        // timeUnixNano must be a string.
        XCTAssertNotNil(record["timeUnixNano"] as? String,
                        "timeUnixNano must be a string")
        XCTAssertFalse((record["timeUnixNano"] as! String).isEmpty,
                       "timeUnixNano must not be empty")

        XCTAssertEqual(record["severityNumber"] as? Int, 13)  // warn
        XCTAssertEqual(record["severityText"] as? String, "WARN")

        let body = record["body"] as? [String: Any]
        XCTAssertEqual(body?["stringValue"] as? String, "test log")

        let recordAttrs = record["attributes"] as? [[String: Any]]
        let recordAttrMap = keyedAttributes(from: recordAttrs ?? [])
        XCTAssertEqual(recordAttrMap["env"], "ci")
    }

    func testFlushWithNoEntriesDoesNotPost() async throws {
        configureWithMockSession()
        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_x", environment: "preview", serviceName: "App")

        await logging.flushNow()

        XCTAssertEqual(LoggingMockURLProtocol.receivedRequests.count, 0,
                       "No POST when the queue is empty")
    }

    // MARK: - Batch threshold triggers flush

    func testBatchThresholdTriggersAutoFlush() async throws {
        configureWithMockSession()
        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_batch",
                          environment: "preview",
                          serviceName: "App")

        // Log flushThreshold - 1 entries without triggering a flush.
        for i in 0..<(LogQueue.flushThreshold - 1) {
            logging.log("msg \(i)")
        }
        XCTAssertEqual(logging.queuedLogCount, LogQueue.flushThreshold - 1,
                       "Should not have auto-flushed yet")
        XCTAssertEqual(LoggingMockURLProtocol.receivedRequests.count, 0)

        // The threshold-th entry triggers an automatic flush via `flush()`.
        // Since flush() spawns a Task, wait briefly for the round-trip.
        logging.log("threshold entry")

        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
            if !LoggingMockURLProtocol.receivedRequests.isEmpty { break }
        }

        XCTAssertGreaterThan(LoggingMockURLProtocol.receivedRequests.count, 0,
                             "Auto-flush must have fired a POST when flushThreshold was reached")
    }

    // MARK: - Requeue on 429 / 5xx (retried-once semantics)

    func testRequeueOn429() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoggingMockURLProtocol.self]
        let session = URLSession(configuration: config)
        Helm.configure(publishableKey: "pk_test",
                       baseURL: "https://example.invalid",
                       session: session)
        LoggingMockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 429,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, Data())
        }

        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_x", environment: "preview", serviceName: "App")
        logging.log("will be requeued")

        await logging.flushNow()

        XCTAssertEqual(logging.queuedLogCount, 1,
                       "Entry must be requeued after a 429")
    }

    func testDropAfterSecondFailure() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoggingMockURLProtocol.self]
        let session = URLSession(configuration: config)
        Helm.configure(publishableKey: "pk_test",
                       baseURL: "https://example.invalid",
                       session: session)
        LoggingMockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 500,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, Data())
        }

        let logging = makeLogging()
        logging.configure(ingestToken: "hlit_x", environment: "preview", serviceName: "App")
        logging.log("retry once")

        // First flush — entry requeued with retried=true.
        await logging.flushNow()
        XCTAssertEqual(logging.queuedLogCount, 1, "Must be requeued after first 500")

        // Second flush — entry already has retried=true → must be dropped.
        await logging.flushNow()
        XCTAssertEqual(logging.queuedLogCount, 0, "Must be dropped after second failure")
    }

    // MARK: - Helm facade accessor

    func testHelmFacadeExposesLogging() {
        XCTAssertTrue(Helm.logging === Logging.shared)
    }

    // MARK: - Helpers

    private func keyedAttributes(from attrs: [[String: Any]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: attrs.compactMap { dict -> (String, String)? in
            guard let key = dict["key"] as? String,
                  let val = (dict["value"] as? [String: Any])?["stringValue"] as? String
            else { return nil }
            return (key, val)
        })
    }
}

// MARK: - LoggingMockURLProtocol

/// Test-only `URLProtocol` for `LoggingTests`. Keeps logging test state isolated
/// from `MockURLProtocol` (used in `HelmHTTPClientTests`) and
/// `AnalyticsMockURLProtocol` (used in `AnalyticsTests`).
private final class LoggingMockURLProtocol: URLProtocol {

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
