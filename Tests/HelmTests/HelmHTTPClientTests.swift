import XCTest
@testable import Helm

final class HelmHTTPClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure no configuration is set so we can test the notConfigured path.
        Configuration.shared = nil
        MockURLProtocol.reset()
    }

    override func tearDown() {
        Configuration.shared = nil
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_post_throws_not_configured_when_no_configuration() async {
        do {
            _ = try await HelmHTTPClient.post(path: "/test/", body: [:])
            XCTFail("Expected HelmError.notConfigured to be thrown")
        } catch let error as HelmError {
            switch error {
            case .notConfigured:
                break // expected
            default:
                XCTFail("Expected .notConfigured but got \(error)")
            }
        } catch {
            XCTFail("Expected HelmError but got \(error)")
        }
    }

    // MARK: - HELM-188: Encoding failure surfaces as HelmError.encodingFailed

    /// `JSONSerialization` rejects non-finite floats. Previously this was
    /// silently swallowed by `try?` and the request was sent with an empty
    /// body. The client must now propagate the failure as
    /// `HelmError.encodingFailed`.
    func test_post_throws_encoding_failed_for_invalid_json_body() async {
        Configuration.shared = Configuration(
            publishableKey: "test-key",
            baseURL: "https://example.invalid"
        )

        let unencodableBody: [String: Any] = [
            "bad_value": Double.infinity
        ]

        do {
            _ = try await HelmHTTPClient.post(path: "/test/", body: unencodableBody)
            XCTFail("Expected HelmError.encodingFailed to be thrown")
        } catch let error as HelmError {
            switch error {
            case .encodingFailed:
                break // expected
            default:
                XCTFail("Expected .encodingFailed but got \(error)")
            }
        } catch {
            XCTFail("Expected HelmError but got \(error)")
        }
    }

    // MARK: - HELM-183: Final URL matches the backend route

    /// With the canonical `baseURL: "https://helmcode.dev"`, posting to the
    /// attribution-match path must produce a fully-qualified URL ending in
    /// `/api/client/v1/attribution/match/`. The SDK is responsible for
    /// prepending the `/api/client/v1` prefix; integrators pass only the host.
    func test_post_url_ends_with_api_client_v1_attribution_match() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"matched":false}"#.data(using: .utf8)!)
        }

        Helm.configure(
            publishableKey: "test-key",
            baseURL: "https://helmcode.dev",
            session: session
        )

        _ = try await HelmHTTPClient.post(
            path: "/api/client/v1/attribution/match/",
            body: ["device_id": "abc"]
        )

        XCTAssertEqual(MockURLProtocol.receivedRequests.count, 1)
        let urlString = MockURLProtocol.receivedRequests[0].url?.absoluteString ?? ""
        XCTAssertTrue(
            urlString.hasSuffix("/api/client/v1/attribution/match/"),
            "Final URL must end with /api/client/v1/attribution/match/, got: \(urlString)"
        )
        XCTAssertEqual(urlString, "https://helmcode.dev/api/client/v1/attribution/match/")
    }

    // MARK: - HELM-191: Injected URLSession is used for requests

    /// A `URLSession` configured with a custom `URLProtocol` subclass and
    /// injected via `Helm.configure(session:)` must be the session that
    /// actually performs the request.
    func test_post_uses_injected_url_session() async throws {
        // Build a URLSession that routes every request through MockURLProtocol.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let responseBody = #"{"ok":true}"#.data(using: .utf8)!
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }

        Helm.configure(
            publishableKey: "test-key",
            baseURL: "https://example.invalid",
            session: session
        )

        let json = try await HelmHTTPClient.post(path: "/test/", body: ["a": 1])

        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(MockURLProtocol.receivedRequests.count, 1,
                       "The injected session's URLProtocol must have been invoked exactly once")

        let received = MockURLProtocol.receivedRequests[0]
        XCTAssertEqual(received.url?.absoluteString, "https://example.invalid/test/")
        XCTAssertEqual(received.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(received.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}

// MARK: - MockURLProtocol

/// Test-only URLProtocol that captures requests and returns canned responses.
private final class MockURLProtocol: URLProtocol {

    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    static func reset() {
        receivedRequests = []
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.receivedRequests.append(request)

        guard let responder = MockURLProtocol.responder else {
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
