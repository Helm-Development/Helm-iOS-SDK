import XCTest
@testable import Helm

final class AnalyticsClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Configuration.shared = nil
    }

    override func tearDown() {
        Configuration.shared = nil
        super.tearDown()
    }

    func testRegistrationBodyIncludesRequiredFieldsAndHash() {
        let body = AnalyticsClient.registrationBody(
            installationId: "bbbb1111-2222-3333-4444-bbbb11112222",
            userHash: String(repeating: "a", count: 32)
        )
        XCTAssertEqual(body["installation_id"] as? String, "bbbb1111-2222-3333-4444-bbbb11112222")
        XCTAssertEqual(body["user_hash"] as? String, String(repeating: "a", count: 32))
        for key in ["platform", "app_version", "os_version", "locale", "timezone"] {
            XCTAssertFalse((body[key] as? String ?? "").isEmpty, "\(key) must be non-empty")
        }
        // locale must be hyphenated (en-US), matching what Helm stores
        XCTAssertFalse((body["locale"] as? String ?? "").contains("_"))
    }

    func testRegistrationBodyIncludesAttributionTokenWhenProvided() {
        let body = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash",
            attributionToken: "attr-abc-123"
        )
        XCTAssertEqual(body["attribution_token"] as? String, "attr-abc-123",
                       "attribution_token must appear in the body when a non-empty token is passed")
    }

    func testRegistrationBodyOmitsAttributionTokenWhenNilOrEmpty() {
        let bodyNil = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash",
            attributionToken: nil
        )
        XCTAssertNil(bodyNil["attribution_token"],
                     "attribution_token must be absent when nil")

        let bodyEmpty = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash",
            attributionToken: ""
        )
        XCTAssertNil(bodyEmpty["attribution_token"],
                     "attribution_token must be absent when empty string")
    }

    // MARK: - Debug marker (HELM-237)

    func testRegistrationBodyMarksADebugBuild() {
        let body = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash",
            debug: true
        )
        XCTAssertEqual(body["debug"] as? Bool, true,
                       "a debug build must register as debug so Helm leaves it out of active-user counts")
    }

    func testRegistrationBodyDefaultsToLive() {
        let body = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash"
        )
        XCTAssertEqual(body["debug"] as? Bool, false,
                       "an unconfigured build counts as a real user, matching the server default")
    }

    // MARK: - Environment (HELM-241)

    func testRegistrationBodyCarriesTheConfiguredEnvironment() {
        let body = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash",
            environment: "staging"
        )
        XCTAssertEqual(body["environment"] as? String, "staging",
                       "registration must report the environment the build talks to")
    }

    func testRegistrationBodyDefaultsToProduction() {
        let body = AnalyticsClient.registrationBody(
            installationId: "iid",
            userHash: "hash"
        )
        XCTAssertEqual(body["environment"] as? String, "production",
                       "a build that never sets environment registers as production")
    }

    func testEventPayloadCarriesItsOwnDebugAndEnvironment() {
        let event = AnalyticsEvent(eventName: "tapped",
                                   occurredAt: Date(),
                                   sessionId: "s",
                                   properties: [:],
                                   debug: true,
                                   environment: "staging")
        let payload = event.payload()
        XCTAssertEqual(payload["debug"] as? Bool, true)
        XCTAssertEqual(payload["environment"] as? String, "staging")
    }

    func testEventPayloadDefaultsToLiveProduction() {
        let event = AnalyticsEvent(eventName: "tapped",
                                   occurredAt: Date(),
                                   sessionId: "s",
                                   properties: [:])
        let payload = event.payload()
        XCTAssertEqual(payload["debug"] as? Bool, false)
        XCTAssertEqual(payload["environment"] as? String, "production")
    }

    /// HELM-241: an event holds the values in force when it was created. A
    /// reconfiguration between creation and flush must not rewrite them.
    func testEventKeepsTheValuesItWasCreatedWithAcrossAReconfiguration() {
        Configuration.shared = Configuration(publishableKey: "pk_test",
                                             baseURL: "https://example.invalid",
                                             debug: true,
                                             environment: "staging")
        let event = AnalyticsEvent(eventName: "tapped",
                                   occurredAt: Date(),
                                   sessionId: "s",
                                   properties: [:],
                                   debug: Configuration.shared?.debug ?? false,
                                   environment: Configuration.shared?.environment ?? "production")

        Helm.configure(publishableKey: "pk_test",
                       baseURL: "https://example.invalid",
                       debug: false,
                       environment: "production",
                       session: URLSession(configuration: .ephemeral))

        let payload = event.payload()
        XCTAssertEqual(payload["debug"] as? Bool, true,
                       "the event was created by a debug build and must stay debug")
        XCTAssertEqual(payload["environment"] as? String, "staging",
                       "the event was created on staging and must stay staging")
    }

    func testEventsBodyShape() {
        let event = AnalyticsEvent(eventName: "tapped",
                                   occurredAt: Date(),
                                   sessionId: "s",
                                   properties: [:])
        let body = AnalyticsClient.eventsBody(installationId: "iid", events: [event])
        XCTAssertEqual(body["installation_id"] as? String, "iid")
        let events = body["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["event_name"] as? String, "tapped")
    }
}
