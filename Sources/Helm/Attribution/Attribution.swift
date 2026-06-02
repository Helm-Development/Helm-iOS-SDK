import Foundation
import os

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "attribution")

/// Handles attribution matching and event tracking for Helm.
public final class Attribution: @unchecked Sendable {

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
        guard !store.hasChecked else {
            logger.info("match() skipped — already checked")
            return
        }

        do {
            let deviceId = store.deviceId
            let signals = await DeviceSignals.collect()

            logger.info("match() starting — device_id=\(deviceId, privacy: .public) signals=\(signals.screenWidth)x\(signals.screenHeight)")

            var body = signals.toDict()
            body["device_id"] = deviceId

            let response = try await HelmHTTPClient.post(
                path: "/attribution/match/",
                body: body
            )

            logger.info("match() response: \(response, privacy: .private)")

            if let matched = response["matched"] as? Bool, matched {
                let attributionId = response["attribution_id"] as? String ?? ""
                store.storeMatch(attributionId: attributionId)
                logger.info("match() SUCCESS — attribution_id=\(attributionId, privacy: .private)")
            } else {
                store.storeUnmatched()
                logger.info("match() no match found")
            }

            store.markChecked()
        } catch {
            logger.error("Attribution match failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Events

    /// Record an attribution event (fire-and-forget).
    ///
    /// - Parameters:
    ///   - eventType: The event name (e.g. "signup", "purchase").
    ///   - metadata: Optional key-value metadata attached to the event.
    public func increment(_ eventType: String, metadata: [String: Any]? = nil) {
        // Serialize metadata to JSON `Data` here so we cross the Task
        // boundary with a Sendable value. `[String: Any]` is not Sendable,
        // but `Data` is, and the caller's dictionary is treated as immutable
        // after this point.
        let metadataData: Data?
        if let metadata = metadata,
           let data = try? JSONSerialization.data(withJSONObject: metadata) {
            metadataData = data
        } else {
            metadataData = nil
        }

        Task {
            await _increment(eventType, metadataData: metadataData)
        }
    }

    private func _increment(_ eventType: String, metadataData: Data?) async {
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

            if let metadataData = metadataData,
               let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] {
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
