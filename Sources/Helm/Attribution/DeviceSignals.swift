#if canImport(UIKit)
import UIKit
#endif
import Foundation

/// Collects device signals for probabilistic fingerprint matching.
internal struct DeviceSignals {
    let screenWidth: Int
    let screenHeight: Int
    let devicePixelRatio: Double
    let timezone: String
    let locale: String
    let osVersion: String

    /// Collect current device signals.
    @MainActor
    static func collect() -> DeviceSignals {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let dpr = Double(scale)
        #else
        let width = 0
        let height = 0
        let dpr = 1.0
        #endif

        let tz = TimeZone.current.identifier
        let loc = Locale.current.languageCode ?? "en"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVer = "\(v.majorVersion).\(v.minorVersion)"

        return DeviceSignals(
            screenWidth: width,
            screenHeight: height,
            devicePixelRatio: dpr,
            timezone: tz,
            locale: loc,
            osVersion: osVer
        )
    }

    /// Convert to dictionary for JSON serialization.
    func toDict() -> [String: Any] {
        return [
            "screen_width": screenWidth,
            "screen_height": screenHeight,
            "device_pixel_ratio": devicePixelRatio,
            "timezone": timezone,
            "locale": locale,
            "os_version": osVersion,
        ]
    }
}
