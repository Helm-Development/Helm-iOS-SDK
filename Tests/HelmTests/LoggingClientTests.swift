import XCTest
@testable import Helm

/// Unit tests for `LoggingClient` — pure payload-builder coverage.
/// No network I/O; all assertions operate on the in-memory dictionary.
final class LoggingClientTests: XCTestCase {

    // MARK: - HelmLogLevel → OTLP severity mapping

    func testDebugSeverity() {
        XCTAssertEqual(HelmLogLevel.debug.severityNumber, 5)
        XCTAssertEqual(HelmLogLevel.debug.severityText, "DEBUG")
    }

    func testInfoSeverity() {
        XCTAssertEqual(HelmLogLevel.info.severityNumber, 9)
        XCTAssertEqual(HelmLogLevel.info.severityText, "INFO")
    }

    func testWarnSeverity() {
        XCTAssertEqual(HelmLogLevel.warn.severityNumber, 13)
        XCTAssertEqual(HelmLogLevel.warn.severityText, "WARN")
    }

    func testErrorSeverity() {
        XCTAssertEqual(HelmLogLevel.error.severityNumber, 17)
        XCTAssertEqual(HelmLogLevel.error.severityText, "ERROR")
    }

    // MARK: - LogEntry.payload() shape

    func testLogEntryPayloadTimeUnixNanoIsString() {
        let entry = LogEntry(message: "hello",
                             level: .info,
                             attributes: [:],
                             timestampNanos: 1_750_000_000_000_000_000)
        let payload = entry.payload()
        XCTAssertEqual(payload["timeUnixNano"] as? String, "1750000000000000000",
                       "timeUnixNano must be serialized as a string, not a number")
    }

    func testLogEntryPayloadBodyStringValue() {
        let entry = LogEntry(message: "test message",
                             level: .warn,
                             attributes: [:],
                             timestampNanos: 1_000)
        let payload = entry.payload()
        let body = payload["body"] as? [String: Any]
        XCTAssertEqual(body?["stringValue"] as? String, "test message")
    }

    func testLogEntryPayloadSeverityNumbers() {
        for level in [HelmLogLevel.debug, .info, .warn, .error] {
            let entry = LogEntry(message: "m", level: level, timestampNanos: 1)
            let payload = entry.payload()
            XCTAssertEqual(payload["severityNumber"] as? Int, level.severityNumber,
                           "severityNumber mismatch for \(level)")
            XCTAssertEqual(payload["severityText"] as? String, level.severityText,
                           "severityText mismatch for \(level)")
        }
    }

    func testLogEntryPayloadCustomAttributes() {
        let entry = LogEntry(message: "m",
                             level: .info,
                             attributes: ["screen": "home", "user_id": "42"],
                             timestampNanos: 1)
        let payload = entry.payload()
        let attrs = payload["attributes"] as? [[String: Any]]
        XCTAssertNotNil(attrs)
        // Build a lookup by key for order-independent assertions.
        let attrMap = Dictionary(uniqueKeysWithValues: (attrs ?? []).compactMap { dict -> (String, String)? in
            guard let key = dict["key"] as? String,
                  let val = (dict["value"] as? [String: Any])?["stringValue"] as? String
            else { return nil }
            return (key, val)
        })
        XCTAssertEqual(attrMap["screen"], "home")
        XCTAssertEqual(attrMap["user_id"], "42")
    }

    func testLogEntryPayloadEmptyAttributesIsEmptyArray() {
        let entry = LogEntry(message: "m", level: .debug, attributes: [:], timestampNanos: 1)
        let payload = entry.payload()
        let attrs = payload["attributes"] as? [[String: Any]]
        XCTAssertNotNil(attrs)
        XCTAssertEqual(attrs?.count, 0)
    }

    // MARK: - LoggingClient.logsBody OTLP envelope

    private func makeEntry(message: String = "msg",
                           level: HelmLogLevel = .info,
                           nanos: UInt64 = 1_750_000_000_000_000_000) -> LogEntry {
        LogEntry(message: message, level: level, timestampNanos: nanos)
    }

