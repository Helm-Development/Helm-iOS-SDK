import XCTest
@testable import Helm

final class DeviceSignalsTests: XCTestCase {

    func test_collect_returns_all_fields() async {
        let signals = await DeviceSignals.collect()
        // On macOS test runner, screen dimensions may be 0 (no UIKit)
        // but timezone, locale, osVersion should always be non-empty
        XCTAssertFalse(signals.timezone.isEmpty)
        XCTAssertFalse(signals.locale.isEmpty)
        XCTAssertFalse(signals.osVersion.isEmpty)
    }

    func test_to_dict_has_expected_keys() async {
        let signals = await DeviceSignals.collect()
        let dict = signals.toDict()
        XCTAssertNotNil(dict["screen_width"] as? Int)
        XCTAssertNotNil(dict["screen_height"] as? Int)
        XCTAssertNotNil(dict["device_pixel_ratio"] as? Double)
        XCTAssertNotNil(dict["timezone"] as? String)
        XCTAssertNotNil(dict["locale"] as? String)
        XCTAssertNotNil(dict["os_version"] as? String)
    }
}
