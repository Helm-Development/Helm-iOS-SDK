import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "feedback")

// MARK: - Public API (HELM-310)

extension Helm {

    /// Send feedback from the app's user to Helm, with an optional image such
    /// as a screenshot.
    ///
    /// The SDK adds the platform (`ios`), the app version
    /// (`CFBundleShortVersionString`), the OS version and the device model
    /// (for example `iPhone16,2`). When the SDK was configured with
    /// `debug: true`, the feedback is stored as sandbox test data.
    ///
    /// The call waits for Helm's answer. Nothing is queued: if it throws, the
    /// feedback was not stored and the caller decides whether to try again.
    ///
    /// - Parameters:
    ///   - type: The kind of feedback.
    ///   - message: The user's message. Leading and trailing whitespace is
    ///     removed; the rest must be between 1 and 5000 characters.
    ///   - imageData: Optional JPEG, PNG, HEIC or WebP data, at most 10 MB.
    ///     Larger data is not sent: the method throws `.imageTooLarge`. To have
    ///     the SDK shrink an image for you, pass a `UIImage` to
    ///     `submitFeedback(type:message:image:userId:email:)` instead.
    ///   - imageMimeType: The MIME type of `imageData`, for example
    ///     `"image/png"`. Ignored when `imageData` is `nil`.
    ///   - userId: Optional. Your app's own ID for the user, at most 100
    ///     characters. Helm stores it as is.
    ///   - email: Optional. An email address Helm can show so you can reply to
    ///     the user.
    /// - Returns: The ID, status and creation date Helm gave the feedback.
    /// - Throws: `HelmFeedbackError`.
    @discardableResult
    public static func submitFeedback(type: FeedbackType,
                                      message: String,
                                      imageData: Data? = nil,
                                      imageMimeType: String = "image/jpeg",
                                      userId: String? = nil,
                                      email: String? = nil) async throws -> FeedbackResult {
        let image = imageData.map { FeedbackClient.Image(data: $0, mimeType: imageMimeType) }
        return try await FeedbackClient.submit(type: type,
                                               message: message,
                                               image: image,
                                               userId: userId,
                                               email: email)
    }

    #if canImport(UIKit)
    /// Send feedback with a `UIImage`, for example a screenshot.
    ///
    /// The image is encoded as JPEG. If the result is over 10 MB, the SDK
    /// lowers the JPEG quality and then scales the image down until it fits.
    /// It throws `.imageTooLarge` only if the image still does not fit.
    ///
    /// Everything else works as in
    /// `submitFeedback(type:message:imageData:imageMimeType:userId:email:)`.
    ///
    /// - Parameters:
    ///   - type: The kind of feedback.
    ///   - message: The user's message, 1 to 5000 characters after trimming.
    ///   - image: The image to attach, or `nil` for none.
    ///   - userId: Optional. Your app's own ID for the user.
    ///   - email: Optional. An email address for replying to the user.
    /// - Returns: The ID, status and creation date Helm gave the feedback.
    /// - Throws: `HelmFeedbackError`.
    @discardableResult
    public static func submitFeedback(type: FeedbackType,
                                      message: String,
                                      image: UIImage?,
                                      userId: String? = nil,
                                      email: String? = nil) async throws -> FeedbackResult {
        // Check the cheap things first, so a bad message does not cost an
        // image encode.
        guard Configuration.shared != nil else {
            throw HelmFeedbackError.notConfigured
        }
        _ = try FeedbackClient.validatedMessage(message)

        var encoded: FeedbackClient.Image?
        if let image {
            let data = try FeedbackImageEncoder.jpegData(for: image, maxBytes: FeedbackClient.maxImageBytes)
            encoded = FeedbackClient.Image(data: data, mimeType: "image/jpeg")
        }
        return try await FeedbackClient.submit(type: type,
                                               message: message,
                                               image: encoded,
                                               userId: userId,
                                               email: email)
    }
    #endif
}

// MARK: - Request building and sending

/// Builds, sends and reads the `POST /api/client/v1/feedback/` request.
internal enum FeedbackClient {

    /// Limits from the endpoint definition in HELM-307.
    static let maxMessageLength = 5000
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxAppVersionLength = 50
    static let maxOSVersionLength = 50
    static let maxDeviceModelLength = 100

    /// An image ready to upload.
    struct Image: Sendable {
        let data: Data
        let mimeType: String
    }

    /// The device and app details the SDK adds to every request. Passed in so
    /// tests can use fixed values.
    struct DeviceDetails: Sendable, Equatable {
        let appVersion: String?
        let osVersion: String
        let deviceModel: String

        static func current() -> DeviceDetails {
            DeviceDetails(appVersion: FeedbackClient.appVersion(),
                          osVersion: AnalyticsClient.osVersion(),
                          deviceModel: FeedbackClient.deviceModel())
        }
    }

