import XCTest
@testable import Helm

final class IdentityStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "IdentityStoreTests")!
        defaults.removePersistentDomain(forName: "IdentityStoreTests")
    }

    func testNilWhenNeverIdentified() {
        XCTAssertNil(IdentityStore(defaults: defaults).userHash)
    }

    func testRoundTrip() {
        let store = IdentityStore(defaults: defaults)
        store.store(userHash: String(repeating: "a", count: 32))
        XCTAssertEqual(store.userHash, String(repeating: "a", count: 32))
        XCTAssertEqual(IdentityStore(defaults: defaults).userHash,
                       String(repeating: "a", count: 32), "persists across instances")
    }

    func testClear() {
        let store = IdentityStore(defaults: defaults)
        store.store(userHash: String(repeating: "a", count: 32))
        store.clear()
        XCTAssertNil(store.userHash)
    }
}
