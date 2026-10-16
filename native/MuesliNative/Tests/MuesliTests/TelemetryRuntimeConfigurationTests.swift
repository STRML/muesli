import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("TelemetryRuntimeConfiguration")
struct TelemetryRuntimeConfigurationTests {
    private let validAppID = "7F2B7846-1CB5-4FE6-8ABC-56F217B06A86"

    @Test(
        "accepts configured build channels",
        arguments: ["production", "preprod", "dev", "canary"]
    )
    func acceptsConfiguredBuildChannels(channel: String) {
        let configuration = makeConfiguration(appID: validAppID, channel: channel)

        #expect(configuration.isEnabled)
        #expect(configuration.appID == validAppID)
        #expect(configuration.sdkAppID == validAppID)
        #expect(configuration.channel.rawValue == channel)
        #expect(configuration.defaultParameters["muesli.channel"] == channel)
        #expect(configuration.defaultParameters["muesli.bundle_id"] == "com.muesli.test")
    }

    @Test("disables telemetry when app ID is missing")
    func disablesMissingAppID() {
        let configuration = makeConfiguration(appID: nil, channel: "dev")

        #expect(!configuration.isEnabled)
        #expect(configuration.appID.isEmpty)
        #expect(configuration.sdkAppID == TelemetryRuntimeConfiguration.disabledSDKAppID)
        #expect(UUID(uuidString: configuration.sdkAppID) != nil)
        #expect(configuration.channel == .unconfigured)
    }

    @Test("disables telemetry when app ID is malformed")
    func disablesMalformedAppID() {
        let configuration = makeConfiguration(appID: "not-an-app-id", channel: "production")

        #expect(!configuration.isEnabled)
        #expect(configuration.appID.isEmpty)
        #expect(configuration.sdkAppID == TelemetryRuntimeConfiguration.disabledSDKAppID)
        #expect(configuration.channel == .unconfigured)
    }

    @Test("disables telemetry when channel is missing or unsupported")
    func disablesMissingOrUnsupportedChannel() {
        let missing = makeConfiguration(appID: validAppID, channel: nil)
        let unsupported = makeConfiguration(appID: validAppID, channel: "staging")

        #expect(!missing.isEnabled)
        #expect(!unsupported.isEnabled)
        #expect(missing.channel == .unconfigured)
        #expect(unsupported.channel == .unconfigured)
    }

    @Test("treats empty and whitespace plist values as missing")
    func treatsBlankValuesAsMissing() {
        let blankAppID = makeConfiguration(appID: "  \n", channel: "dev")
        let blankChannel = makeConfiguration(appID: validAppID, channel: " \t ")

        for configuration in [blankAppID, blankChannel] {
            #expect(!configuration.isEnabled)
            #expect(configuration.appID.isEmpty)
            #expect(configuration.sdkAppID == TelemetryRuntimeConfiguration.disabledSDKAppID)
            #expect(configuration.channel == .unconfigured)
        }
    }

    @Test("a compiled-in app ID sends nothing until the user opts in")
    func requiresUserConsent() {
        let configuration = makeConfiguration(appID: validAppID, channel: "production", userConsented: false)

        #expect(!configuration.isEnabled)
        #expect(configuration.appID.isEmpty)
        #expect(configuration.sdkAppID == TelemetryRuntimeConfiguration.disabledSDKAppID)
        #expect(configuration.channel == .unconfigured)
    }

    @Test("opting in does nothing when the build has no app ID")
    func consentWithoutAppIDStaysDisabled() {
        let configuration = makeConfiguration(appID: nil, channel: nil, userConsented: true)

        #expect(!configuration.isEnabled)
        #expect(configuration.sdkAppID == TelemetryRuntimeConfiguration.disabledSDKAppID)
    }

    @Test("an opted-out launch does not initialize TelemetryDeck, and its signals never reach the SDK")
    func optedOutLaunchDoesNotInitialize() {
        let sdk = RecordingTelemetrySDK()
        let gate = TelemetryGate(sdk: sdk)

        gate.apply(makeConfiguration(appID: validAppID, channel: "dev", userConsented: false))
        gate.apply(makeConfiguration(appID: nil, channel: nil, userConsented: true))
        gate.signal("dictation.completed", parameters: ["backend": "whisper"])
        gate.errorOccurred(id: "incident", parameters: [:], isAppState: false)

        #expect(!gate.isActive)
        #expect(sdk.events.isEmpty)
    }

    @Test("only the telemetry gate calls TelemetryDeck")
    func onlyTheGateCallsTelemetryDeck() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift"
            && url.lastPathComponent != "TelemetryRuntimeConfiguration.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("import TelemetryDeck") || source.contains("TelemetryDeck.signal(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "Send analytics through MuesliTelemetry or TelemetryGate: \(offenders)")
    }

    @Test("opting in starts TelemetryDeck once and opting out stops it")
    func optInStartsAndOptOutStops() {
        let sdk = RecordingTelemetrySDK()
        let gate = TelemetryGate(sdk: sdk)
        let consented = makeConfiguration(appID: validAppID, channel: "dev", userConsented: true)

        gate.apply(consented)
        gate.apply(consented)
        gate.signal("dictation.completed")
        gate.apply(makeConfiguration(appID: validAppID, channel: "dev", userConsented: false))
        gate.signal("dictation.completed")

        #expect(!gate.isActive)
        #expect(sdk.events == ["start:\(validAppID)", "signal:dictation.completed", "stop"])
    }

    @Test("analytics consent defaults off and round-trips through config JSON")
    func consentSettingDefaultsOff() throws {
        let fresh = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(fresh.shareUsageAnalytics == false)

        var config = AppConfig()
        config.shareUsageAnalytics = true
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["share_usage_analytics"] as? Bool == true)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data).shareUsageAnalytics == true)
    }

    private func makeConfiguration(
        appID: String?,
        channel: String?,
        userConsented: Bool = true
    ) -> TelemetryRuntimeConfiguration {
        var dictionary: [String: Any] = [:]
        dictionary[TelemetryRuntimeConfiguration.appIDInfoKey] = appID
        dictionary[TelemetryRuntimeConfiguration.channelInfoKey] = channel
        return TelemetryRuntimeConfiguration.resolve(
            infoDictionary: dictionary,
            bundleIdentifier: "com.muesli.test",
            userConsented: userConsented
        )
    }
}

private final class RecordingTelemetrySDK: TelemetrySDK, @unchecked Sendable {
    private(set) var events: [String] = []

    func start(_ runtime: TelemetryRuntimeConfiguration) { events.append("start:\(runtime.appID)") }
    func stop() { events.append("stop") }
    func signal(_ name: String, parameters: [String: String]) { events.append("signal:\(name)") }
    func errorOccurred(id: String, parameters: [String: String], isAppState: Bool) { events.append("error:\(id)") }
}
