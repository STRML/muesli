import Foundation
import TelemetryDeck

enum MuesliTelemetryChannel: String, CaseIterable, Sendable {
    case production
    case preprod
    case dev
    case canary
    case unconfigured
}

struct TelemetryRuntimeConfiguration: Equatable, Sendable {
    static let appIDInfoKey = "MuesliTelemetryDeckAppID"
    static let channelInfoKey = "MuesliTelemetryChannel"
    static let disabledSDKAppID = "00000000-0000-0000-0000-000000000000"

    let appID: String
    let channel: MuesliTelemetryChannel
    let bundleID: String
    let isEnabled: Bool

    var sdkAppID: String {
        isEnabled ? appID : Self.disabledSDKAppID
    }

    static func current(userConsented: Bool, bundle: Bundle = .main) -> TelemetryRuntimeConfiguration {
        resolve(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier,
            userConsented: userConsented
        )
    }

    /// True when this build has an analytics destination compiled in, whatever the user chose.
    static func buildHasAnalyticsDestination(bundle: Bundle = .main) -> Bool {
        current(userConsented: true, bundle: bundle).isEnabled
    }

    /// Analytics run only when the build carries a valid app ID and channel AND the user turned on
    /// "Share anonymous usage analytics" (off by default).
    static func resolve(
        infoDictionary: [String: Any],
        bundleIdentifier: String?,
        userConsented: Bool
    ) -> TelemetryRuntimeConfiguration {
        let rawAppID = stringValue(for: appIDInfoKey, in: infoDictionary) ?? ""
        let rawChannel = stringValue(for: channelInfoKey, in: infoDictionary) ?? "unconfigured"
        let channel = MuesliTelemetryChannel(rawValue: rawChannel) ?? .unconfigured
        let hasValidAppID = UUID(uuidString: rawAppID) != nil
        let hasConfiguredChannel = channel != .unconfigured
        let enabled = hasValidAppID && hasConfiguredChannel && userConsented

        return TelemetryRuntimeConfiguration(
            appID: enabled ? rawAppID : "",
            channel: enabled ? channel : .unconfigured,
            bundleID: normalizedBundleID(bundleIdentifier),
            isEnabled: enabled
        )
    }

    var defaultParameters: [String: String] {
        [
            "muesli.channel": channel.rawValue,
            "muesli.bundle_id": bundleID,
        ]
    }

    private static func stringValue(for key: String, in dictionary: [String: Any]) -> String? {
        guard let value = dictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedBundleID(_ value: String?) -> String {
        guard let value else { return "unknown" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

enum TelemetryBootstrap {
    /// (Re)initializes TelemetryDeck for the user's current choice. It must always run before any
    /// `TelemetryDeck.signal` call: an uninitialized SDK builds a fresh, enabled manager per call.
    /// A disabled config carries the all-zero app ID and `analyticsDisabled`, so no signal is recorded.
    @discardableResult
    static func start(userConsented: Bool, bundle: Bundle = .main) -> TelemetryRuntimeConfiguration {
        let runtime = TelemetryRuntimeConfiguration.current(userConsented: userConsented, bundle: bundle)
        let config = TelemetryDeck.Config(appID: runtime.sdkAppID)
        config.analyticsDisabled = !runtime.isEnabled
        config.defaultParameters = { runtime.defaultParameters }
        TelemetryDeck.initialize(config: config)
        return runtime
    }
}
