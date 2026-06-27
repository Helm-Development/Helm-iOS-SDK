/// Log severity levels for the Helm logging module.
///
/// Each case maps to its OTLP `severityNumber` and `severityText`
/// as defined by the OpenTelemetry specification and mirrored by the
/// django-helm `_build_otlp_payload` contract.
public enum HelmLogLevel {
    /// Verbose diagnostic information. OTLP severity 5 (DEBUG).
    case debug
    /// General informational messages. OTLP severity 9 (INFO).
    case info
    /// Potentially harmful situations worth flagging. OTLP severity 13 (WARN).
    case warn
    /// Error conditions that should be investigated. OTLP severity 17 (ERROR).
    case error

    /// The OTLP `severityNumber` for this level.
    var severityNumber: Int {
        switch self {
        case .debug: return 5
        case .info:  return 9
        case .warn:  return 13
        case .error: return 17
        }
    }

    /// The OTLP `severityText` for this level.
    var severityText: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }
}
