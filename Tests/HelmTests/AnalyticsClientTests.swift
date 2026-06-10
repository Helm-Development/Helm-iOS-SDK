import XCTest
@testable import Helm

final class AnalyticsClientTests: XCTestCase {

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
