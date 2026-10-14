import Foundation
import Testing
@testable import MuesliNativeApp

/// A recording started from a calendar link ("Join & Transcribe") is armed with a source built
/// from the meeting URL alone. These tests build candidates with the real resolver, the way the
/// live monitor does, to prove that such a source binds to the call it started.
@Suite("Meeting call-end detection")
struct MeetingCallEndDetectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    struct NativeCall: CustomTestStringConvertible, Sendable {
        let label: String
        let url: String
        let bundleID: String
        let appName: String
        var testDescription: String { label }
    }

    static let nativeCalls: [NativeCall] = [
        NativeCall(
            label: "Teams (new) meetup-join",
            url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZDI5YjQ3MTktNzI2%40thread.v2/0?context=%7b%22Tid%22%3a%22a1b2%22%7d",
            bundleID: "com.microsoft.teams2", appName: "Microsoft Teams"
        ),
        NativeCall(
            label: "Teams (classic) meetup-join",
            url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZDI5YjQ3MTktNzI2%40thread.v2/0?context=%7b%22Tid%22%3a%22a1b2%22%7d",
            bundleID: "com.microsoft.teams", appName: "Microsoft Teams"
        ),
        NativeCall(
            label: "Teams live meet link",
            url: "https://teams.live.com/meet/9876543210123?p=abcDEFghi",
            bundleID: "com.microsoft.teams2", appName: "Microsoft Teams"
        ),
        NativeCall(
            label: "Zoom",
            url: "https://us02web.zoom.us/j/81234567890?pwd=abcdef",
            bundleID: "us.zoom.xos", appName: "zoom.us"
        ),
        NativeCall(
            label: "Webex meetings app",
            url: "https://acme.webex.com/meet/jdoe",
            bundleID: "com.webex.meetingmanager", appName: "Webex"
        ),
        NativeCall(
            label: "Webex (cisco) app",
            url: "https://acme.webex.com/meet/jdoe",
            bundleID: "com.cisco.webexmeetingsapp", appName: "Webex"
        ),
        NativeCall(
            label: "FaceTime",
            url: "https://facetime.apple.com/join#v=1&p=abc&k=def",
            bundleID: "com.apple.FaceTime", appName: "FaceTime"
        ),
        NativeCall(
            label: "Slack huddle",
            url: "https://app.slack.com/huddle/T012345/C067890",
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"
        ),
    ]

    private func resolver() -> MeetingCandidateResolver {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = "com.muesli.app"
        return resolver
    }

    private func audio(_ call: NativeCall) -> AudioProcessActivity {
        AudioProcessActivity(
            pid: 4321, bundleID: call.bundleID, appName: call.appName,
            isRunningInput: true, isRunningOutput: true
        )
    }

    private func resolve(
        processes: [AudioProcessActivity] = [],
        calendar: CalendarEventContext? = nil,
        runningApps: [RunningAppInfo] = [],
        browserMeetings: [BrowserMeetingContext] = [],
        at date: Date? = nil
    ) -> MeetingCandidate? {
        resolver().resolve(MeetingSignalSnapshot(
            micActive: true, cameraActive: false, calendarEvent: calendar,
            runningApps: runningApps, browserMeetings: browserMeetings,
            audioInputProcesses: processes, foregroundBundleID: nil, now: date ?? now
        ))
    }

    private func urlSource(_ rawURL: String) throws -> MeetingAutoStopSource {
        let url = try #require(URL(string: rawURL))
        return try #require(MeetingAutoStopSource(meetingURL: url))
    }

    @Test("a URL-armed source binds to the native app the call is in", arguments: nativeCalls, [false, true])
    func urlSourceBindsToNativeApp(call: NativeCall, withCalendarEvent: Bool) throws {
        let source = try urlSource(call.url)
        let calendar = withCalendarEvent ? CalendarEventContext(id: "evt-1", title: "Weekly sync") : nil
        let candidate = try #require(resolve(processes: [audio(call)], calendar: calendar))

        #expect(candidate.url == nil, "native apps expose no room URL")
        #expect(MeetingAutoStopPolicy.matches(candidate: candidate, source: source))

        // End to end through the tracker: seen while the call runs, lost 20 s after it ends.
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: source)
        tracker.markRecordingStarted(now: now)
        let whileInCall = tracker.observe(candidate: candidate, now: now.addingTimeInterval(10), gracePeriod: 20)
        #expect(!whileInCall)
        #expect(tracker.lastSeenAt == now.addingTimeInterval(10))
        let insideGrace = tracker.observe(candidate: nil, now: now.addingTimeInterval(25), gracePeriod: 20)
        #expect(!insideGrace)
        let afterGrace = tracker.observe(candidate: nil, now: now.addingTimeInterval(31), gracePeriod: 20)
        #expect(afterGrace)
    }

    @Test("a URL-armed source binds to the stabilized session candidate the monitor really emits")
    func urlSourceBindsToStabilizedCandidate() async throws {
        let call = Self.nativeCalls[0]
        let source = try urlSource(call.url)
        let raw = try #require(resolve(processes: [audio(call)]))
        let tracker = MeetingMediaSessionTracker()
        let snapshot = MeetingSignalSnapshot(
            micActive: true, cameraActive: false, calendarEvent: nil, runningApps: [],
            browserMeetings: [], audioInputProcesses: [audio(call)], foregroundBundleID: nil, now: now
        )
        let stabilized = try #require(await tracker.stabilize(candidate: raw, snapshot: snapshot))

        #expect(stabilized.id.hasPrefix("meeting-session:app:com.microsoft.teams2"))
        #expect(MeetingAutoStopPolicy.matches(candidate: stabilized, source: source))
    }

    @Test("a URL-armed source still matches a browser candidate in the same room")
    func urlSourceMatchesBrowserRoom() throws {
        let call = Self.nativeCalls[2]
        let source = try urlSource(call.url)
        let normalized = try #require(MeetingURLNormalizer.normalize(call.url))
        let browserCandidate = try #require(resolve(browserMeetings: [BrowserMeetingContext(
            bundleID: "com.google.Chrome", appName: "Chrome", url: normalized.url,
            normalizedID: normalized.id, platform: normalized.platform, isFocused: true
        )]))
        #expect(MeetingAutoStopPolicy.matches(candidate: browserCandidate, source: source))
    }

    @Test("a different platform never extends the recording", arguments: [0, 3, 4, 6])
    func otherPlatformDoesNotBind(otherIndex: Int) throws {
        let teams = Self.nativeCalls[0]
        let other = Self.nativeCalls[otherIndex]
        let source = try urlSource(teams.url)
        let candidate = try #require(resolve(processes: [audio(other)]))
        #expect(MeetingAutoStopPolicy.matches(candidate: candidate, source: source) == (otherIndex == 0))
    }

    @Test("conflicting room evidence from another Teams meeting in a browser does not match")
    func conflictingBrowserRoomDoesNotMatch() throws {
        let teams = Self.nativeCalls[0]
        let source = try urlSource(teams.url)
        let other = try #require(MeetingURLNormalizer.normalize("https://teams.microsoft.com/l/meetup-join/19%3ameeting_OTHER%40thread.v2/0"))
        let candidate = try #require(resolve(browserMeetings: [BrowserMeetingContext(
            bundleID: "com.google.Chrome", appName: "Chrome", url: other.url,
            normalizedID: other.id, platform: other.platform, isFocused: true
        )]))
        #expect(!MeetingAutoStopPolicy.matches(candidate: candidate, source: source))
    }

    @Test("a calendar guess from a merely running app is not evidence of the call")
    func runningAppGuessDoesNotBind() throws {
        let teams = Self.nativeCalls[0]
        let source = try urlSource(teams.url)
        let guess = try #require(resolve(
            calendar: CalendarEventContext(id: "evt-1", title: "Weekly sync"),
            runningApps: [RunningAppInfo(bundleID: teams.bundleID, isActive: false)]
        ))
        #expect(guess.sourceBundleID == teams.bundleID)
        #expect(!guess.evidence.contains(.audioInputProcess))
        #expect(!MeetingAutoStopPolicy.matches(candidate: guess, source: source))
    }

    @Test("browser audio with no room URL cannot bind a URL-armed source")
    func browserAudioWithoutRoomDoesNotBind() throws {
        let meet = try urlSource("https://meet.google.com/abc-defg-hij")
        let youtube = try #require(resolve(processes: [AudioProcessActivity(
            pid: 99, bundleID: "com.google.Chrome.helper", appName: "Chrome Helper",
            isRunningInput: true, isRunningOutput: true
        )]))
        #expect(youtube.platform == .unknown)
        #expect(!MeetingAutoStopPolicy.matches(candidate: youtube, source: meet))
    }

    @Test("once bound, the source follows the same app but not another platform")
    func boundSourceStaysBound() throws {
        let teams = Self.nativeCalls[0]
        let zoom = Self.nativeCalls[3]
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: try urlSource(teams.url))
        tracker.markRecordingStarted(now: now)
        let teamsCandidate = try #require(resolve(processes: [audio(teams)]))
        let seen = tracker.observe(candidate: teamsCandidate, now: now.addingTimeInterval(5), gracePeriod: 20)
        #expect(!seen)
        #expect(tracker.source?.sourceBundleID == teams.bundleID)

        // A Zoom call does not keep the Teams recording alive.
        let zoomCandidate = try #require(resolve(processes: [audio(zoom)]))
        let zoomExtends = tracker.observe(candidate: zoomCandidate, now: now.addingTimeInterval(40), gracePeriod: 20)
        #expect(zoomExtends)

        // Teams comes back under a new session id with only dedicated-app evidence: still the call.
        let rejoin = MeetingCandidate(
            id: "app:com.microsoft.teams2", platform: .teams, appName: "Teams", url: nil,
            evidence: [.dedicatedApp, .foregroundApp], startedAt: now, meetingTitle: nil,
            sourceBundleID: teams.bundleID
        )
        let rejoined = tracker.observe(candidate: rejoin, now: now.addingTimeInterval(50), gracePeriod: 20)
        #expect(!rejoined)
        #expect(tracker.lastSeenAt == now.addingTimeInterval(50))
    }

    @Test("a source taken from an observed candidate never re-binds by platform")
    func observedSourceDoesNotRebind() throws {
        let teams = Self.nativeCalls[0]
        let zoom = Self.nativeCalls[3]
        let meet = MeetingCandidate(
            id: "googleMeet:meet.google.com/abc-defg-hij", platform: .googleMeet, appName: "Chrome",
            url: "meet.google.com/abc-defg-hij", evidence: [.browserURL, .audioInputProcess],
            startedAt: now, meetingTitle: nil, sourceBundleID: "com.google.Chrome"
        )
        let source = MeetingAutoStopSource(candidate: meet)
        #expect(!MeetingAutoStopPolicy.matches(candidate: try #require(resolve(processes: [audio(teams)])), source: source))
        #expect(!MeetingAutoStopPolicy.matches(candidate: try #require(resolve(processes: [audio(zoom)])), source: source))
    }

    // MARK: Binding window

    @Test("a URL-armed source can bind during the first 15 minutes of the recording, not after")
    func bindingWindow() throws {
        let teams = Self.nativeCalls[0]
        let candidate = try #require(resolve(processes: [audio(teams)]))
        let url = try urlSource(teams.url)

        var early = MeetingAutoStopTracker()
        early.arm(source: url)
        early.markRecordingStarted(now: now)
        let atEdge = now.addingTimeInterval(MeetingAutoStopTracker.platformBindingWindow)
        #expect(early.matches(candidate, now: atEdge))
        _ = early.observe(candidate: candidate, now: atEdge, gracePeriod: 20)
        #expect(early.lastSeenAt == atEdge)

        var late = MeetingAutoStopTracker()
        late.arm(source: url)
        late.markRecordingStarted(now: now)
        let pastEdge = atEdge.addingTimeInterval(1)
        #expect(!late.matches(candidate, now: pastEdge))
        let lateSeen = late.observe(candidate: candidate, now: pastEdge, gracePeriod: 20)
        #expect(!lateSeen)
        #expect(late.lastSeenAt == nil)
        #expect(late.source?.sourceBundleID == nil)

        // While the recording is still preparing the window has not started to run out.
        var preparing = MeetingAutoStopTracker()
        preparing.arm(source: url)
        preparing.observeBeforeRecordingStarted(candidate: candidate)
        #expect(preparing.source?.sourceBundleID == teams.bundleID)

        // Re-arming starts over: no leftover deadline from the previous recording.
        late.arm(source: url)
        #expect(late.matches(candidate, now: pastEdge))
    }

    // MARK: Monitor scoping

    @Test("a stale browser tab with another room cannot hide the native call from a URL-armed source")
    func staleBrowserTabDoesNotShadowNativeCall() throws {
        let teams = Self.nativeCalls[0]
        let source = try urlSource(teams.url)
        let launcher = try #require(MeetingURLNormalizer.normalize(
            "https://teams.microsoft.com/dl/launcher/launcher.html?url=%2F_%23%2Fl%2Fmeetup-join%2F19%3Ameeting_ZDI5YjQ3MTktNzI2%40thread.v2%2F0&type=meetup-join"
        ))
        let staleTab = BrowserMeetingContext(
            bundleID: "com.google.Chrome", appName: "Chrome", url: launcher.url,
            normalizedID: launcher.id, platform: launcher.platform, isFocused: false
        )
        let calendar = CalendarEventContext(id: "evt-1", title: "Weekly sync")
        func snapshot(_ tabs: [BrowserMeetingContext]) -> MeetingSignalSnapshot {
            MeetingSignalSnapshot(
                micActive: true, cameraActive: false, calendarEvent: calendar, runningApps: [],
                browserMeetings: tabs, audioInputProcesses: [audio(teams)], foregroundBundleID: nil, now: now
            )
        }

        // Unscoped, the resolver prefers the browser tab, and the tab's room conflicts with the link.
        let shadowed = try #require(resolver().resolve(snapshot([staleTab])))
        #expect(shadowed.sourceBundleID == "com.google.Chrome")
        #expect(!MeetingAutoStopPolicy.matches(candidate: shadowed, source: source))

        let scoped = MeetingAutoStopPolicy.scopedBrowserMeetings([staleTab], source: source)
        #expect(scoped.isEmpty)
        let native = try #require(resolver().resolve(snapshot(scoped)))
        #expect(native.sourceBundleID == teams.bundleID)
        #expect(MeetingAutoStopPolicy.matches(candidate: native, source: source))
    }

    @Test("a seen browser source still sees the next room in the same browser as a different call")
    func nextRoomInSameBrowserIsNotTheSameCall() throws {
        let roomA = try #require(MeetingURLNormalizer.normalize("https://meet.google.com/abc-defg-hij"))
        let roomB = try #require(MeetingURLNormalizer.normalize("https://meet.google.com/zzz-yyyy-xxx"))
        let seenInRoomA = MeetingCandidate(
            id: roomA.id, platform: .googleMeet, appName: "Chrome", url: roomA.url,
            evidence: [.browserURL, .audioInputProcess], startedAt: now, meetingTitle: nil,
            sourceBundleID: "com.google.Chrome"
        )
        let source = MeetingAutoStopSource(candidate: seenInRoomA)
        let tabInRoomB = BrowserMeetingContext(
            bundleID: "com.google.Chrome", appName: "Chrome", url: roomB.url,
            normalizedID: roomB.id, platform: roomB.platform, isFocused: true
        )
        let chromeAudio = AudioProcessActivity(
            pid: 77, bundleID: "com.google.Chrome", appName: "Chrome",
            isRunningInput: true, isRunningOutput: true
        )
        let snapshot = MeetingSignalSnapshot(
            micActive: true, cameraActive: false, calendarEvent: nil, runningApps: [],
            browserMeetings: [tabInRoomB], audioInputProcesses: [chromeAudio],
            foregroundBundleID: "com.google.Chrome", now: now
        )
        // What the monitor feeds the resolver while it follows this source.
        let scoped = snapshot.replacingBrowserMeetings(
            MeetingAutoStopPolicy.scopedBrowserMeetings(snapshot.browserMeetings, source: source)
        )
        let candidate = try #require(resolver().resolve(scoped))
        // Room B's tab must stay visible: dropping it leaves room-less Chrome audio, which the
        // seen source would take for room A and the recording would run on through meeting B.
        #expect(!MeetingAutoStopPolicy.matches(candidate: candidate, source: source))
    }

    @Test("scoping keeps the tab in the source's own room, and everything once the source is bound or room-less")
    func scopedBrowserMeetings() throws {
        let roomA = try #require(MeetingURLNormalizer.normalize("https://meet.google.com/abc-defg-hij"))
        let roomB = try #require(MeetingURLNormalizer.normalize("https://meet.google.com/zzz-yyyy-xxx"))
        func tab(_ room: NormalizedMeetingURL) -> BrowserMeetingContext {
            BrowserMeetingContext(
                bundleID: "com.google.Chrome", appName: "Chrome", url: room.url,
                normalizedID: room.id, platform: room.platform, isFocused: false
            )
        }
        let tabs = [tab(roomA), tab(roomB)]
        let urlSource = try urlSource("https://meet.google.com/abc-defg-hij")
        #expect(MeetingAutoStopPolicy.scopedBrowserMeetings(tabs, source: urlSource) == [tab(roomA)])

        let nativeCandidate = try #require(resolve(processes: [audio(Self.nativeCalls[0])]))
        let roomless = MeetingAutoStopSource(candidate: nativeCandidate)
        #expect(roomless.normalizedURL == nil)
        #expect(MeetingAutoStopPolicy.scopedBrowserMeetings(tabs, source: roomless) == tabs)

        let bound = urlSource.refined(with: nativeCandidate)
        #expect(bound.sourceBundleID == Self.nativeCalls[0].bundleID)
        #expect(MeetingAutoStopPolicy.scopedBrowserMeetings(tabs, source: bound) == tabs)
    }

    @Test("Control Center attribution proves a call only for the source's own platform")
    func attributionIsLiveness() throws {
        let teamsURL = try urlSource(Self.nativeCalls[0].url)
        #expect(MeetingAutoStopPolicy.attributionIsLiveness(bundleID: "com.microsoft.teams2", source: teamsURL))
        #expect(MeetingAutoStopPolicy.attributionIsLiveness(bundleID: "com.microsoft.teams", source: teamsURL))
        #expect(!MeetingAutoStopPolicy.attributionIsLiveness(bundleID: "us.zoom.xos", source: teamsURL))
        #expect(!MeetingAutoStopPolicy.attributionIsLiveness(bundleID: "com.google.Chrome", source: teamsURL))

        let bound = teamsURL.refined(with: try #require(resolve(processes: [audio(Self.nativeCalls[0])])))
        #expect(MeetingAutoStopPolicy.attributionIsLiveness(bundleID: "com.microsoft.teams2", source: bound))

        let meetCandidate = MeetingCandidate(
            id: "googleMeet:meet.google.com/abc-defg-hij", platform: .googleMeet, appName: "Chrome",
            url: "meet.google.com/abc-defg-hij", evidence: [.browserURL], startedAt: now,
            meetingTitle: nil, sourceBundleID: "com.google.Chrome"
        )
        #expect(!MeetingAutoStopPolicy.attributionIsLiveness(
            bundleID: "com.google.Chrome", source: MeetingAutoStopSource(candidate: meetCandidate)
        ))
    }
}
