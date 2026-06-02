import Foundation

/// Errors produced by the Helm SDK networking layer.
internal enum HelmError: Error, LocalizedError, @unchecked Sendable {

    /// `Helm.configure(...)` was not called before making API requests.
    case notConfigured

    /// A network-level error occurred (e.g. no connectivity).
    case networkError(Error)

    /// The server returned an unexpected or unparseable response.
    case invalidResponse

    /// The server returned a non-2xx status code.
    case serverError(Int, String)

    /// Failed to encode the request body as JSON.
    case encodingFailed(Error)

    /// The request body contained values that are not valid JSON
    /// (e.g. `Double.infinity`, non-string keys). Surfaced as the
    /// underlying error in `.encodingFailed`.
    case invalidJSONBody

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Helm SDK is not configured. Call Helm.configure(...) first."
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server."
        case .serverError(let code, let body):
            return "Server error \(code): \(body)"
        case .encodingFailed(let underlying):
            return "Failed to encode request body: \(underlying.localizedDescription)"
        case .invalidJSONBody:
            return "Request body is not a valid JSON object."
        }
    }
}
