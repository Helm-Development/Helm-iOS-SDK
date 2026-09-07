import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds and sends analytics payloads to Helm via `HelmHTTPClient`.
internal enum AnalyticsClient {

    // MARK: - Device facts

    static func platformName() -> String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }

    static func localeIdentifier() -> String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    // MARK: - Payload builders (pure, unit-tested)

    static func registrationBody(installationId: String,
                                 userHash: String,
                                 attributionToken: String? = nil,
                                 debug: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [
            "installation_id": installationId,
            "platform": platformName(),
            "app_version": appVersion(),
            "os_version": osVersion(),
            "locale": localeIdentifier(),
            "timezone": TimeZone.current.identifier,
            "user_hash": userHash,
            // HELM-237: the same `debug` wire field the attribution endpoints
            // take (TAS-801). Helm leaves activity from a debug build out of its
            // active-user counts. Always sent, including when false, so a device
            // that moves from a debug build to a shipped one counts as live again.
            "debug": debug,
        ]
        // Include attribution_token only when non-empty; mirrors Android AnalyticsClient.kt:58.
        if let token = attributionToken, !token.isEmpty {
            dict["attribution_token"] = token
        }
        return dict
    }

    static func eventsBody(installationId: String, events: [AnalyticsEvent]) -> [String: Any] {
        [
            "installation_id": installationId,
            "events": events.map { $0.payload() },
        ]
    }

    // MARK: - Network

    /// Register (or re-register) this installation. `userHash` may be "" when anonymous;
    /// the SDK always echoes its stored hash so identity never regresses (spec §5).
    /// `attributionToken` is forwarded as `attribution_token` when non-empty so the
    /// server can close the Attribution → Installation pairing via `_close_attribution_pairing`.
    /// The configured `debug` flag rides along so Helm can tell a developer's build
    /// apart from a real user (HELM-237).
    static func registerInstallation(installationId: String, userHash: String, attributionToken: String? = nil) async throws {
        _ = try await HelmHTTPClient.post(
            path: APIPath.analyticsInstallations,
            body: registrationBody(installationId: installationId,
                                   userHash: userHash,
                                   attributionToken: attributionToken,
                                   debug: Configuration.shared?.debug ?? false)
        )
    }

    static func sendEvents(installationId: String, events: [AnalyticsEvent]) async throws {
        _ = try await HelmHTTPClient.post(
            path: APIPath.analyticsEvents,
            body: eventsBody(installationId: installationId, events: events)
        )
    }
}
