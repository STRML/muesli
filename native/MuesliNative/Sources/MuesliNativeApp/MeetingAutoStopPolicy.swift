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
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return .stopWithNotice
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
    /// The call is over: stop the recording and say so.
    case stopWithNotice
}

/// What to do about a recording whose call signal is gone.
enum MeetingSignalLossAction: Equatable {
    case none
    /// First loss: raise the persistent sidebar alert and show the toast.
    case raiseAlertAndToast
    /// The alert is already up; show the toast again.
    case reofferToast
    /// The call is over and the recording follows it: stop, then tell the user.
    case stopAndNotify
}

/// The user-facing side of signal loss for one recording. The recording is never stopped from
/// here: this only decides when to tell the user, and what stays on screen until they answer.
struct MeetingSignalLossPromptState: Equatable {
    /// How long a toast the user did not answer stays quiet before it is offered again.
    static let reofferInterval: TimeInterval = 5 * 60

    private var isAlertRaised = false
    private var isStopIssued = false
    private(set) var isDismissedForRecording = false
    private var lastOfferedAt: Date?
    private(set) var lastTranscriptActivityAt: Date?

    /// The sidebar shows "Call ended?" while this holds. It stays until the user stops or
    /// dismisses, or the call signal returns.
    var isCallEndedAlertActive: Bool { isAlertRaised }

    mutating func resetForRecording() {
        self = MeetingSignalLossPromptState()
    }

    mutating func noteTranscriptActivity(now: Date) {
        lastTranscriptActivityAt = now
    }

    /// Speech from the remote side is evidence that the call is still going. The user's own
    /// voice is not: the mic keeps hearing them after the call ends.
    mutating func noteTranscriptActivity(from speaker: String, now: Date) {
        guard speaker != Self.ownVoiceSpeakerLabel else { return }
        noteTranscriptActivity(now: now)
    }

    static let ownVoiceSpeakerLabel = "You"

    func hasRecentTranscriptActivity(now: Date, quietPeriod: TimeInterval) -> Bool {
        guard let lastTranscriptActivityAt else { return false }
        return now.timeIntervalSince(lastTranscriptActivityAt) < quietPeriod
    }

    /// Call on every observation in which the source is gone past its grace period.
    mutating func evaluateSignalLoss(
        now: Date,
        transcriptQuietPeriod: TimeInterval,
        response: MeetingSignalLossResponse = .warnOnly
    ) -> MeetingSignalLossAction {
        guard !isDismissedForRecording,
              !hasRecentTranscriptActivity(now: now, quietPeriod: transcriptQuietPeriod) else {
            return .none
        }
        if response == .stopWithNotice {
            // The stop is decided once; the recording is gone after it.
            guard !isStopIssued else { return .none }
            isStopIssued = true
            return .stopAndNotify
        }
        guard isAlertRaised, let lastOfferedAt else {
            isAlertRaised = true
            lastOfferedAt = now
            return .raiseAlertAndToast
        }
        guard now.timeIntervalSince(lastOfferedAt) >= Self.reofferInterval else { return .none }
        self.lastOfferedAt = now
        return .reofferToast
    }

    mutating func markSourceRecovered() {
        isAlertRaised = false
        lastOfferedAt = nil
    }

    mutating func markDismissedByUser() {
        isAlertRaised = false
        isDismissedForRecording = true
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
    /// Whether the latest observation found the call. Nil until the first one.
    private var lastObservationMatched: Bool?
    private var observedBeforeRecordingStarted = false
    private var platformBindingDeadline: Date?

    /// How long after the recording starts a source armed from a calendar link may still bind to
    /// the native app that hosts the call. After that, only the room URL or an identity that was
    /// seen earlier can keep the recording tied to its call.
    static let platformBindingWindow: TimeInterval = 15 * 60

    var isArmed: Bool {
        source != nil
    }

    /// The call was seen during this recording and the latest observation no longer finds it.
    /// Unlike the signal-loss alert this does not wait out the grace period: it only words the
    /// scheduled-end popup, which has no use for a delay.
    var hasLostSource: Bool {
        source != nil && lastSeenAt != nil && lastObservationMatched == false
    }

    mutating func arm(source: MeetingAutoStopSource?) {
        self.source = source
        lastSeenAt = nil
        lastObservationMatched = nil
        observedBeforeRecordingStarted = false
        platformBindingDeadline = nil
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        lastObservationMatched = nil
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
            lastObservationMatched = true
            return false
        }
        lastObservationMatched = false

        guard let lastSeenAt else {
            return false
        }

        return now.timeIntervalSince(lastSeenAt) >= gracePeriod
    }
}

