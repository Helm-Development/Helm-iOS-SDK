import Foundation
import os

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "attribution")

/// Handles attribution matching and event tracking for Helm.
public final class Attribution {

    internal static let shared = Attribution()

    private let store = AttributionStore()

    private init() {}

    // MARK: - Match

    /// Attempt to match the current device to an attribution source.
    ///
    /// This method returns immediately and performs work in the background.
    /// It is safe to call on every app launch -- if a match check has already
    /// been performed, subsequent calls are no-ops.
    public func match() {
        Task {
            await _match()
        }
    }

    private func _match() async {
        guard !store.hasChecked else { return }

        do {
            let ip = try await IPResolver.fetchPublicIP()

            let deviceId = store.deviceId

            let body: [String: Any] = [
                "ip": ip,
                "user_agent": "Helm-iOS-SDK/1.0",
                "device_id": deviceId
            ]

            let response = try await HelmHTTPClient.post(
                path: "/attribution/match/",
                body: body
            )

            if let matched = response["matched"] as? Bool, matched {
                let attributionId = response["attribution_id"] as? String ?? ""
                store.storeMatch(attributionId: attributionId)
            } else {
                store.storeUnmatched()
            }

            store.markChecked()
        } catch {
            logger.error("Attribution match failed: \(error.localizedDescription, privacy: .public)")
            // Do NOT mark as checked so we retry on next launch.
        }
    }

    // MARK: - Events

    /// Record an attribution event (fire-and-forget).
    ///
    /// - Parameters:
    ///   - eventType: The event name (e.g. "signup", "purchase").
    ///   - metadata: Optional key-value metadata attached to the event.
    public func increment(_ eventType: String, metadata: [String: Any]? = nil) {
        Task {
            await _increment(eventType, metadata: metadata)
        }
    }

    private func _increment(_ eventType: String, metadata: [String: Any]?) async {
        do {
            let rawId = store.rawAttributionId

            var body: [String: Any] = [
                "event_type": eventType
            ]

            // Send null when no attribution, otherwise send the stored ID.
            if rawId.isEmpty {
                body["attribution_id"] = NSNull()
            } else {
                body["attribution_id"] = rawId
            }

            if let metadata = metadata {
                body["metadata"] = metadata
            }

            _ = try await HelmHTTPClient.post(
                path: "/attribution/event/",
                body: body
            )
        } catch {
            logger.error("Attribution increment failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Authenticated Events

    // TODO: incrementAuthenticated — not implemented in v1.
    // This will allow sending events tied to an authenticated user identity
    // (e.g. after login) in addition to the device-level attribution.
}
