import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// HELM-336: where the Apple Ads attribution token comes from.
///
/// Hidden behind a protocol so tests never call the AdServices framework.
internal protocol AppleAdsTokenProviding: Sendable {

    /// A new AdServices attribution token.
    ///
    /// - Returns: the token, or `nil` when AdServices is not available on
    ///   this platform or OS version.
    /// - Throws: when AdServices cannot make a token right now (for example,
    ///   no network). The SDK tries again on the next launch.
    func attributionToken() throws -> String?
}

/// The real token, from `AAAttribution.attributionToken()` (iOS 14.3 and
/// macOS 11.1 and later). Call it off the main thread: it can block while
/// AdServices talks to Apple.
internal struct SystemAppleAdsTokenProvider: AppleAdsTokenProviding {

    func attributionToken() throws -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, macOS 11.1, *) {
            return try Self.adServicesToken()
        }
        #endif
        return nil
    }

    #if canImport(AdServices)
    @available(iOS 14.3, macOS 11.1, *)
    private static func adServicesToken() throws -> String {
        try AAAttribution.attributionToken()
    }
    #endif
}

/// Used by test-built `Attribution` instances that do not supply their own
/// provider. Reports that AdServices is not available.
internal struct UnavailableAppleAdsTokenProvider: AppleAdsTokenProviding {
    func attributionToken() throws -> String? { nil }
}
