import Foundation

enum MeetingRecordingStartOrigin: Equatable {
    case manual
    case detectedPrompt
    case calendarAutoRecord
    case scheduledMeetingPrompt
    case joinAndRecord

    var tracksMeetingSource: Bool {
        switch self {
        case .manual:
            return false
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return true
        }
    }

    var signalLossResponse: MeetingSignalLossResponse {
        switch self {
        case .manual:
            return .none
        case .detectedPrompt:
            return .warnOnly
        case .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return .warnOnly
        }
    }

    func signalLossSource(
        explicitSource: MeetingAutoStopSource?,
        recentSource: @autoclosure () -> MeetingAutoStopSource?
    ) -> MeetingAutoStopSource? {
        switch self {
        case .manual:
            return nil
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return explicitSource ?? recentSource()
        }
    }
}

enum MeetingSignalLossResponse: Equatable {
    case none
    case warnOnly
}

struct MeetingSignalLossPromptState: Equatable {
    private(set) var isPromptSuppressed = false
    private(set) var isDismissedForRecording = false
    private(set) var lastTranscriptActivityAt: Date?

    var canPresentPrompt: Bool {
        !isPromptSuppressed && !isDismissedForRecording
    }

    mutating func resetForRecording() {
        isPromptSuppressed = false
        isDismissedForRecording = false
        lastTranscriptActivityAt = nil
    }

    mutating func noteTranscriptActivity(now: Date) {
        lastTranscriptActivityAt = now
    }

    func hasRecentTranscriptActivity(now: Date, quietPeriod: TimeInterval) -> Bool {
        guard let lastTranscriptActivityAt else { return false }
        return now.timeIntervalSince(lastTranscriptActivityAt) < quietPeriod
    }

    mutating func markPromptPresented() {
        isPromptSuppressed = true
    }

    mutating func markSourceRecovered() {
        isPromptSuppressed = false
    }

    mutating func markDismissedByUser() {
        isPromptSuppressed = true
        isDismissedForRecording = true
    }

    mutating func markAutoDismissed() {
        isPromptSuppressed = true
    }
}

struct MeetingAutoStopSource: Equatable {
    let candidateID: String?
    let suppressionID: String?
    let normalizedURL: String?
    let sourceBundleID: String?
    /// The meeting platform when it is known (never `.unknown`). A source armed from a calendar
    /// link knows its platform before it has seen any candidate.
    let platform: MeetingCandidate.Platform?
    let hasObservedCandidate: Bool

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        platform: MeetingCandidate.Platform?,
        hasObservedCandidate: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.platform = platform
        self.hasObservedCandidate = hasObservedCandidate
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
        self.platform = Self.knownPlatform(candidate.platform)
        self.hasObservedCandidate = true
    }

    init?(meetingURL: URL) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
        self.platform = Self.knownPlatform(normalized.platform)
        self.hasObservedCandidate = false
    }

    private static func knownPlatform(_ platform: MeetingCandidate.Platform) -> MeetingCandidate.Platform? {
        platform == .unknown ? nil : platform
    }

    func refined(with candidate: MeetingCandidate) -> MeetingAutoStopSource {
        let refinedSuppressionID = candidate.suppressionID == candidate.id
            ? suppressionID ?? candidate.suppressionID
            : candidate.suppressionID
        return MeetingAutoStopSource(
            candidateID: candidateID ?? candidate.id,
            suppressionID: refinedSuppressionID,
            normalizedURL: normalizedURL ?? candidate.url,
            sourceBundleID: sourceBundleID ?? candidate.sourceBundleID,
            platform: platform ?? Self.knownPlatform(candidate.platform),
            hasObservedCandidate: true
        )
    }
}

struct MeetingAutoStopTracker: Equatable {
    private(set) var source: MeetingAutoStopSource?
    private(set) var lastSeenAt: Date?
    private var observedBeforeRecordingStarted = false
    private var platformBindingDeadline: Date?

    /// How long after the recording starts a source armed from a calendar link may still bind to
    /// the native app that hosts the call. After that, only the room URL or an identity that was
    /// seen earlier can keep the recording tied to its call.
    static let platformBindingWindow: TimeInterval = 15 * 60

    var isArmed: Bool {
        source != nil
    }

    mutating func arm(source: MeetingAutoStopSource?) {
        self.source = source
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
        platformBindingDeadline = nil
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
        platformBindingDeadline = nil
    }

    /// Whether `candidate` is the call this recording follows, as of `now`.
    func matches(_ candidate: MeetingCandidate?, now: Date) -> Bool {
        guard let candidate, let source else { return false }
        return MeetingAutoStopPolicy.matches(
            candidate: candidate,
            source: source,
            allowsPlatformBinding: platformBindingDeadline.map { now <= $0 } ?? true
        )
    }

