import Foundation

/// Builds OTLP/HTTP JSON log envelopes and ships them to the Helm ingest endpoint.
///
/// Stateless — mirrors the `AnalyticsClient` split between pure payload builders
/// (unit-testable) and the network layer.
///
/// OTLP contract mirrors django-helm `logging/_build_otlp_payload`:
/// ```
/// {
///   "resourceLogs": [{
///     "resource": {
///       "attributes": [
///         {"key": "helm.environment", "value": {"stringValue": "<env>"}},
///         {"key": "service.name",     "value": {"stringValue": "<service>"}},
///         // optional:
///         {"key": "helm.commit.sha",  "value": {"stringValue": "<sha>"}}
///       ]
///     },
///     "scopeLogs": [{
///       "scope": {"name": "dev.helmcode.helm"},
///       "logRecords": [
///         {
///           "timeUnixNano": "<nanoseconds as string>",
///           "severityNumber": Int,
///           "severityText": String,
///           "body": {"stringValue": "<message>"},
///           "attributes": [{"key": k, "value": {"stringValue": v}}]
///         }
///       ]
///     }]
///   }]
/// }
/// ```
internal enum LoggingClient {

    // MARK: - Payload builder (pure, unit-tested)

    /// Builds the complete OTLP/HTTP JSON envelope for a batch of log entries.
    static func logsBody(environment: String,
                         serviceName: String,
                         commitSha: String?,
                         entries: [LogEntry]) -> [String: Any] {
        var resourceAttributes: [[String: Any]] = [
            ["key": "helm.environment", "value": ["stringValue": environment]],
            ["key": "service.name",     "value": ["stringValue": serviceName]],
        ]
        if let sha = commitSha, !sha.isEmpty {
            resourceAttributes.append(
                ["key": "helm.commit.sha", "value": ["stringValue": sha]]
            )
        }

        let logRecords: [[String: Any]] = entries.map { $0.payload() }

        return [
            "resourceLogs": [
                [
                    "resource": ["attributes": resourceAttributes],
                    "scopeLogs": [
                        [
                            "scope": ["name": "dev.helmcode.helm"],
                            "logRecords": logRecords,
                        ]
                    ],
                ]
            ]
        ]
    }

    // MARK: - Network

    /// Sends a batch of log entries to the Helm OTLP endpoint.
    ///
    /// Uses `bearerOverride` so the `hlit_…` ingest token is sent in the
    /// `Authorization` header instead of the publishable key.
    static func sendLogs(ingestToken: String,
                         environment: String,
                         serviceName: String,
                         commitSha: String?,
                         entries: [LogEntry]) async throws {
        _ = try await HelmHTTPClient.post(
            path: APIPath.logs,
            body: logsBody(environment: environment,
                           serviceName: serviceName,
                           commitSha: commitSha,
                           entries: entries),
            bearerOverride: ingestToken
        )
    }
}
