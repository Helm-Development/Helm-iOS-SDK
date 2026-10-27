import XCTest
@testable import Helm
#if canImport(UIKit)
import UIKit
#endif

/// HELM-310: `Helm.submitFeedback(...)` against the endpoint defined in
/// HELM-307 — request shape, multipart encoding, the `debug` flag, validation
/// before sending, success parsing, and the mapping of every error code.
final class FeedbackTests: XCTestCase {

    private static let baseURL = "https://example.invalid"
    private static let publishableKey = "pk_test_key"

    override func setUp() {
        super.setUp()
        Configuration.shared = nil
        FeedbackMockURLProtocol.reset()
    }

    override func tearDown() {
        Configuration.shared = nil
        FeedbackMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Sets the configuration directly rather than through `Helm.configure`,
    /// which would also replay queued attribution submissions.
    private func configureSDK(debug: Bool = false,
                              responder: @escaping (URLRequest) -> FeedbackMockURLProtocol.Outcome = { _ in FeedbackTests.created() }) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackMockURLProtocol.self]
        FeedbackMockURLProtocol.responder = responder
        Configuration.shared = Configuration(publishableKey: Self.publishableKey,
                                             baseURL: Self.baseURL,
                                             debug: debug,
                                             session: URLSession(configuration: config))
    }

    private static func json(_ object: [String: Any], status: Int) -> FeedbackMockURLProtocol.Outcome {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/")!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return .response(response, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func created(id: String = "4b0c5a0e-8a7f-4a52-9f0d-2f3e1d1c0b9a",
                                dateCreated: String = "2026-10-25T09:01:52+00:00") -> FeedbackMockURLProtocol.Outcome {
        json(["id": id,
              "feedback_type": "bug_report",
              "status": "new",
              "date_created": dateCreated],
             status: 201)
    }

    private static func errorEnvelope(code: String, message: String = "nope", status: Int) -> FeedbackMockURLProtocol.Outcome {
        json(["error": ["code": code, "message": message]], status: status)
    }

    private static func emptyResponse(status: Int) -> FeedbackMockURLProtocol.Outcome {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/")!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        return .response(response, Data())
    }

    private var feedbackRequests: [URLRequest] {
        FeedbackMockURLProtocol.receivedRequests.filter {
            $0.url?.absoluteString == Self.baseURL + APIPath.feedback
        }
    }

    private func onlyFeedbackRequest(file: StaticString = #filePath, line: UInt = #line) throws -> URLRequest {
        let requests = feedbackRequests
        XCTAssertEqual(requests.count, 1, "expected exactly one feedback request", file: file, line: line)
        return try XCTUnwrap(requests.first, file: file, line: line)
    }

    private func bodyData(of request: URLRequest) -> Data? {
        // URLSession moves httpBody into httpBodyStream before URLProtocol sees it.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        return request.httpBody
    }

    private func parts(of request: URLRequest) throws -> [String: MultipartPart] {
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(MultipartPart.boundary(fromContentType: contentType))
        let body = try XCTUnwrap(bodyData(of: request))
        return try MultipartPart.parse(body, boundary: boundary)
    }

    private func assertThrows(_ expected: HelmFeedbackError,
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as HelmFeedbackError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected HelmFeedbackError.\(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Request

    func test_feedback_path_matches_the_server_exactly() {
        XCTAssertEqual(APIPath.feedback, "/api/client/v1/feedback/")
    }

    func test_request_is_a_multipart_post_to_the_feedback_path_with_the_publishable_key() async throws {
        configureSDK()

        try await Helm.submitFeedback(type: .bugReport, message: "The app crashed")

        let request = try onlyFeedbackRequest()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/api/client/v1/feedback/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.publishableKey)")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
    }

    func test_multipart_body_carries_the_required_and_device_fields() async throws {
        configureSDK()

        try await Helm.submitFeedback(type: .featureRequest, message: "  Please add dark mode\n")

        let parts = try parts(of: try onlyFeedbackRequest())
        XCTAssertEqual(parts["feedback_type"]?.text, "feature_request")
        XCTAssertEqual(parts["message"]?.text, "Please add dark mode",
                       "the message is sent trimmed")
        XCTAssertEqual(parts["platform"]?.text, "ios")
        XCTAssertEqual(parts["os_version"]?.text, AnalyticsClient.osVersion())
        XCTAssertEqual(parts["device_model"]?.text, FeedbackClient.deviceModel())
        XCTAssertFalse(parts["device_model"]?.text?.isEmpty ?? true)
        XCTAssertEqual(parts["app_version"]?.text, FeedbackClient.appVersion())
        XCTAssertNil(parts["image"])
        XCTAssertNil(parts["user_id"], "optional fields are left out when not given")
        XCTAssertNil(parts["email"])
        for part in parts.values {
            XCTAssertNil(part.fileName, "text fields must not carry a filename")
        }
    }

    func test_user_id_and_email_are_sent_when_given() async throws {
        configureSDK()

        try await Helm.submitFeedback(type: .feedback,
                                      message: "Love it",
                                      userId: "user-42",
                                      email: "someone@example.com")

        let parts = try parts(of: try onlyFeedbackRequest())
        XCTAssertEqual(parts["feedback_type"]?.text, "feedback")
        XCTAssertEqual(parts["user_id"]?.text, "user-42")
        XCTAssertEqual(parts["email"]?.text, "someone@example.com")
    }

    func test_image_is_sent_as_a_file_part_with_its_mime_type_and_exact_bytes() async throws {
        configureSDK()
        // Include CR, LF and a fake boundary marker to show binary data is
        // carried byte for byte.
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]) + Data("\r\n--x\r\n".utf8)

        try await Helm.submitFeedback(type: .bugReport,
                                      message: "See screenshot",
                                      imageData: imageBytes,
                                      imageMimeType: "image/png")

        let parts = try parts(of: try onlyFeedbackRequest())
        let image = try XCTUnwrap(parts["image"])
        XCTAssertEqual(image.fileName, "feedback.png")
        XCTAssertEqual(image.contentType, "image/png")
        XCTAssertEqual(image.body, imageBytes)
    }

    func test_image_mime_type_defaults_to_jpeg() async throws {
        configureSDK()

        try await Helm.submitFeedback(type: .bugReport, message: "x", imageData: Data([0xFF, 0xD8, 0xFF]))

        let image = try XCTUnwrap(try parts(of: try onlyFeedbackRequest())["image"])
        XCTAssertEqual(image.fileName, "feedback.jpg")
        XCTAssertEqual(image.contentType, "image/jpeg")
    }

    func test_field_values_with_unicode_quotes_and_line_breaks_arrive_unchanged() async throws {
        configureSDK()
        let message = "Line one\r\nLine \"two\" — ünïcödé 👨‍👩‍👧\n--not-a-boundary"

        try await Helm.submitFeedback(type: .feedback, message: message)

        let parts = try parts(of: try onlyFeedbackRequest())
        XCTAssertEqual(parts["message"]?.text, message)
    }

    // MARK: - debug flag

    func test_debug_true_is_sent_when_configured_for_debug() async throws {
        configureSDK(debug: true)

        try await Helm.submitFeedback(type: .bugReport, message: "test data")

        XCTAssertEqual(try parts(of: try onlyFeedbackRequest())["debug"]?.text, "true")
    }

    func test_debug_false_is_sent_when_not_configured_for_debug() async throws {
        configureSDK(debug: false)

        try await Helm.submitFeedback(type: .bugReport, message: "real data")

        XCTAssertEqual(try parts(of: try onlyFeedbackRequest())["debug"]?.text, "false")
    }

    // MARK: - Device details

    func test_device_details_are_cut_to_the_server_limits() throws {
        let device = FeedbackClient.DeviceDetails(appVersion: String(repeating: "1", count: 80),
                                                  osVersion: String(repeating: "2", count: 80),
                                                  deviceModel: String(repeating: "3", count: 150))
        var form = try FeedbackClient.makeForm(type: .feedback, message: "hi", image: nil,
                                               userId: nil, email: nil, debug: false, device: device)
        let body = form.encoded()
        let parts = try MultipartPart.parse(body, boundary: form.boundary)
        XCTAssertEqual(parts["app_version"]?.text?.count, 50)
        XCTAssertEqual(parts["os_version"]?.text?.count, 50)
        XCTAssertEqual(parts["device_model"]?.text?.count, 100)
    }

    func test_app_version_is_left_out_when_the_bundle_has_none() throws {
        let device = FeedbackClient.DeviceDetails(appVersion: nil, osVersion: "18.2", deviceModel: "iPhone16,2")
        let form = try FeedbackClient.makeForm(type: .feedback, message: "hi", image: nil,
                                               userId: nil, email: nil, debug: false, device: device)
        XCTAssertFalse(form.names.contains("app_version"))
        XCTAssertEqual(form.names, ["feedback_type", "message", "platform", "os_version", "device_model", "debug"])
    }

    func test_device_model_is_a_hardware_identifier() {
        let model = FeedbackClient.deviceModel()
        XCTAssertFalse(model.isEmpty)
        XCTAssertFalse(model.contains("\0"))
        #if os(iOS)
        XCTAssertTrue(model.hasPrefix("iPhone") || model.hasPrefix("iPad") || model.hasPrefix("iPod"), model)
        #endif
    }

    // MARK: - Validation before sending

    func test_not_configured_throws_without_sending() async {
        await assertThrows(.notConfigured) {
            try await Helm.submitFeedback(type: .bugReport, message: "hello")
        }
        XCTAssertTrue(FeedbackMockURLProtocol.receivedRequests.isEmpty)
    }

    func test_empty_or_whitespace_message_throws_without_sending() async {
        configureSDK()

        await assertThrows(.emptyMessage) {
            try await Helm.submitFeedback(type: .bugReport, message: "")
        }
        await assertThrows(.emptyMessage) {
            try await Helm.submitFeedback(type: .bugReport, message: "  \n\t ")
        }
        XCTAssertTrue(feedbackRequests.isEmpty)
    }

    func test_message_over_5000_characters_throws_without_sending() async {
        configureSDK()

        await assertThrows(.messageTooLong(maxLength: 5000)) {
            try await Helm.submitFeedback(type: .bugReport, message: String(repeating: "a", count: 5001))
        }
        XCTAssertTrue(feedbackRequests.isEmpty)
    }

    func test_message_of_exactly_5000_characters_after_trimming_is_sent() async throws {
        configureSDK()

        try await Helm.submitFeedback(type: .bugReport,
                                      message: "   " + String(repeating: "a", count: 5000) + "\n")

        XCTAssertEqual(try parts(of: try onlyFeedbackRequest())["message"]?.text?.count, 5000)
    }

    func test_message_length_is_counted_in_code_points_like_the_server() {
        // One family emoji is a single Swift Character but five code points,
        // which is how the server (Python `len`) counts it.
        let family = "👨‍👩‍👧"
        XCTAssertEqual(family.unicodeScalars.count, 5)
        let message = String(repeating: family, count: 1001) // 5005 code points, 1001 Characters
        XCTAssertThrowsError(try FeedbackClient.validatedMessage(message)) { error in
            XCTAssertEqual(error as? HelmFeedbackError, .messageTooLong(maxLength: 5000))
        }
        XCTAssertNoThrow(try FeedbackClient.validatedMessage(String(repeating: family, count: 1000)))
    }

    func test_image_data_over_10_mb_throws_without_sending() async {
        configureSDK()
        let tooLarge = Data(count: 10 * 1024 * 1024 + 1)

        await assertThrows(.imageTooLarge(maxBytes: 10 * 1024 * 1024)) {
            try await Helm.submitFeedback(type: .bugReport, message: "big", imageData: tooLarge)
        }
        XCTAssertTrue(feedbackRequests.isEmpty)
    }

    func test_image_data_of_exactly_10_mb_is_sent() async throws {
        configureSDK()
        let atLimit = Data(count: 10 * 1024 * 1024)

        try await Helm.submitFeedback(type: .bugReport, message: "big", imageData: atLimit)

        XCTAssertEqual(try parts(of: try onlyFeedbackRequest())["image"]?.body.count, atLimit.count)
    }

    func test_empty_image_data_throws_invalid_image_without_sending() async {
        configureSDK()

        do {
            try await Helm.submitFeedback(type: .bugReport, message: "x", imageData: Data())
            XCTFail("expected invalidImage")
        } catch let error as HelmFeedbackError {
            guard case .invalidImage = error else { return XCTFail("expected invalidImage, got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(feedbackRequests.isEmpty)
    }

    // MARK: - Success

    /// The form Helm's server writes: whole seconds and a numeric UTC offset.
    func test_201_response_is_parsed_into_a_result() async throws {
        configureSDK { _ in Self.created(id: "4b0c5a0e-8a7f-4a52-9f0d-2f3e1d1c0b9a",
                                         dateCreated: "2026-10-25T09:01:52+00:00") }

        let result = try await Helm.submitFeedback(type: .bugReport, message: "hello")

        XCTAssertEqual(result.id, "4b0c5a0e-8a7f-4a52-9f0d-2f3e1d1c0b9a")
        XCTAssertEqual(result.status, "new")
        XCTAssertEqual(result.createdAt, ISO8601DateFormatter().date(from: "2026-10-25T09:01:52Z"))
    }

    /// In case the server later adds fractional seconds or writes `Z`.
    func test_201_response_with_fractional_seconds_and_z_is_parsed() async throws {
        configureSDK { _ in Self.created(id: "4b0c5a0e-8a7f-4a52-9f0d-2f3e1d1c0b9a",
                                         dateCreated: "2026-10-25T09:01:52.123456Z") }

        let result = try await Helm.submitFeedback(type: .bugReport, message: "hello")

        XCTAssertEqual(result.id, "4b0c5a0e-8a7f-4a52-9f0d-2f3e1d1c0b9a")
        XCTAssertEqual(result.status, "new")
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T09:01:52Z"))
        XCTAssertEqual(result.createdAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970 + 0.123, accuracy: 0.0005)
    }

    func test_dates_with_an_offset_and_without_fractional_seconds_are_parsed() throws {
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T09:01:52Z"))
        XCTAssertEqual(FeedbackClient.parseDate("2026-10-25T09:01:52+00:00"), expected)
        XCTAssertEqual(FeedbackClient.parseDate("2026-10-25T11:01:52+02:00"), expected)
        XCTAssertEqual(FeedbackClient.parseDate("2026-10-25T09:01:52Z"), expected)
        XCTAssertEqual(try XCTUnwrap(FeedbackClient.parseDate("2026-10-25T09:01:52.5+00:00")).timeIntervalSince1970,
                       expected.timeIntervalSince1970 + 0.5, accuracy: 0.0005)
        XCTAssertNil(FeedbackClient.parseDate("yesterday"))
    }

    func test_success_without_the_expected_fields_throws_invalid_response() async {
        configureSDK { _ in Self.json(["id": "abc"], status: 201) }

        await assertThrows(.invalidResponse) {
            try await Helm.submitFeedback(type: .bugReport, message: "hello")
        }
    }

    // MARK: - Error codes

    func test_each_server_error_code_maps_to_its_own_error() async {
        let cases: [(FeedbackMockURLProtocol.Outcome, HelmFeedbackError)] = [
            (Self.errorEnvelope(code: "missing_field", message: "message is required", status: 400),
             .missingField(message: "message is required")),
            (Self.errorEnvelope(code: "invalid_field", message: "email is not valid", status: 400),
             .invalidField(message: "email is not valid")),
            (Self.errorEnvelope(code: "invalid_image", message: "not an image", status: 400),
             .invalidImage(message: "not an image")),
            (Self.errorEnvelope(code: "image_too_large", status: 413),
             .imageTooLarge(maxBytes: 10 * 1024 * 1024)),
            (Self.errorEnvelope(code: "auth_required", status: 401), .authRequired),
            (Self.errorEnvelope(code: "invalid_token", status: 401), .invalidToken),
            (Self.errorEnvelope(code: "rate_limited", message: "slow down", status: 429),
             .server(code: "rate_limited", message: "slow down")),
        ]

        for (outcome, expected) in cases {
            FeedbackMockURLProtocol.reset()
            configureSDK { _ in outcome }
            await assertThrows(expected) {
                try await Helm.submitFeedback(type: .bugReport, message: "hello")
            }
        }
    }

    func test_413_without_an_error_body_maps_to_image_too_large() async {
        configureSDK { _ in Self.emptyResponse(status: 413) }

        await assertThrows(.imageTooLarge(maxBytes: 10 * 1024 * 1024)) {
            try await Helm.submitFeedback(type: .bugReport, message: "hello")
        }
    }

    func test_4xx_without_an_error_body_maps_to_server_with_the_status() async {
        configureSDK { _ in Self.emptyResponse(status: 404) }

        await assertThrows(.server(code: "http_404", message: "")) {
            try await Helm.submitFeedback(type: .bugReport, message: "hello")
        }
    }

    func test_connection_failure_maps_to_network() async {
        configureSDK { _ in .failure(URLError(.notConnectedToInternet)) }

        await assertThrows(.network) {
            try await Helm.submitFeedback(type: .bugReport, message: "hello")
        }
    }

    func test_server_failure_maps_to_network() async {
        configureSDK { _ in Self.emptyResponse(status: 503) }

        await assertThrows(.network) {
            try await Helm.submitFeedback(type: .bugReport, message: "hello")
        }
    }

    func test_failures_are_not_retried() async {
        configureSDK { _ in .failure(URLError(.timedOut)) }

        _ = try? await Helm.submitFeedback(type: .bugReport, message: "hello")

        XCTAssertEqual(feedbackRequests.count, 1, "there is no offline queue or retry")
    }

    // MARK: - Multipart encoding

    func test_multipart_encoding_matches_the_expected_bytes() {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "a", value: "1")
        form.addFile(name: "f", fileName: "x.png", mimeType: "image/png", data: Data("PNG".utf8))

        let body = String(decoding: form.encoded(), as: UTF8.self)

        XCTAssertEqual(body,
                       "--B\r\n"
                       + "Content-Disposition: form-data; name=\"a\"\r\n\r\n"
                       + "1\r\n"
                       + "--B\r\n"
                       + "Content-Disposition: form-data; name=\"f\"; filename=\"x.png\"\r\n"
                       + "Content-Type: image/png\r\n\r\n"
                       + "PNG\r\n"
                       + "--B--\r\n")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")
    }

    func test_header_parameters_escape_quotes_and_line_breaks() {
        XCTAssertEqual(MultipartFormData.escapeHeaderParameter("a\"b\r\nc"), "a%22b%0D%0Ac")

        var form = MultipartFormData(boundary: "B")
        form.addFile(name: "image", fileName: "evil\"\r\nX-Injected: 1.png", mimeType: "image/png", data: Data())
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("filename=\"evil%22%0D%0AX-Injected: 1.png\""), body)
        XCTAssertFalse(body.contains("\r\nX-Injected"))
    }

    func test_a_new_boundary_is_chosen_when_a_value_contains_it() throws {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "message", value: "before\r\n--B\r\nafter")
        form.addFile(name: "image", fileName: "x.jpg", mimeType: "image/jpeg", data: Data("--B".utf8))

        let body = form.encoded()

        XCTAssertNotEqual(form.boundary, "B")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=\(form.boundary)")
        let parts = try MultipartPart.parse(body, boundary: form.boundary)
        XCTAssertEqual(parts["message"]?.text, "before\r\n--B\r\nafter")
        XCTAssertEqual(parts["image"]?.body, Data("--B".utf8))
    }

    func test_random_boundaries_differ_and_stay_within_the_rfc_limit() {
        let first = MultipartFormData.randomBoundary()
        let second = MultipartFormData.randomBoundary()
        XCTAssertNotEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, 70)
    }

    // MARK: - Image fitting

    func test_fit_returns_the_first_quality_that_fits_at_full_size() throws {
        var attempts: [(Double, Double)] = []
        let data = try FeedbackImageEncoder.fit(maxBytes: 600, longestSide: 4000) { quality, scale in
            attempts.append((quality, scale))
            return Data(count: Int(quality * 1000)) // 900, 800, 700, 600 ...
        }
        XCTAssertEqual(data.count, 600)
        XCTAssertEqual(attempts.map(\.0), [0.9, 0.8, 0.7, 0.6])
        XCTAssertTrue(attempts.allSatisfy { $0.1 == 1.0 }, "no scaling while a quality still fits")
    }

    func test_fit_scales_down_when_lowering_the_quality_is_not_enough() throws {
        var scales: [Double] = []
        let data = try FeedbackImageEncoder.fit(maxBytes: 300, longestSide: 4000) { _, scale in
            scales.append(scale)
            return Data(count: Int(1000 * scale * scale)) // bytes grow with area
        }
        XCTAssertLessThanOrEqual(data.count, 300)
        XCTAssertEqual(scales.filter { $0 < 1 }.first ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertLessThan(scales.last ?? 1, 0.75)
    }

    func test_fit_throws_image_too_large_when_nothing_fits() {
        XCTAssertThrowsError(try FeedbackImageEncoder.fit(maxBytes: 10, longestSide: 1000) { _, _ in
            Data(count: 1000)
        }) { error in
            XCTAssertEqual(error as? HelmFeedbackError, .imageTooLarge(maxBytes: 10))
        }
    }

    func test_fit_stops_scaling_at_the_minimum_size() throws {
        var smallestSide = Double.infinity
        _ = try? FeedbackImageEncoder.fit(maxBytes: 0, longestSide: 4000) { _, scale in
            smallestSide = min(smallestSide, 4000 * scale)
            return Data(count: 1)
        }
        XCTAssertGreaterThanOrEqual(smallestSide, FeedbackImageEncoder.minimumLongestSide)
    }

    func test_fit_throws_invalid_image_when_encoding_fails() {
        XCTAssertThrowsError(try FeedbackImageEncoder.fit(maxBytes: 10, longestSide: 1000) { _, _ in nil }) { error in
            guard case .invalidImage = error as? HelmFeedbackError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
        }
    }

    // MARK: - UIImage

    #if canImport(UIKit)
    private func noiseImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var generator = SystemRandomNumberGenerator()
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    UIColor(red: .random(in: 0...1, using: &generator),
                            green: .random(in: 0...1, using: &generator),
                            blue: .random(in: 0...1, using: &generator),
                            alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }

    func test_uiimage_is_sent_as_jpeg() async throws {
        configureSDK()
        let image = noiseImage(width: 64, height: 64)

        try await Helm.submitFeedback(type: .bugReport, message: "screenshot", image: image)

        let part = try XCTUnwrap(try parts(of: try onlyFeedbackRequest())["image"])
        XCTAssertEqual(part.contentType, "image/jpeg")
        XCTAssertEqual(part.fileName, "feedback.jpg")
        XCTAssertEqual(Array(part.body.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG start-of-image marker")
    }

    func test_nil_uiimage_sends_no_image_part() async throws {
        configureSDK()

        try await Helm.submitFeedback(type: .bugReport, message: "no screenshot", image: nil)

        XCTAssertNil(try parts(of: try onlyFeedbackRequest())["image"])
    }

    func test_uiimage_over_the_limit_is_compressed_and_scaled_to_fit() throws {
        let image = noiseImage(width: 600, height: 400)
        let fullSize = try XCTUnwrap(image.jpegData(compressionQuality: 0.4))
        let limit = fullSize.count / 2 // forces at least one scale-down step

        let data = try FeedbackImageEncoder.jpegData(for: image, maxBytes: limit)

        XCTAssertLessThanOrEqual(data.count, limit)
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThan(decoded.size.width * decoded.scale, 600)
        XCTAssertEqual(decoded.size.width / decoded.size.height, 1.5, accuracy: 0.01, "aspect ratio is kept")
    }

    func test_uiimage_that_cannot_fit_throws_image_too_large_without_sending() async {
        configureSDK()
        let image = noiseImage(width: 400, height: 400)

        XCTAssertThrowsError(try FeedbackImageEncoder.jpegData(for: image, maxBytes: 100)) { error in
            XCTAssertEqual(error as? HelmFeedbackError, .imageTooLarge(maxBytes: 100))
        }
        XCTAssertTrue(feedbackRequests.isEmpty)
    }

    func test_uiimage_overload_checks_the_message_before_encoding() async {
        configureSDK()

        await assertThrows(.emptyMessage) {
            try await Helm.submitFeedback(type: .bugReport, message: " ", image: UIImage())
        }
        XCTAssertTrue(feedbackRequests.isEmpty)
    }
    #endif
}

// MARK: - Multipart parsing for assertions

/// One part of a parsed `multipart/form-data` body.
private struct MultipartPart {
    let name: String
    let fileName: String?
    let contentType: String?
    let body: Data

    var text: String? { String(data: body, encoding: .utf8) }

    static func boundary(fromContentType contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        return String(contentType[range.upperBound...])
    }

    /// A small parser for the SDK's own output: splits on the boundary
    /// delimiter and reads the `Content-Disposition` and `Content-Type`
    /// headers of each part.
    static func parse(_ body: Data, boundary: String) throws -> [String: MultipartPart] {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        let crlf = Data("\r\n".utf8)

        var result: [String: MultipartPart] = [:]
        var searchStart = body.startIndex
        guard let first = body.range(of: delimiter, in: searchStart..<body.endIndex) else {
            throw ParseError.malformed("no opening delimiter")
        }
        searchStart = first.upperBound

        while true {
            // After a delimiter comes either "--" (the end) or CRLF and a part.
            if body[searchStart...].starts(with: Data("--".utf8)) { break }
            guard body[searchStart...].starts(with: crlf) else { throw ParseError.malformed("no CRLF after delimiter") }
            let partStart = searchStart + crlf.count
            guard let next = body.range(of: crlf + delimiter, in: partStart..<body.endIndex) else {
                throw ParseError.malformed("no closing delimiter")
            }
            let part = body[partStart..<next.lowerBound]
            guard let split = part.range(of: headerEnd) else { throw ParseError.malformed("no header end") }
            let headerText = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
            let content = Data(part[split.upperBound...])

            var name: String?
            var fileName: String?
            var contentType: String?
            for line in headerText.components(separatedBy: "\r\n") {
                if line.hasPrefix("Content-Disposition:") {
                    name = parameter("name", in: line)
                    fileName = parameter("filename", in: line)
                } else if line.hasPrefix("Content-Type:") {
                    contentType = line.dropFirst("Content-Type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            guard let name else { throw ParseError.malformed("part without a name") }
            result[name] = MultipartPart(name: name, fileName: fileName, contentType: contentType, body: content)
            searchStart = next.upperBound
        }
        return result
    }

    private static func parameter(_ key: String, in line: String) -> String? {
        guard let start = line.range(of: "; \(key)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    enum ParseError: Error {
        case malformed(String)
    }
}

// MARK: - Mock URL protocol

private final class FeedbackMockURLProtocol: URLProtocol {

    enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(URLError)
    }

    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> Outcome)?
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        receivedRequests = []
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.receivedRequests.append(request)
        let responder = Self.responder
        Self.lock.unlock()

        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        switch responder(request) {
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
