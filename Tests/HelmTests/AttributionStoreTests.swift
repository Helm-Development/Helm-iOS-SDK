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

    // MARK: - HELM-184: Bounded retry budget

    func test_can_retry_true_on_fresh_install() {
        XCTAssertTrue(store.canRetry)
        XCTAssertEqual(store.attemptCount, 0)
    }

    func test_can_retry_flips_false_after_max_attempts() {
        for _ in 0 ..< AttributionStore.maxAttempts {
            store.recordFailedAttempt()
        }
        XCTAssertEqual(store.attemptCount, AttributionStore.maxAttempts)
        XCTAssertFalse(store.canRetry)
    }

    func test_can_retry_still_true_below_max_attempts() {
        store.recordFailedAttempt()
        store.recordFailedAttempt()
        XCTAssertEqual(store.attemptCount, 2)
        XCTAssertTrue(store.canRetry)
    }

    func test_reset_retry_budget_clears_attempts() {
        store.recordFailedAttempt()
        store.recordFailedAttempt()
        store.recordFailedAttempt()
        XCTAssertEqual(store.attemptCount, 3)

        store.resetRetryBudget()

        XCTAssertEqual(store.attemptCount, 0)
        XCTAssertTrue(store.canRetry)
    }

    /// Once five failures have stacked up, `canRetry` is false and a
    /// caller (Attribution._match) is expected to flip `hasChecked` to
    /// true. Verified end-to-end by `Attribution`-level tests.
    func test_record_failed_attempt_increments_counter() {
        XCTAssertEqual(store.attemptCount, 0)
        store.recordFailedAttempt()
        XCTAssertEqual(store.attemptCount, 1)
        store.recordFailedAttempt()
        XCTAssertEqual(store.attemptCount, 2)
    }

    // MARK: - HELM-189: clearAll resets every key

    func test_clear_all_removes_every_key() {
        store.storeMatch(attributionId: UUID().uuidString)
        store.markChecked()
        store.recordFailedAttempt()
        let originalDeviceId = store.deviceId

        store.clearAll()

        XCTAssertFalse(store.hasChecked)
        XCTAssertNil(store.attributionId)
        XCTAssertEqual(store.rawAttributionId, "")
        XCTAssertEqual(store.attemptCount, 0)
        XCTAssertTrue(store.canRetry)

        // Next read regenerates a fresh device id.
        let newDeviceId = store.deviceId
        XCTAssertNotEqual(newDeviceId, originalDeviceId)
    }

    // MARK: - HELM-185: Thread-safety stress test

    /// Verifies that concurrent first-launch reads of `deviceId` never race
    /// to write different UUIDs. Without the lock, two tasks can each see
    /// `nil` and produce distinct IDs, leaving whichever wrote last in
    /// UserDefaults while the other caller has already returned a stale value.
    func test_device_id_concurrent_first_launch_returns_same_id() async {
        // Drain any default-write that may have happened in setUp.
        defaults.removeObject(forKey: "helm_device_id")

        let concurrentReads = 64
        let ids = await withTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<concurrentReads {
                group.addTask { [store] in
                    return store!.deviceId
                }
            }
            var collected: [String] = []
            for await id in group {
                collected.append(id)
            }
            return collected
        }

        XCTAssertEqual(ids.count, concurrentReads)
        let unique = Set(ids)
        XCTAssertEqual(unique.count, 1,
                       "All concurrent deviceId reads must return the same UUID; got \(unique.count) distinct values")

        // The single ID must match what's persisted in UserDefaults.
        let persisted = defaults.string(forKey: "helm_device_id")
        XCTAssertNotNil(persisted)
        XCTAssertEqual(unique.first, persisted)
    }
}
