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

/// What to do about a recording whose call signal is gone.
enum MeetingSignalLossAction: Equatable {
    case none
    /// First loss: raise the persistent sidebar alert and show the toast.
    case raiseAlertAndToast
    /// The alert is already up; show the toast again.
    case reofferToast
}

/// The user-facing side of signal loss for one recording. The recording is never stopped from
/// here: this only decides when to tell the user, and what stays on screen until they answer.
struct MeetingSignalLossPromptState: Equatable {
    /// How long a toast the user did not answer stays quiet before it is offered again.
    static let reofferInterval: TimeInterval = 5 * 60

    private var isAlertRaised = false
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
    mutating func evaluateSignalLoss(now: Date, transcriptQuietPeriod: TimeInterval) -> MeetingSignalLossAction {
        guard !isDismissedForRecording,
              !hasRecentTranscriptActivity(now: now, quietPeriod: transcriptQuietPeriod) else {
            return .none
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
    let hasObservedCandidate: Bool

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        hasObservedCandidate: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.hasObservedCandidate = hasObservedCandidate
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
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
        self.hasObservedCandidate = false
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
            hasObservedCandidate: true
        )
    }
}

struct MeetingAutoStopTracker: Equatable {
    private(set) var source: MeetingAutoStopSource?
    private(set) var lastSeenAt: Date?
    private var observedBeforeRecordingStarted = false

    var isArmed: Bool {
        source != nil
    }

    mutating func arm(source: MeetingAutoStopSource?) {
        self.source = source
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
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

        if let candidate,
           MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) {
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
    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        // Missing room evidence permits a media fallback; conflicting room
        // evidence must never extend the original recording, even in one browser.
        if let room = source.normalizedURL, let candidateRoom = candidate.url,
           room != candidateRoom { return false }
        if candidate.id == source.candidateID
            || candidate.suppressionID == source.suppressionID
            || (source.normalizedURL != nil && candidate.url == source.normalizedURL) {
            return true
        }
        guard let sourceBundle = source.sourceBundleID,
              let candidateBundle = candidate.sourceBundleID,
              bundleIDsReferToSameApp(sourceBundle, candidateBundle) else { return false }
        // Native sources have no room identity. Browser sources need observed
        // media attribution when their room URL is temporarily unavailable.
        return source.normalizedURL == nil
            || (source.hasObservedCandidate && candidate.evidence.contains(.audioInputProcess))
    }

    static func bundleIDsReferToSameApp(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        return lhs == rhs || lhs.hasPrefix("\(rhs).") || rhs.hasPrefix("\(lhs).")
    }
}