    func testLogsBodyTopLevelStructure() {
        let body = LoggingClient.logsBody(environment: "preview",
                                          serviceName: "MyApp",
                                          commitSha: nil,
                                          entries: [makeEntry()])
        XCTAssertNotNil(body["resourceLogs"] as? [[String: Any]],
                        "Top-level key must be 'resourceLogs'")
        let resourceLogs = body["resourceLogs"] as! [[String: Any]]
        XCTAssertEqual(resourceLogs.count, 1, "Exactly one resourceLogs entry")
    }

    func testLogsBodyResourceAttributes() {
        let body = LoggingClient.logsBody(environment: "staging",
                                          serviceName: "TastySpread-iOS",
                                          commitSha: nil,
                                          entries: [makeEntry()])
        let resourceLogs = body["resourceLogs"] as! [[String: Any]]
        let resource = resourceLogs[0]["resource"] as? [String: Any]
        let attrs = resource?["attributes"] as? [[String: Any]]
        XCTAssertNotNil(attrs)

        let attrMap = keyedAttributes(from: attrs ?? [])
        XCTAssertEqual(attrMap["helm.environment"], "staging")
        XCTAssertEqual(attrMap["service.name"], "TastySpread-iOS")
        XCTAssertNil(attrMap["helm.commit.sha"],
                     "commit sha must be absent when not provided")
    }

    func testLogsBodyResourceAttributesIncludesCommitSha() {
        let body = LoggingClient.logsBody(environment: "preview",
                                          serviceName: "App",
                                          commitSha: "abc123",
                                          entries: [makeEntry()])
        let resourceLogs = body["resourceLogs"] as! [[String: Any]]
        let resource = resourceLogs[0]["resource"] as? [String: Any]
        let attrs = resource?["attributes"] as? [[String: Any]]
        let attrMap = keyedAttributes(from: attrs ?? [])
        XCTAssertEqual(attrMap["helm.commit.sha"], "abc123")
    }

    func testLogsBodyScopeNameAndLogRecords() {
        let entry = makeEntry(message: "hello", level: .warn)
        let body = LoggingClient.logsBody(environment: "preview",
                                          serviceName: "App",
                                          commitSha: nil,
                                          entries: [entry])
        let resourceLogs = body["resourceLogs"] as! [[String: Any]]
        let scopeLogs = resourceLogs[0]["scopeLogs"] as? [[String: Any]]
        XCTAssertEqual(scopeLogs?.count, 1)

        let scope = scopeLogs?[0]["scope"] as? [String: Any]
        XCTAssertEqual(scope?["name"] as? String, "dev.helmcode.helm")

        let records = scopeLogs?[0]["logRecords"] as? [[String: Any]]
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?[0]["timeUnixNano"] as? String, "1750000000000000000")
        XCTAssertEqual(records?[0]["severityNumber"] as? Int, 13) // warn
        XCTAssertEqual(records?[0]["severityText"] as? String, "WARN")
        let body0 = records?[0]["body"] as? [String: Any]
        XCTAssertEqual(body0?["stringValue"] as? String, "hello")
    }

    func testLogsBodyMultipleEntries() {
        let entries = [
            makeEntry(message: "first",  level: .debug),
            makeEntry(message: "second", level: .error),
        ]
        let body = LoggingClient.logsBody(environment: "preview",
                                          serviceName: "App",
                                          commitSha: nil,
                                          entries: entries)
        let resourceLogs = body["resourceLogs"] as! [[String: Any]]
        let scopeLogs = resourceLogs[0]["scopeLogs"] as? [[String: Any]]
        let records = scopeLogs?[0]["logRecords"] as? [[String: Any]]
        XCTAssertEqual(records?.count, 2)
    }

    // MARK: - Helpers

    /// Build a `[key: stringValue]` map from an OTLP attribute array for easy assertions.
    private func keyedAttributes(from attrs: [[String: Any]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: attrs.compactMap { dict -> (String, String)? in
            guard let key = dict["key"] as? String,
                  let val = (dict["value"] as? [String: Any])?["stringValue"] as? String
            else { return nil }
            return (key, val)
        })
    }
}
