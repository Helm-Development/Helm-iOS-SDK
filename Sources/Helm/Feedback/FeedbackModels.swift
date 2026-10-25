import Foundation

// MARK: - Public types (HELM-310)

/// The kind of feedback a user is sending. The raw value is the
/// `feedback_type` value Helm expects.
public enum FeedbackType: String, CaseIterable, Equatable, Sendable {

    /// Something in the app is broken or behaves unexpectedly.
    case bugReport = "bug_report"

    /// The user is asking for something the app does not do yet.
    case featureRequest = "feature_request"

    /// General feedback that is neither a bug report nor a feature request.
    case feedback = "feedback"
}

/// What Helm returns after it has stored a piece of feedback.
public struct FeedbackResult: Equatable, Sendable {

    /// The ID Helm gave the feedback (a UUID string).
    public let id: String

    /// The feedback's review status in Helm. New feedback is always `"new"`;
    /// project members change it later on the User Feedback page.
    public let status: String

    /// When Helm stored the feedback.
    public let createdAt: Date

    public init(id: String, status: String, createdAt: Date) {
        self.id = id
        self.status = status
        self.createdAt = createdAt
    }
}

/// The errors `Helm.submitFeedback(...)` throws.
///
/// The first group is found on the device before anything is sent. The second
/// group is Helm's answer to the request. Nothing is queued or retried: when
/// this error is thrown, the feedback was not stored.
public enum HelmFeedbackError: Error, Equatable, Sendable, LocalizedError {

    // Found on the device, before sending.

    /// `Helm.configure(...)` has not been called yet.
    case notConfigured

    /// The message is empty, or contains only spaces and line breaks.
    case emptyMessage

    /// The message is longer than `maxLength` characters (5000) after
    /// leading and trailing whitespace is removed.
    case messageTooLong(maxLength: Int)

    /// The image is larger than `maxBytes` (10 MB). For raw image data this is
    /// thrown without sending. For a `UIImage` it is thrown only when the image
    /// is still too large after it has been compressed and scaled down. Helm's
    /// `image_too_large` answer (HTTP 413) maps to this case as well.
    case imageTooLarge(maxBytes: Int)

    // Helm's answer.

    /// Helm's `missing_field`: a required field was not sent. `message` is
    /// Helm's explanation and names the field.
    case missingField(message: String)

    /// Helm's `invalid_field`: a field has a value Helm does not accept, for
    /// example an email address that is not valid or a user ID longer than
    /// 100 characters. `message` is Helm's explanation.
    case invalidField(message: String)

    /// Helm's `invalid_image`: the file is not a JPEG, PNG, HEIC or WebP image.
    /// Also thrown before sending when a `UIImage` cannot be encoded as JPEG.
    case invalidImage(message: String)

    /// Helm's `auth_required`: the request had no usable `Authorization` header.
    case authRequired

    /// Helm's `invalid_token`: the publishable key is unknown or revoked.
    case invalidToken

    /// The request did not get an answer from Helm: no connection, a timeout,
    /// or a server failure (HTTP 5xx). The feedback was not stored; the caller
    /// can try again later.
    case network

    /// Any other error Helm returned, passed through as is so a new
    /// server-side error code is still readable without an SDK update.
    case server(code: String, message: String)

    /// Helm answered with success but the response body could not be read.
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Helm SDK is not configured. Call Helm.configure(...) first."
        case .emptyMessage:
            return "The feedback message is empty."
        case .messageTooLong(let maxLength):
            return "The feedback message is longer than \(maxLength) characters."
        case .imageTooLarge(let maxBytes):
            return "The image is larger than \(maxBytes / (1024 * 1024)) MB."
        case .missingField(let message):
            return "A required field is missing: \(message)"
        case .invalidField(let message):
            return "A field has a value Helm does not accept: \(message)"
        case .invalidImage(let message):
            return "The image is not a supported type: \(message)"
        case .authRequired:
            return "The request to Helm was not authenticated."
        case .invalidToken:
            return "Helm did not accept the publishable key."
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

/// Turns the SDK's internal `HelmError` into the public `HelmFeedbackError`.
internal enum FeedbackErrorMapper {

    static func map(_ error: Error) -> HelmFeedbackError {
        guard let helmError = error as? HelmError else {
            // `HelmHTTPClient` wraps everything it throws, so this should not
            // happen.
            return .server(code: "unknown", message: error.localizedDescription)
        }

        switch helmError {
        case .networkError:
            return .network
        case .serverError(let status, let body):
            if status >= 500 {
                return .network
            }
            return serverError(status: status, body: body)
        case .notConfigured:
            return .notConfigured
        case .invalidResponse:
            return .invalidResponse
        case .encodingFailed(let underlying):
            return .server(code: "encoding_failed", message: underlying.localizedDescription)
        case .invalidJSONBody:
            return .server(code: "encoding_failed", message: "Request body is not a valid JSON object.")
        }
    }

    /// Read Helm's error body `{"error": {"message", "code"}}` and map each
    /// code the feedback endpoint documents onto its own case.
    static func serverError(status: Int, body: String) -> HelmFeedbackError {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = json["error"] as? [String: Any],
              let code = envelope["code"] as? String else {
            if status == 413 {
                // A proxy in front of Helm can reject an oversized upload with
                // a plain 413 before the request reaches Helm itself.
                return .imageTooLarge(maxBytes: FeedbackClient.maxImageBytes)
            }
            return .server(code: "http_\(status)", message: body)
        }

        let message = envelope["message"] as? String ?? ""

        switch code {
        case "missing_field":
            return .missingField(message: message)
        case "invalid_field":
            return .invalidField(message: message)
        case "invalid_image":
            return .invalidImage(message: message)
        case "image_too_large":
            return .imageTooLarge(maxBytes: FeedbackClient.maxImageBytes)
        case "auth_required":
            return .authRequired
        case "invalid_token":
            return .invalidToken
        default:
            return .server(code: code, message: message)
        }
    }
}
