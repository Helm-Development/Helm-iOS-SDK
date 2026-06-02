import Foundation
import os

private let logger = Logger(subsystem: "dev.helmcode.helm", category: "http")

/// Makes authenticated HTTP requests to the Helm API.
internal struct HelmHTTPClient: Sendable {

    /// POST JSON to a Helm API endpoint.
    ///
    /// - Parameters:
    ///   - path: The API path (e.g. "/attribution/match/").
    ///   - body: A dictionary that will be serialized to JSON.
    /// - Returns: The parsed JSON response as a dictionary.
    /// - Throws: `HelmError` on configuration, encoding, network, or parsing failures.
    static func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let config = Configuration.shared else {
            throw HelmError.notConfigured
        }

        guard let url = URL(string: config.baseURL + path) else {
            throw HelmError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `JSONSerialization.data(withJSONObject:)` raises an Objective-C
        // exception (uncatchable from Swift) for fundamentally invalid input
        // (e.g. `Double.infinity`, non-string keys). Pre-validate with
        // `isValidJSONObject` so we can surface a clean Swift error instead
        // of crashing or — as before — silently sending an empty body.
        guard JSONSerialization.isValidJSONObject(body) else {
            let error = HelmError.invalidJSONBody
            logger.error("JSON encoding failed: invalid JSON object")
            throw HelmError.encodingFailed(error)
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("JSON encoding failed: \(error.localizedDescription, privacy: .public)")
            throw HelmError.encodingFailed(error)
        }

        logger.info("POST \(url.absoluteString, privacy: .public)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await config.session.data(for: request)
        } catch {
            logger.error("network error: \(error.localizedDescription, privacy: .public)")
            throw HelmError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HelmError.invalidResponse
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        logger.info("response: status=\(httpResponse.statusCode, privacy: .public) body=\(bodyString, privacy: .private)")

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HelmError.serverError(httpResponse.statusCode, bodyString)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelmError.invalidResponse
        }

        return json
    }
}
