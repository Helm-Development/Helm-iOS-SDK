import Foundation

/// Builds a `multipart/form-data` request body (RFC 7578) by hand, so the SDK
/// needs no extra dependency to upload a file.
///
/// Add text fields with `addField(name:value:)` and files with
/// `addFile(name:fileName:mimeType:data:)`, then read `contentType` for the
/// request's `Content-Type` header and `encoded()` for the body.
internal struct MultipartFormData: Sendable {

    private enum Part: Sendable {
        case field(name: String, value: String)
        case file(name: String, fileName: String, mimeType: String, data: Data)
    }

    private var parts: [Part] = []

    /// The string that separates the parts. It is random so that it is very
    /// unlikely to appear inside a value; `encoded()` checks anyway and picks a
    /// new one if it does.
    private(set) var boundary: String

    init(boundary: String = MultipartFormData.randomBoundary()) {
        self.boundary = boundary
    }

    /// The value for the request's `Content-Type` header.
    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// The names of the fields and files added so far, in order.
    var names: [String] {
        parts.map {
            switch $0 {
            case .field(let name, _): return name
            case .file(let name, _, _, _): return name
            }
        }
    }

    mutating func addField(name: String, value: String) {
        parts.append(.field(name: name, value: value))
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        parts.append(.file(name: name, fileName: fileName, mimeType: mimeType, data: data))
    }

    /// The encoded body. If the boundary happens to occur inside any value or
    /// file, a new random boundary is chosen first, so read `contentType`
    /// after calling this.
    mutating func encoded() -> Data {
        while containsBoundary() {
            boundary = Self.randomBoundary()
        }

        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n")
            switch part {
            case .field(let name, let value):
                body.append("Content-Disposition: form-data; name=\"\(Self.escapeHeaderParameter(name))\"\r\n")
                body.append("\r\n")
                body.append(value)
            case .file(let name, let fileName, let mimeType, let data):
                body.append("Content-Disposition: form-data; name=\"\(Self.escapeHeaderParameter(name))\"; filename=\"\(Self.escapeHeaderParameter(fileName))\"\r\n")
                body.append("Content-Type: \(Self.stripLineBreaks(mimeType))\r\n")
                body.append("\r\n")
                body.append(data)
            }
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Helpers

    /// A boundary of 46 characters, well under the 70-character limit in
    /// RFC 2046, made only of characters that never need quoting.
    static func randomBoundary() -> String {
        "Helm-Boundary-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Escapes a value placed inside a quoted `Content-Disposition` parameter
    /// (`name="..."`, `filename="..."`). Following the HTML form-encoding
    /// rules, `"` becomes `%22`, carriage return becomes `%0D` and line feed
    /// becomes `%0A`, so a value can never end the quoted string or start a
    /// new header line.
    static func escapeHeaderParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private static func stripLineBreaks(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func containsBoundary() -> Bool {
        let marker = Data("--\(boundary)".utf8)
        for part in parts {
            switch part {
            case .field(let name, let value):
                if name.contains(boundary) || value.contains(boundary) { return true }
            case .file(let name, let fileName, let mimeType, let data):
                if name.contains(boundary) || fileName.contains(boundary) || mimeType.contains(boundary) {
                    return true
                }
                if data.range(of: marker) != nil { return true }
            }
        }
        return false
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
