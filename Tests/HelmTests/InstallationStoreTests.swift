import XCTest
@testable import Helm

final class InstallationStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "InstallationStoreTests")!
        defaults.removePersistentDomain(forName: "InstallationStoreTests")
    }

    func testGeneratesLowercaseUUIDOnce() {
        let store = InstallationStore(defaults: defaults, useKeychain: false)
        let id = store.installationId
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(store.installationId, id, "second read returns the same id")
    }

    func testPersistsAcrossInstances() {
        let first = InstallationStore(defaults: defaults, useKeychain: false).installationId
        let second = InstallationStore(defaults: defaults, useKeychain: false).installationId
        XCTAssertEqual(first, second)
    }
}