    static func submit(type: FeedbackType,
                       message: String,
                       image: Image?,
                       userId: String?,
                       email: String?,
                       device: DeviceDetails = .current()) async throws -> FeedbackResult {
        guard let config = Configuration.shared else {
            logger.error("submitFeedback() before Helm.configure(...) — throwing notConfigured")
            throw HelmFeedbackError.notConfigured
        }

        let form = try makeForm(type: type,
                                message: message,
                                image: image,
                                userId: userId,
                                email: email,
                                debug: config.debug,
                                device: device)

        let response: [String: Any]
        do {
            response = try await HelmHTTPClient.postMultipart(path: APIPath.feedback, form: form)
        } catch {
            let mapped = FeedbackErrorMapper.map(error)
            logger.error("feedback submission failed: \(mapped.localizedDescription, privacy: .public)")
            throw mapped
        }

        let result = try parseResult(response)
        logger.info("feedback stored: id=\(result.id, privacy: .public)")
        return result
    }

    /// Check the inputs and build the form. Throws before anything is sent.
    ///
    /// `debug` is always sent, as the string `"true"` or `"false"`, in the
    /// same way every other SDK request always carries its `debug` flag. Helm
    /// treats only `"true"` as sandbox test data.
    static func makeForm(type: FeedbackType,
                         message: String,
                         image: Image?,
                         userId: String?,
                         email: String?,
                         debug: Bool,
                         device: DeviceDetails) throws -> MultipartFormData {
        let trimmedMessage = try validatedMessage(message)

        if let image {
            if image.data.isEmpty {
                throw HelmFeedbackError.invalidImage(message: "The image data is empty.")
            }
            if image.data.count > maxImageBytes {
                throw HelmFeedbackError.imageTooLarge(maxBytes: maxImageBytes)
            }
        }

        var form = MultipartFormData()
        form.addField(name: "feedback_type", value: type.rawValue)
        form.addField(name: "message", value: trimmedMessage)
        // Always "ios", even when the package is built for macOS to run the
        // tests: Helm accepts only "ios" and "android" here.
        form.addField(name: "platform", value: "ios")
        if let userId, !userId.isEmpty {
            form.addField(name: "user_id", value: userId)
        }
        if let email, !email.isEmpty {
            form.addField(name: "email", value: email)
        }
        if let appVersion = device.appVersion, !appVersion.isEmpty {
            form.addField(name: "app_version", value: String(appVersion.prefix(maxAppVersionLength)))
        }
        form.addField(name: "os_version", value: String(device.osVersion.prefix(maxOSVersionLength)))
        form.addField(name: "device_model", value: String(device.deviceModel.prefix(maxDeviceModelLength)))
        form.addField(name: "debug", value: debug ? "true" : "false")
        if let image {
            form.addFile(name: "image",
                         fileName: fileName(forMimeType: image.mimeType),
                         mimeType: image.mimeType,
                         data: image.data)
        }
        return form
    }

    /// Returns the message with leading and trailing whitespace removed, or
    /// throws when it is empty or too long.
    ///
    /// The length is counted in Unicode code points, the way Helm's server
    /// (Python) counts it, so a message the SDK accepts is never rejected by
    /// Helm for its length. Swift's `count` counts grapheme clusters, which
    /// would let some emoji-heavy messages through that Helm then rejects.
    static func validatedMessage(_ message: String) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw HelmFeedbackError.emptyMessage
        }
        if trimmed.unicodeScalars.count > maxMessageLength {
            throw HelmFeedbackError.messageTooLong(maxLength: maxMessageLength)
        }
        return trimmed
    }

    /// Read the 201 body `{"id", "feedback_type", "status", "date_created"}`.
    static func parseResult(_ response: [String: Any]) throws -> FeedbackResult {
        guard let id = response["id"] as? String, !id.isEmpty,
              let status = response["status"] as? String,
              let dateString = response["date_created"] as? String,
              let createdAt = parseDate(dateString) else {
            throw HelmFeedbackError.invalidResponse
        }
        return FeedbackResult(id: id, status: status, createdAt: createdAt)
    }

    /// Parse an ISO 8601 date. Helm's server writes whole seconds and a
    /// numeric UTC offset, for example `2026-10-25T09:01:52+00:00`. A `Z`
    /// suffix and fractional seconds (for example `.123456`) are accepted too,
    /// in case the format changes. `ISO8601DateFormatter` does not reliably
    /// read more than three fractional digits, so the fraction is cut to three
    /// digits first.
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var normalized = string
        if let range = normalized.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = normalized[range].dropFirst()
            let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized.replaceSubrange(range, with: "." + millis)
            return formatter.date(from: normalized)
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    static func fileName(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased().trimmingCharacters(in: .whitespaces) {
        case "image/jpeg", "image/jpg": return "feedback.jpg"
        case "image/png": return "feedback.png"
        case "image/heic", "image/heif": return "feedback.heic"
        case "image/webp": return "feedback.webp"
        default: return "feedback"
        }
    }

    // MARK: - Device details

    /// The app's `CFBundleShortVersionString`, or `nil` when it has none.
    static func appVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The hardware model identifier, for example `iPhone16,2`. On the
    /// simulator `uname` reports the Mac's CPU (`arm64`), so the simulated
    /// device's identifier is read from the environment instead.
    static func deviceModel() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
