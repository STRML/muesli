enum DictationStartupTelemetry {
    static func send(_ report: DictationStartupReport) {
        MuesliTelemetry.signal(report.eventName, parameters: report.telemetryParameters)
        if report.outcome == .failed && report.failureReason != .none, report.failureReason != .recorderError {
            TelemetryGate.shared.errorOccurred(
                id: "microphone_capture_failed", parameters: report.telemetryParameters, isAppState: true
            )
        }
    }
}
