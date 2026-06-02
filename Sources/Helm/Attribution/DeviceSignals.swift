#if canImport(UIKit)
import UIKit
#endif
import Foundation

/// Collects device signals for probabilistic fingerprint matching.
internal struct DeviceSignals: Sendable {
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

        // Match navigator.language format: "en-US" not just "en"
        let langCode = Locale.current.languageCode ?? "en"
        let regionCode = Locale.current.regionCode ?? ""
        let loc = regionCode.isEmpty ? langCode : "\(langCode)-\(regionCode)"

        // Safari UA reports the marketing iOS version (e.g. "18.7"), not the
        // internal Darwin version (e.g. "26.4"). operatingSystemVersionString
        // contains the marketing version: "Version 18.7 (Build 22H123)"
        let versionStr = ProcessInfo.processInfo.operatingSystemVersionString
        let osVer: String
        if let range = versionStr.range(of: #"(\d+\.\d+)"#, options: .regularExpression) {
            osVer = String(versionStr[range])
        } else {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            osVer = "\(v.majorVersion).\(v.minorVersion)"
        }

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
