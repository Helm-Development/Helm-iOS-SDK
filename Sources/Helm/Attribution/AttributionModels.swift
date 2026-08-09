import Foundation

// MARK: - Public result types (HELM-220)

/// Outcome of a promo-code submission.
public enum PromoCodeResult: Equatable, Sendable {

    /// The code was linked to the user server-side.
    ///
    /// - `influencerCode`: the canonical code the server linked (the server
    ///   normalizes case, so this may differ from the string you submitted).
    /// - `offeringId`: the RevenueCat offering identifier to present on the
    ///   paywall, when the influencer's campaign specifies one.
    case linked(influencerCode: String, offeringId: String?)

    /// The submission could not reach the server (offline, timeout, 5xx) and
    /// was persisted to the on-device queue instead. It replays automatically
    /// on the next `Helm.configure(...)`, app foreground, or attribution call
    /// for up to 30 days.
    ///
    /// Show the user something like "your code will be applied as soon as
    /// you're back online" — do not treat this as a failure.
    case queued
}

/// The user's influencer-attribution status, used to pick which paywall
/// offering to present.
public struct AttributionStatus: Equatable, Sendable {

    /// Whether the user is linked to an influencer promo code.
    public let isLinked: Bool

    /// The linked influencer code, when `isLinked` is true.
    public let influencerCode: String?

    /// The RevenueCat offering identifier to present, when the campaign
    /// specifies one.
    public let offeringId: String?

    /// `true` when this status was served from the on-device cache because the
    /// network was unreachable; `false` when it came fresh from the server.
    ///
    /// A cached status is the last value the server confirmed for this
    /// `userId`. There is no expiry — `fromCache` is the staleness signal.
    public let fromCache: Bool

    public init(isLinked: Bool,
                influencerCode: String?,
                offeringId: String?,
                fromCache: Bool) {
        self.isLinked = isLinked
        self.influencerCode = influencerCode
        self.offeringId = offeringId
        self.fromCache = fromCache
    }
}

/// The public error surface for Helm's `async throws` attribution methods.
///
/// The SDK's internal networking error type never crosses this boundary —
/// every transport and backend failure is mapped onto one of these cases.
public enum HelmAttributionError: Error, Equatable, Sendable, LocalizedError {

    /// `Helm.configure(...)` has not been called yet.
    case notConfigured

    /// Backend `invalid_code` — no such promo code exists.
    case invalidCode

    /// Backend `code_inactive` — the code exists but is outside its active
    /// window or has reached capacity.
    case codeInactive

    /// Backend `already_linked` — a *different* code is already linked to this
    /// user, and the backend does not allow re-linking.
    case alreadyLinked

    /// A transport failure (no connectivity, timeout, 5xx) with nothing queued
    /// or cached to fall back on.
    case network

    /// Any other backend error envelope (`{"error": {"message", "code"}}`),
    /// passed through verbatim so new server-side codes are still actionable
    /// without an SDK update.
    case server(code: String, message: String)

    /// The server returned a 2xx response whose body could not be understood.
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Helm SDK is not configured. Call Helm.configure(...) first."
        case .invalidCode:
            return "That promo code doesn't exist."
        case .codeInactive:
            return "That promo code is no longer active."
        case .alreadyLinked:
            return "A different promo code is already linked to this user."
        case .network:
            return "Couldn't reach Helm. Check your connection and try again."
        case .server(let code, let message):
            return "Helm returned an error (\(code)): \(message)"
        case .invalidResponse:
            return "Invalid response from the Helm server."
        }
    }
}

// MARK: - Internal error mapping

/// Splits the SDK's internal `HelmError` taxonomy into the two outcomes the
/// attribution submission flows care about:
///
/// - **transport** — the request never got a verdict from the backend. Safe (and
///   required) to retry, so promo-code / transaction submissions get queued and
///   status reads fall back to the cache.
/// - **terminal** — the backend answered, and the answer will not change on
///   retry. Surfaced to the caller and never queued.
internal enum AttributionErrorMapper {

    internal enum Classification: Equatable {
        case transport
        case terminal(HelmAttributionError)
    }

    /// Classify an error thrown by `HelmHTTPClient.post`.
    ///
    /// Note that 4xx statuses — including 408 and 429 — are terminal by the
    /// HELM-218 definition of transient ("no connectivity, timeout, 5xx"). If
    /// the backend ever rate-limits these endpoints, 429 should move to
    /// `.transport` here and nowhere else.
    internal static func classify(_ error: Error) -> Classification {
        guard let helmError = error as? HelmError else {
            // Defensive: `HelmHTTPClient` wraps everything it throws, so this
            // should be unreachable.
            return .terminal(.server(code: "unknown", message: error.localizedDescription))
        }

        switch helmError {
        case .networkError:
            return .transport

        case .serverError(let status, let body):
            if status >= 500 {
                return .transport
            }
            return .terminal(terminalError(status: status, body: body))

        case .notConfigured:
            // Misconfiguration is an integrator bug, not a transient failure —
            // it must never be queued for replay.
            return .terminal(.notConfigured)

        case .invalidResponse:
            return .terminal(.invalidResponse)

        case .encodingFailed(let underlying):
            return .terminal(.server(code: "encoding_failed", message: underlying.localizedDescription))

        case .invalidJSONBody:
            return .terminal(.server(code: "encoding_failed", message: "Request body is not a valid JSON object."))
        }
    }

    /// Parse the backend error envelope `{"error": {"message", "code"}}` and map
    /// the known terminal codes onto dedicated cases.
    internal static func terminalError(status: Int, body: String) -> HelmAttributionError {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = json["error"] as? [String: Any],
              let code = envelope["code"] as? String else {
            return .server(code: "http_\(status)", message: body)
        }

        let message = envelope["message"] as? String ?? ""

        switch code {
        case "invalid_code":
            return .invalidCode
        case "code_inactive":
            return .codeInactive
        case "already_linked":
            return .alreadyLinked
        default:
            return .server(code: code, message: message)
        }
    }
}
