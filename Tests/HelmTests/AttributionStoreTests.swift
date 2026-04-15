import XCTest
@testable import Helm

final class AttributionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: AttributionStore!

    override func setUp() {
        super.setUp()
        let suiteName = "dev.helmcode.helm.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = AttributionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Tests

    func test_initially_not_checked() {
        XCTAssertFalse(store.hasChecked)
        XCTAssertNil(store.attributionId)
        XCTAssertEqual(store.rawAttributionId, "")
    }

    func test_store_match_sets_id_and_checked() {
        let testId = UUID().uuidString

        store.storeMatch(attributionId: testId)
        store.markChecked()

        XCTAssertTrue(store.hasChecked)
        XCTAssertEqual(store.attributionId, testId)
        XCTAssertEqual(store.rawAttributionId, testId)
    }

    func test_store_unmatched_sets_empty_and_checked() {
        store.storeUnmatched()
        store.markChecked()

        XCTAssertTrue(store.hasChecked)
        XCTAssertNil(store.attributionId, "attributionId should be nil when unmatched")
        XCTAssertEqual(store.rawAttributionId, "", "rawAttributionId should be empty string when unmatched")
    }

    func test_has_checked_persists() {
        XCTAssertFalse(store.hasChecked)

        store.markChecked()
        XCTAssertTrue(store.hasChecked)

        // Create a new store instance backed by the same UserDefaults suite
        let store2 = AttributionStore(defaults: defaults)
        XCTAssertTrue(store2.hasChecked, "hasChecked should persist across store instances")
    }

    func test_device_id_generated_once() {
        let firstId = store.deviceId
        XCTAssertFalse(firstId.isEmpty)

        let secondId = store.deviceId
        XCTAssertEqual(firstId, secondId, "deviceId should be stable across reads")

        // New store backed by same defaults should return the same ID
        let store2 = AttributionStore(defaults: defaults)
        XCTAssertEqual(store2.deviceId, firstId, "deviceId should persist across store instances")
    }
}