/// One observation of a recording that follows a call, from candidate to decision. The controller
/// owns the state and acts on the result; keeping the step pure lets scenarios replay a whole call.
enum MeetingCallEndPolicy {
    /// How long the call may be missing before it counts as over.
    static let gracePeriod: TimeInterval = 20
    /// How long remote speech must have been absent before the recording stops.
    static let transcriptQuietPeriod: TimeInterval = 45

    static func step(
        tracker: inout MeetingAutoStopTracker,
        prompt: inout MeetingSignalLossPromptState,
        response: MeetingSignalLossResponse,
        candidate: MeetingCandidate?,
        now: Date
    ) -> MeetingSignalLossAction {
        guard tracker.isArmed else { return .none }
        if tracker.matches(candidate, now: now) {
            prompt.markSourceRecovered()
        }
        guard tracker.observe(candidate: candidate, now: now, gracePeriod: gracePeriod),
              response != .none else { return .none }
        return prompt.evaluateSignalLoss(now: now, transcriptQuietPeriod: transcriptQuietPeriod, response: response)
    }

    /// The scheduled-end popup is for a call that may still be going. Once the tracker has lost the
    /// call, the call-ended notice owns the moment.
    static func showsScheduledEndPopup(tracker: MeetingAutoStopTracker) -> Bool {
        !tracker.hasLostSource
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

    /// The candidate a recording that follows `source` may treat as its call, or nil. Discovery
    /// accepts a focused meeting tab on its own (it is how a prompt appears); liveness needs media
    /// too, because the tab stays on the post-call page after the call ends.
    static func followedCandidate(_ candidate: MeetingCandidate?, source: MeetingAutoStopSource) -> MeetingCandidate? {
        guard let candidate,
              matches(candidate: candidate, source: source),
              !candidate.evidence.isDisjoint(with: [.micActive, .cameraActive, .audioInputProcess]) else {
            return nil
        }
        return candidate
    }

    /// While a recording is armed from a link and has not bound to anything, a browser tab in some
    /// other room is not evidence for it, and it must not shadow lower-precedence evidence: the
    /// resolver prefers a browser tab over the native app, so a stale tab (a Teams launcher page
    /// left behind by the hand-off to the desktop app) would hide the very call the source is
    /// waiting for.
    ///
    /// Once the source is bound the tabs stay. A bound browser source accepts room-less audio from
    /// its own browser, so hiding the next room's tab would let a second meeting in the same
    /// browser pass for the first and the recording would run on through it.
    static func scopedBrowserMeetings(
        _ meetings: [BrowserMeetingContext],
        source: MeetingAutoStopSource
    ) -> [BrowserMeetingContext] {
        guard source.sourceBundleID == nil, let room = source.normalizedURL else { return meetings }
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

    /// Adds what Control Center attributes to a browser or meeting app to the CoreAudio processes.
    /// While a recording follows `source` the monitor runs no CoreAudio scan, so this is the only
    /// audio evidence it has. A bound source takes attributions to its own app only.
    static func livenessAudioProcesses(
        _ coreAudioProcesses: [AudioProcessActivity],
        sensorAttributions: SensorAttributionSnapshot,
        runningProcessIDsByBundleID: [String: pid_t],
        source: MeetingAutoStopSource?
    ) -> [AudioProcessActivity] {
        var processes = coreAudioProcesses
        let existingBundleIDs = Set(coreAudioProcesses.map(\.bundleID))
        let attributedBundleIDs = sensorAttributions.micBundleIDs
            .union(sensorAttributions.cameraBundleIDs)
            .sorted()

        for attributedBundleID in attributedBundleIDs {
            let bundleID: String
            if let sourceBundleID = source?.sourceBundleID {
                guard bundleIDsReferToSameApp(attributedBundleID, sourceBundleID) else { continue }
                bundleID = sourceBundleID
            } else {
                bundleID = attributedBundleID
            }

            let appName = MeetingCandidateResolver.browserApps[bundleID]
                ?? MeetingCandidateResolver.dedicatedApps[bundleID]?.name
            guard let appName else { continue }
            guard !existingBundleIDs.contains(where: { bundleIDsReferToSameApp($0, bundleID) }) else {
                continue
            }

            processes.append(AudioProcessActivity(
                pid: runningProcessIDsByBundleID[bundleID] ?? 0,
                bundleID: bundleID,
                appName: appName,
                isRunningInput: true,
                // Full-duplex was established during discovery. While tracking that source,
                // a current attribution is sufficient liveness evidence without another HAL
                // process enumeration.
                isRunningOutput: source.map { attributionIsLiveness(bundleID: bundleID, source: $0) } ?? false
            ))
        }

        return processes
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
