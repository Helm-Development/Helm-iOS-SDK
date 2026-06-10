import Foundation

/// Resolves the device's public IP address using an external service.
internal struct IPResolver {

    /// Fetch the device's public IP address.
    ///
    /// Uses https://api.ipify.org?format=json which returns `{"ip": "..."}`.
    /// - Returns: The public IP as a string.
    /// - Throws: `HelmError.networkError` or `HelmError.invalidResponse`.
    static func fetchPublicIP() async throws -> String {
        guard let url = URL(string: "https://api.ipify.org?format=json") else {
            throw HelmError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw HelmError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String else {
            throw HelmError.invalidResponse
        }

        return ip
    }
}
