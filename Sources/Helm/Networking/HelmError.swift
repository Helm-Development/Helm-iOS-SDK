import Foundation

/// Errors produced by the Helm SDK networking layer.
internal enum HelmError: Error, LocalizedError {

    /// `Helm.configure(...)` was not called before making API requests.
    case notConfigured

    /// A network-level error occurred (e.g. no connectivity).
    case networkError(Error)

    /// The server returned an unexpected or unparseable response.
    case invalidResponse

    /// The server returned a non-2xx status code.
    case serverError(Int, String)

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
        }
    }
}
