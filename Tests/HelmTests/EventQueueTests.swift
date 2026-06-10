import XCTest
@testable import Helm

final class EventQueueTests: XCTestCase {

    private func makeEvent(_ name: String = "tapped") -> AnalyticsEvent {
        AnalyticsEvent(eventName: name,
                       occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                       sessionId: "11111111-1111-1111-1111-111111111111",
                       properties: ["screen": "home"])
    }

    func testPayloadShapeMatchesIngestContract() {
        let payload = makeEvent().payload()
        XCTAssertEqual(payload["event_name"] as? String, "tapped")
        XCTAssertEqual(payload["session_id"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual((payload["properties"] as? [String: Any])?["screen"] as? String, "home")
        // occurred_at must be ISO8601 (Helm's parse_datetime requirement)
        let occurredAt = payload["occurred_at"] as? String ?? ""
        XCTAssertNotNil(ISO8601DateFormatter().date(from: occurredAt), "got: \(occurredAt)")
    }

    func testEnqueueSignalsFlushAtThreshold() {
        let queue = EventQueue()
        for i in 1..<EventQueue.flushThreshold {
            XCTAssertFalse(queue.enqueue(makeEvent("e\(i)")))
        }
        XCTAssertTrue(queue.enqueue(makeEvent("last")))
    }

    func testDrainEmptiesQueue() {
        let queue = EventQueue()
        _ = queue.enqueue(makeEvent())
        _ = queue.enqueue(makeEvent())
        XCTAssertEqual(queue.drain().count, 2)
        XCTAssertEqual(queue.count, 0)
    }

    func testCapDropsOldest() {
        let queue = EventQueue()
        for i in 0..<(EventQueue.maxQueued + 10) {
            _ = queue.enqueue(makeEvent("e\(i)"))
        }
        let drained = queue.drain()
        XCTAssertEqual(drained.count, EventQueue.maxQueued)
        XCTAssertEqual(drained.first?.eventName, "e10", "oldest 10 dropped")
    }

    func testRequeuePutsEventsBackInFrontWithoutExceedingCap() {
        let queue = EventQueue()
        _ = queue.enqueue(makeEvent("newer"))
        queue.requeue([makeEvent("failed")])
        let drained = queue.drain()
        XCTAssertEqual(drained.map(\.eventName), ["failed", "newer"])
    }

    func testRetriedFlagDefaultsFalse() {
        XCTAssertFalse(makeEvent().retried)
    }
}
