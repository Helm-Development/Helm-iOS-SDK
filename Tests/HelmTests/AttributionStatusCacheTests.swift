import XCTest
@testable import Helm

/// HELM-220: per-userId isolation, overwrite semantics, eviction, and wipe of
/// the offline attribution status cache.
final class AttributionStatusCacheTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cache: AttributionStatusCache!

    override func setUp() {
        super.setUp()
        suiteName = "dev.helmcode.helm.tests.statuscache.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        cache = AttributionStatusCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        cache = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func status(isLinked: Bool = true,
                        code: String? = "elysia",
                        offering: String? = "inf_monthly",
                        fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CachedStatus {
        CachedStatus(isLinked: isLinked, influencerCode: code, offeringId: offering, fetchedAt: fetchedAt)
    }

    // MARK: - Round-trip

    func test_initially_empty() {
        XCTAssertNil(cache.status(for: "user-1"))
        XCTAssertEqual(cache.count, 0)
    }

    func test_store_and_read_round_trips_through_userdefaults() {
        let value = status()
        cache.store(value, for: "user-1")

        // Second instance on the same suite proves the Codable round-trip.
        let reopened = AttributionStatusCache(defaults: defaults)
        XCTAssertEqual(reopened.status(for: "user-1"), value)
    }

    func test_nil_optionals_round_trip() {
        let value = status(isLinked: false, code: nil, offering: nil)
        cache.store(value, for: "user-1")

        XCTAssertEqual(cache.status(for: "user-1"), value)
    }

    // MARK: - Per-user isolation

    func test_one_users_status_is_invisible_to_another() {
        cache.store(status(code: "elysia", offering: "inf_monthly"), for: "user-a")

        XCTAssertNil(cache.status(for: "user-b"),
                     "A device that switches accounts must never serve user A's offering to user B")
        XCTAssertEqual(cache.status(for: "user-a")?.influencerCode, "elysia")
    }

    func test_multiple_users_are_stored_independently() {
        cache.store(status(code: "elysia"), for: "user-a")
        cache.store(status(code: "marcus"), for: "user-b")

        XCTAssertEqual(cache.status(for: "user-a")?.influencerCode, "elysia")
        XCTAssertEqual(cache.status(for: "user-b")?.influencerCode, "marcus")
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: - Overwrite

    func test_storing_again_overwrites_in_place() {
        cache.store(status(isLinked: false, code: nil, offering: nil), for: "user-a")
        cache.store(status(isLinked: true, code: "elysia", offering: "inf_monthly"), for: "user-a")

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.status(for: "user-a")?.isLinked, true)
        XCTAssertEqual(cache.status(for: "user-a")?.offeringId, "inf_monthly")
    }

    // MARK: - Eviction

    func test_beyond_cap_the_oldest_entry_is_evicted() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0 ... AttributionStatusCache.maxEntries {
            cache.store(status(code: "code-\(index)",
                               fetchedAt: base.addingTimeInterval(TimeInterval(index))),
                        for: "user-\(index)")
        }

        XCTAssertEqual(cache.count, AttributionStatusCache.maxEntries)
        XCTAssertNil(cache.status(for: "user-0"), "Oldest fetchedAt must be evicted first")
        XCTAssertNotNil(cache.status(for: "user-\(AttributionStatusCache.maxEntries)"),
                        "The newest entry must survive eviction")
    }

    // MARK: - clearAll

    func test_clear_all_wipes_every_user() {
        cache.store(status(), for: "user-a")
        cache.store(status(), for: "user-b")

        cache.clearAll()

        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.status(for: "user-a"))
        XCTAssertNil(defaults.data(forKey: "helm_attribution_status_cache"))
    }

    // MARK: - Corruption tolerance

    func test_corrupt_payload_is_discarded_rather_than_wedging_the_cache() {
        defaults.set(Data("not json".utf8), forKey: "helm_attribution_status_cache")

        XCTAssertNil(cache.status(for: "user-a"))

        cache.store(status(code: "after-corruption"), for: "user-a")
        XCTAssertEqual(cache.status(for: "user-a")?.influencerCode, "after-corruption")
    }
}
