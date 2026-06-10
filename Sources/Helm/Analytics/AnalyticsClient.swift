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

    static func registrationBody(installationId: String, userHash: String) -> [String: Any] {
        [
            "installation_id": installationId,
            "platform": platformName(),
            "app_version": appVersion(),
            "os_version": osVersion(),
            "locale": localeIdentifier(),
            "timezone": TimeZone.current.identifier,
            "user_hash": userHash,
        ]
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
    static func registerInstallation(installationId: String, userHash: String) async throws {
        _ = try await HelmHTTPClient.post(
            path: "/api/v1/analytics/installations/",
            body: registrationBody(installationId: installationId, userHash: userHash)
        )
    }

    static func sendEvents(installationId: String, events: [AnalyticsEvent]) async throws {
        _ = try await HelmHTTPClient.post(
            path: "/api/v1/analytics/events/",
            body: eventsBody(installationId: installationId, events: events)
        )
    }
}
