/// Centralized API path constants for all Helm SDK endpoints.
///
/// All path strings are defined exactly once here. Call sites reference
/// `APIPath.*` rather than inlining literals so typos surface at compile time
/// and future audits require changing only this file.
///
/// Path prefix notes:
/// - Attribution endpoints use the `/api/client/v1/` prefix (publishable-key auth).
/// - Analytics endpoints use the `/api/v1/analytics/` prefix (build-entitlement auth).
/// - Log ingestion uses `/api/v1/logs` (ingest-token auth, preview/non-prod only).
enum APIPath {
    // MARK: - Attribution (/api/client/v1/attribution/*)

    static let attributionMatch  = "/api/client/v1/attribution/match/"
    static let attributionEvent  = "/api/client/v1/attribution/event/"

    // MARK: - Analytics (/api/v1/analytics/*)

    static let analyticsInstallations = "/api/v1/analytics/installations/"
    static let analyticsEvents        = "/api/v1/analytics/events/"
    static let analyticsApiHits       = "/api/v1/analytics/api-hits/"

    // MARK: - Logging (/api/v1/logs — no trailing slash)

    static let logs = "/api/v1/logs"
}
