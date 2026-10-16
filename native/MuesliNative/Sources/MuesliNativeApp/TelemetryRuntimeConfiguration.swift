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

/// The TelemetryDeck calls Muesli makes, behind a seam so the consent gate is testable.
protocol TelemetrySDK: Sendable {
    func start(_ runtime: TelemetryRuntimeConfiguration)
    func stop()
    func signal(_ name: String, parameters: [String: String])
    func errorOccurred(id: String, parameters: [String: String], isAppState: Bool)
}

/// Calls are serialized by `TelemetryGate`'s lock.
final class TelemetryDeckSDK: TelemetrySDK, @unchecked Sendable {
    private var config: TelemetryDeck.Config?

    func start(_ runtime: TelemetryRuntimeConfiguration) {
        if let config {
            config.analyticsDisabled = false
            config.sessionStatsEnabled = true
            return
        }
        let config = TelemetryDeck.Config(appID: runtime.appID)
        config.defaultParameters = { runtime.defaultParameters }
        TelemetryDeck.initialize(config: config)
        self.config = config
    }

    /// Opt-out disables the live SDK instead of calling `TelemetryDeck.terminate()`. After
    /// terminate, the SDK's own delayed session start (0.5 s after initialize) would reach an
    /// uninitialized manager, which builds a new one that reads and uploads the shared cache.
    /// Disabled, the SDK records no new signals; ones queued before the opt-out may still send.
    func stop() {
        config?.analyticsDisabled = true
        config?.sessionStatsEnabled = false
    }

    func signal(_ name: String, parameters: [String: String]) {
        TelemetryDeck.signal(name, parameters: parameters)
    }

    func errorOccurred(id: String, parameters: [String: String], isAppState: Bool) {
        TelemetryDeck.errorOccurred(id: id, category: isAppState ? .appState : .thrownException,
                                    message: nil, parameters: parameters)
    }
}

/// Owns whether TelemetryDeck runs at all. Without consent (or without a compiled-in app ID) the
/// SDK is never initialized and never touched: in TelemetryDeck 2.11.0 even a disabled
/// `initialize` creates a SignalManager that reads the shared `<Caches>/telemetrysignalcache` and
/// uploads it, and any SDK call before `initialize` builds such a manager on the fly. So every
/// Muesli signal goes through `signal`/`errorOccurred` here, which drop it while inactive.
final class TelemetryGate: @unchecked Sendable {
    static let shared = TelemetryGate(sdk: TelemetryDeckSDK())

    private let sdk: TelemetrySDK
    private let lock = NSLock()
    private var active = false

    init(sdk: TelemetrySDK) {
        self.sdk = sdk
    }

    var isActive: Bool {
        lock.withLock { active }
    }

    /// Starts TelemetryDeck when the runtime allows it and stops it when it no longer does.
    @discardableResult
    func apply(_ runtime: TelemetryRuntimeConfiguration) -> TelemetryRuntimeConfiguration {
        lock.withLock {
            if runtime.isEnabled, !active {
                sdk.start(runtime)
                active = true
            } else if !runtime.isEnabled, active {
                sdk.stop()
                active = false
            }
        }
        return runtime
    }

    @discardableResult
    func apply(userConsented: Bool, bundle: Bundle = .main) -> TelemetryRuntimeConfiguration {
        apply(TelemetryRuntimeConfiguration.current(userConsented: userConsented, bundle: bundle))
    }

    func signal(_ name: String, parameters: [String: String] = [:]) {
        lock.withLock {
            guard active else { return }
            sdk.signal(name, parameters: parameters)
        }
    }

    func errorOccurred(id: String, parameters: [String: String], isAppState: Bool) {
        lock.withLock {
            guard active else { return }
            sdk.errorOccurred(id: id, parameters: parameters, isAppState: isAppState)
        }
    }
}

/// The only way Muesli code sends analytics.
enum MuesliTelemetry {
    static func signal(_ name: String, parameters: [String: String] = [:]) {
        TelemetryGate.shared.signal(name, parameters: parameters)
    }
}
