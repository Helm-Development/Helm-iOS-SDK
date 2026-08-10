import XCTest
@testable import Helm

/// HELM-220: persistence, dedupe, FIFO ordering, retention pruning, and the
/// hard cap on the offline attribution submission queue.
final class PendingSubmissionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Mutable clock so retention can be advanced without waiting 30 days.
    private var now: Date!
    private var store: PendingSubmissionStore!

    override func setUp() {
        super.setUp()
        suiteName = "dev.helmcode.helm.tests.pendingqueue.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        now = Date(timeIntervalSince1970: 1_800_000_000)
        store = PendingSubmissionStore(defaults: defaults, now: { [weak self] in self?.now ?? Date() })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        now = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func submission(kind: PendingSubmission.Kind = .promoCode,
                            userId: String = "user-1",
                            value: String = "ELYSIA",
                            at offset: TimeInterval = 0,
                            debug: Bool = false) -> PendingSubmission {
        PendingSubmission(kind: kind,
                          userId: userId,
                          value: value,
                          enqueuedAt: now.addingTimeInterval(offset),
                          debug: debug)
    }

    // MARK: - Persistence

    func test_initially_empty() {
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    func test_enqueued_entry_round_trips_through_userdefaults() {
        let entry = submission(kind: .transaction, userId: "rc-app-user-42", value: "2000000123456789")
        store.enqueue(entry)

        // A second store instance on the same suite must see the same entry —
        // proves the Codable round-trip, not just in-memory state.
        let reopened = PendingSubmissionStore(defaults: defaults, now: { [weak self] in self?.now ?? Date() })
        let all = reopened.all()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, entry, "Every field must survive the encode/decode round-trip")
    }

    func test_fifo_order_is_preserved() {
        store.enqueue(submission(value: "FIRST"))
        store.enqueue(submission(value: "SECOND"))
        store.enqueue(submission(value: "THIRD"))

        XCTAssertEqual(store.all().map(\.value), ["FIRST", "SECOND", "THIRD"])
    }

    func test_remove_deletes_exactly_one_entry() {
        let first = submission(value: "FIRST")
        let second = submission(value: "SECOND")
        store.enqueue(first)
        store.enqueue(second)

        store.remove(id: first.id)

        XCTAssertEqual(store.all().map(\.value), ["SECOND"])
    }

    func test_remove_unknown_id_is_a_noop() {
        store.enqueue(submission(value: "ONLY"))

        store.remove(id: "not-a-real-id")

        XCTAssertEqual(store.count, 1)
    }

    // MARK: - Dedupe

    func test_identical_submission_is_not_queued_twice() {
        store.enqueue(submission(userId: "user-1", value: "ELYSIA"))
        store.enqueue(submission(userId: "user-1", value: "ELYSIA"))

        XCTAssertEqual(store.count, 1, "Identical (kind, userId, value) must dedupe")
    }

    func test_same_value_with_different_kind_or_user_is_kept() {
        store.enqueue(submission(kind: .promoCode, userId: "user-1", value: "SHARED"))
        store.enqueue(submission(kind: .transaction, userId: "user-1", value: "SHARED"))
        store.enqueue(submission(kind: .promoCode, userId: "user-2", value: "SHARED"))

        XCTAssertEqual(store.count, 3, "Dedupe key is (kind, userId, value) — not value alone")
    }

    // MARK: - TAS-801 debug marker

    func test_debug_marker_round_trips_through_userdefaults() {
        let entry = submission(kind: .transaction, value: "2000000123456789", debug: true)
        store.enqueue(entry)

        let reopened = PendingSubmissionStore(defaults: defaults, now: { [weak self] in self?.now ?? Date() })
        let all = reopened.all()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.debug, true, "The sandbox marker must survive the Codable round-trip")
        XCTAssertEqual(all.first, entry)
    }

    /// A 1.3.0 queue on disk has no `debug` key. It must decode as **live** — and
    /// crucially it must decode at all: `readLocked()` discards the entire queue
    /// on a decode failure, so a throwing `init(from:)` would wipe every
    /// submission an offline device had accumulated before the upgrade.
    func test_legacy_entry_without_the_debug_key_decodes_as_live() throws {
        let legacy: [[String: Any]] = [[
            "id": "legacy-id",
            "kind": "promo_code",
            "userId": "user-1",
            "value": "ELYSIA",
            "enqueuedAt": now.timeIntervalSince1970,
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy),
                     forKey: "helm_attribution_pending_submissions")

        let all = store.all()

        XCTAssertEqual(all.count, 1, "A 1.3.0 queue must not be discarded on upgrade")
        XCTAssertEqual(all.first?.id, "legacy-id")
        XCTAssertEqual(all.first?.value, "ELYSIA")
        XCTAssertEqual(all.first?.debug, false, "A pre-flag entry replays as live data")
    }

    func test_same_submission_under_a_different_debug_marker_is_kept() {
        store.enqueue(submission(value: "SHARED", debug: false))
        store.enqueue(submission(value: "SHARED", debug: true))

        XCTAssertEqual(store.count, 2,
                       "Dedupe key includes `debug` — the same code in two environments is two submissions")
        XCTAssertEqual(store.all().map(\.debug), [false, true])
    }

    func test_identical_submission_including_debug_still_dedupes() {
        store.enqueue(submission(value: "SHARED", debug: true))
        store.enqueue(submission(value: "SHARED", debug: true))

        XCTAssertEqual(store.count, 1)
    }

    // MARK: - Retention (30 days)

    func test_entry_just_inside_retention_window_is_retained() {
        store.enqueue(submission())

        now = now.addingTimeInterval(PendingSubmissionStore.retentionWindow - 1)

        XCTAssertEqual(store.count, 1, "An entry one second short of 30 days must still replay")
    }

    func test_entry_past_retention_window_is_dropped() {
        store.enqueue(submission())

        now = now.addingTimeInterval(PendingSubmissionStore.retentionWindow + 1)

        XCTAssertTrue(store.all().isEmpty, "Entries older than 30 days must be pruned")
        XCTAssertNil(defaults.data(forKey: "helm_attribution_pending_submissions"),
                     "Pruning to empty must remove the key, not leave an empty array")
    }

    func test_pruning_keeps_live_entries_and_drops_expired_ones() {
        store.enqueue(submission(value: "OLD", at: 0))
        store.enqueue(submission(value: "NEW", at: PendingSubmissionStore.retentionWindow - 10))

        now = now.addingTimeInterval(PendingSubmissionStore.retentionWindow + 1)

        XCTAssertEqual(store.all().map(\.value), ["NEW"])
    }

    // MARK: - Cap

    func test_overflow_drops_the_oldest_entries() {
        for index in 0 ..< (PendingSubmissionStore.maxQueued + 1) {
            store.enqueue(submission(value: "CODE-\(index)"))
        }

        let all = store.all()
        XCTAssertEqual(all.count, PendingSubmissionStore.maxQueued)
        XCTAssertEqual(all.first?.value, "CODE-1", "The oldest entry must be the one dropped")
        XCTAssertEqual(all.last?.value, "CODE-\(PendingSubmissionStore.maxQueued)")
    }

    // MARK: - clearAll

    func test_clear_all_empties_the_queue_and_removes_the_key() {
        store.enqueue(submission(value: "A"))
        store.enqueue(submission(value: "B"))

        store.clearAll()

        XCTAssertEqual(store.count, 0)
        XCTAssertNil(defaults.data(forKey: "helm_attribution_pending_submissions"))
    }

    // MARK: - Corruption tolerance

    func test_corrupt_payload_is_discarded_rather_than_wedging_the_queue() {
        defaults.set(Data("not json".utf8), forKey: "helm_attribution_pending_submissions")

        XCTAssertTrue(store.all().isEmpty)

        store.enqueue(submission(value: "AFTER-CORRUPTION"))
        XCTAssertEqual(store.all().map(\.value), ["AFTER-CORRUPTION"])
    }
}