    mutating func observeBeforeRecordingStarted(candidate: MeetingCandidate?) {
        guard let currentSource = source,
              let candidate,
              MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) else {
            return
        }
        source = currentSource.refined(with: candidate)
        observedBeforeRecordingStarted = true
    }

    mutating func markRecordingStarted(now: Date) {
        platformBindingDeadline = now.addingTimeInterval(Self.platformBindingWindow)
        guard observedBeforeRecordingStarted, lastSeenAt == nil else { return }
        lastSeenAt = now
        observedBeforeRecordingStarted = false
    }

    mutating func observe(
        candidate: MeetingCandidate?,
        now: Date,
        gracePeriod: TimeInterval
    ) -> Bool {
        guard let currentSource = source else {
            return false
        }

        if let candidate, matches(candidate, now: now) {
            source = currentSource.refined(with: candidate)
            lastSeenAt = now
            return false
        }

        guard let lastSeenAt else {
            return false
        }

        return now.timeIntervalSince(lastSeenAt) >= gracePeriod
    }
}

enum MeetingAutoStopPolicy {
    static func matches(
        candidate: MeetingCandidate,
        source: MeetingAutoStopSource,
        allowsPlatformBinding: Bool = true
    ) -> Bool {
        // Missing room evidence permits a media fallback; conflicting room
        // evidence must never extend the original recording, even in one browser.
        if let room = source.normalizedURL, let candidateRoom = candidate.url,
           room != candidateRoom { return false }
        if candidate.id == source.candidateID
            || candidate.suppressionID == source.suppressionID
            || (source.normalizedURL != nil && candidate.url == source.normalizedURL) {
            return true
        }
        if allowsPlatformBinding, bindsByPlatform(candidate: candidate, source: source) { return true }
        guard let sourceBundle = source.sourceBundleID,
              let candidateBundle = candidate.sourceBundleID,
              bundleIDsReferToSameApp(sourceBundle, candidateBundle) else { return false }
        // Native sources have no room identity. Browser sources need observed
        // media attribution when their room URL is temporarily unavailable.
        return source.normalizedURL == nil
            || isNativeMeetingApp(sourceBundle)
            || (source.hasObservedCandidate && candidate.evidence.contains(.audioInputProcess))
    }

    /// A recording started from a calendar link knows the room URL but not which app hosts the
    /// call. Native clients (Teams, Zoom, Webex, FaceTime, Slack) expose no room URL, so the
    /// link can never match them. The first room-less candidate from a native client of the
    /// link's own platform, backed by audio-process or foreground-app evidence, binds the source.
    /// Another platform, a candidate with a room URL (it would have matched or conflicted above),
    /// a browser, and a source that has already bound all stay out.
    static func bindsByPlatform(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        guard !source.hasObservedCandidate,
              source.sourceBundleID == nil,
              let platform = source.platform,
              candidate.platform == platform,
              candidate.url == nil,
              let bundleID = candidate.sourceBundleID,
              isNativeMeetingApp(bundleID) else { return false }
        return !candidate.evidence.isDisjoint(with: [.audioInputProcess, .dedicatedApp])
    }

    /// While a recording follows a source, a browser tab in some other room is not evidence for
    /// it. It must not shadow lower-precedence evidence either: the resolver prefers a browser tab
    /// over the native app, so a stale tab (a Teams launcher page left behind by the hand-off to
    /// the desktop app) would hide the very call the source is waiting for.
    static func scopedBrowserMeetings(
        _ meetings: [BrowserMeetingContext],
        source: MeetingAutoStopSource
    ) -> [BrowserMeetingContext] {
        guard let room = source.normalizedURL else { return meetings }
        return meetings.filter { $0.url == room }
    }

    /// Whether a Control Center mic or camera attribution to `bundleID` is enough, on its own,
    /// to call that app's candidate live. The full-duplex check ran during discovery for a source
    /// that was seen; a source armed from a link was never seen, so an attribution to a native
    /// client of the link's own platform stands in for it.
    static func attributionIsLiveness(bundleID: String, source: MeetingAutoStopSource) -> Bool {
        guard let app = MeetingCandidateResolver.dedicatedApps[bundleID] else { return false }
        if let sourceBundle = source.sourceBundleID {
            return bundleIDsReferToSameApp(bundleID, sourceBundle)
        }
        return source.platform == app.platform
    }

    static func isNativeMeetingApp(_ bundleID: String) -> Bool {
        MeetingCandidateResolver.dedicatedApps[bundleID] != nil
    }

    static func bundleIDsReferToSameApp(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        return lhs == rhs || lhs.hasPrefix("\(rhs).") || rhs.hasPrefix("\(lhs).")
    }
}
