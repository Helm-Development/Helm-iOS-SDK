import XCTest
@testable import Helm

final class AnalyticsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AnalyticsTests")!
        defaults.removePersistentDomain(forName: "AnalyticsTests")
        Configuration.shared = Configuration(publishableKey: "pk_test", baseURL: "https://example.invalid")
    }

    override func tearDown() {
        Configuration.shared = nil
        super.tearDown()
    }

    private func makeAnalytics() -> Analytics {
        Analytics(installationStore: InstallationStore(defaults: defaults, useKeychain: false),
                  identityStore: IdentityStore(defaults: defaults),
                  sessionManager: SessionManager(),
                  queue: EventQueue())
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

    func testHelmFacadeExposesAnalytics() {
        XCTAssertTrue(Helm.analytics === Analytics.shared)
    }
}
