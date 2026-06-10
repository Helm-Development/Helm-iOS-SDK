import XCTest
@testable import Helm

final class SessionManagerTests: XCTestCase {

    func testNewSessionOnInit() {
        let manager = SessionManager()
        XCTAssertNotNil(UUID(uuidString: manager.sessionId))
        XCTAssertEqual(manager.sessionId, manager.sessionId.lowercased())
    }

    func testShortBackgroundKeepsSession() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let manager = SessionManager(backgroundTimeout: 300, now: { fakeNow })
        let original = manager.sessionId
        manager.appDidEnterBackground()
        fakeNow = fakeNow.addingTimeInterval(120) // 2 min < 5 min
        XCTAssertFalse(manager.appWillEnterForeground())
        XCTAssertEqual(manager.sessionId, original)
    }

    func testLongBackgroundRotatesSession() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let manager = SessionManager(backgroundTimeout: 300, now: { fakeNow })
        let original = manager.sessionId
        manager.appDidEnterBackground()
        fakeNow = fakeNow.addingTimeInterval(301) // > 5 min
        XCTAssertTrue(manager.appWillEnterForeground())
        XCTAssertNotEqual(manager.sessionId, original)
    }

    func testForegroundWithoutBackgroundIsNoop() {
        let manager = SessionManager()
        let original = manager.sessionId
        XCTAssertFalse(manager.appWillEnterForeground())
        XCTAssertEqual(manager.sessionId, original)
    }
}
