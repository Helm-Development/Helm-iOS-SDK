import XCTest
@testable import Helm

final class HelmHTTPClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure no configuration is set so we can test the notConfigured path.
        Configuration.shared = nil
    }

    override func tearDown() {
        Configuration.shared = nil
        super.tearDown()
    }

    func test_post_throws_not_configured_when_no_configuration() async {
        do {
            _ = try await HelmHTTPClient.post(path: "/test/", body: [:])
            XCTFail("Expected HelmError.notConfigured to be thrown")
        } catch let error as HelmError {
            switch error {
            case .notConfigured:
                break // expected
            default:
                XCTFail("Expected .notConfigured but got \(error)")
            }
        } catch {
            XCTFail("Expected HelmError but got \(error)")
        }
    }
}
