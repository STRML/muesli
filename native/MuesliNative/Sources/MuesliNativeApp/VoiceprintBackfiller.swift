import FluidAudio
import Foundation
import MuesliCore

enum VoiceprintBackfillState: Equatable, Sendable {
    case idle
    case running(completed: Int, total: Int, learned: Int, currentTitle: String)
    case finished(learned: Int, scanned: Int)
    case failed(String)
}

struct TranscriptSpeakerInterval: Equatable, Sendable {
    let speakerName: String
    let startSeconds: Double
    let endSeconds: Double
}

/// Matches diarization clusters and embeddings from saved recordings against
/// named speaker intervals in existing meeting transcripts, without re-transcribing.
enum VoiceprintBackfiller {
    static let maxEstimatedTurnDuration: TimeInterval = 30.0
    static let minimumMajorityOverlapRatio: Double = 0.60
    static let minimumClusterCoverageRatio: Double = 0.25
    private static let secondsPerDay: Double = 86_400

    static func match(
        candidate: VoiceprintBackfillCandidate,
        segments: [TimedSpeakerSegment],
        speakerCentroids: [String: [Float]],
        profiles: [SpeakerProfileSummary],
        minimumSpeechSeconds: Double = SpeakerCentroidBuilder.minimumVoiceprintSeconds,
        calendar: Calendar = .current
    ) -> [BackfilledVoiceprintMatch] {
        guard !segments.isEmpty else { return [] }

        let maxSegmentEnd = segments.map { Double($0.endTimeSeconds) }.max() ?? 0
        let recordingEnd = max(candidate.durationSeconds, maxSegmentEnd)
        let intervals = parseTranscriptIntervals(
            rawTranscript: candidate.rawTranscript,
            startTime: candidate.startTime,
            recordingDuration: recordingEnd > 0 ? recordingEnd : nil,
            calendar: calendar
        )
        guard !intervals.isEmpty else { return [] }

        // Map known speakers for this meeting:
        // 1) Explicit meeting_speakers rows (handles private meetings where label is "Speaker 1")
        // 2) Existing speaker profiles matched case-insensitively by transcript speaker name
        var existingByLowerLabel: [String: (profileID: Int64, label: String)] = [:]
        var existingLabelByProfileID: [Int64: String] = [:]
        var alreadyLearnedProfileIDs = Set<Int64>()
        for speaker in candidate.existingSpeakers {
            guard let profileID = speaker.profileID else { continue }
            let key = normalizedKey(speaker.label)
            if !key.isEmpty, existingByLowerLabel[key] == nil {
                existingByLowerLabel[key] = (profileID, speaker.label)
            }
            if existingLabelByProfileID[profileID] == nil {
                existingLabelByProfileID[profileID] = speaker.label
            }
            if speaker.hasVoiceprintFromMeeting {
                alreadyLearnedProfileIDs.insert(profileID)
            }
        }

        var profilesByLowerName: [String: (id: Int64, name: String)] = [:]
        for profile in profiles {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isReservedName(trimmed) else { continue }
            let key = trimmed.lowercased()
            if profilesByLowerName[key] == nil {
                profilesByLowerName[key] = (profile.id, trimmed)
            }
        }

        func resolvedTarget(for intervalSpeakerName: String) -> (profileID: Int64, label: String)? {
            let key = normalizedKey(intervalSpeakerName)
            guard !key.isEmpty else { return nil }
            if let existing = existingByLowerLabel[key] {
                return existing
            }
            guard !isReservedName(intervalSpeakerName),
                  let profile = profilesByLowerName[key] else {
                return nil
            }
            return (profile.id, profile.name)
        }

        struct ClusterClaim {
            let profileID: Int64
            let label: String
            let overlapSeconds: Double
            let centroid: [Float]
        }

        let segmentsByCluster = Dictionary(grouping: segments, by: \.speakerId)
        var claimsByProfileID: [Int64: [ClusterClaim]] = [:]

        for clusterID in segmentsByCluster.keys.sorted() {
            let clusterSegments = segmentsByCluster[clusterID] ?? []
            let speechSeconds = clusterSegments.reduce(0.0) { $0 + Double(max(0, $1.durationSeconds)) }
            guard speechSeconds >= minimumSpeechSeconds, speechSeconds > 0 else { continue }

            guard let centroid = weightedCentroid(of: clusterSegments) ?? validNormalized(speakerCentroids[clusterID]) else {
                continue
            }

            var totalOverlap: Double = 0
            var overlapByProfile: [Int64: Double] = [:]
            var labelByProfile: [Int64: String] = [:]

            for segment in clusterSegments {
                let segStart = Double(segment.startTimeSeconds)
                let segEnd = Double(segment.endTimeSeconds)
                guard segEnd > segStart else { continue }

                for interval in intervals {
                    let overlap = min(segEnd, interval.endSeconds) - max(segStart, interval.startSeconds)
                    guard overlap > 0 else { continue }
                    totalOverlap += overlap
                    if let target = resolvedTarget(for: interval.speakerName) {
                        overlapByProfile[target.profileID, default: 0] += overlap
                        if labelByProfile[target.profileID] == nil {
                            labelByProfile[target.profileID] = target.label
                        }
                    }
                }
            }

            guard totalOverlap > 0,
                  let (bestProfileID, bestOverlap) = overlapByProfile.max(by: { lhs, rhs in
                      if lhs.value == rhs.value { return lhs.key > rhs.key }
                      return lhs.value < rhs.value
                  }) else {
                continue
            }

            guard bestOverlap / totalOverlap >= minimumMajorityOverlapRatio,
                  bestOverlap / speechSeconds >= minimumClusterCoverageRatio else {
                continue
            }

            let targetLabel = existingLabelByProfileID[bestProfileID]
                ?? labelByProfile[bestProfileID]
                ?? profiles.first(where: { $0.id == bestProfileID })?.name
                ?? ""
            guard !targetLabel.isEmpty else { continue }

            claimsByProfileID[bestProfileID, default: []].append(
                ClusterClaim(
                    profileID: bestProfileID,
                    label: targetLabel,
                    overlapSeconds: bestOverlap,
                    centroid: centroid
                )
            )
        }

        var results: [BackfilledVoiceprintMatch] = []
        for profileID in claimsByProfileID.keys.sorted() {
            guard !alreadyLearnedProfileIDs.contains(profileID),
                  let claims = claimsByProfileID[profileID],
                  !claims.isEmpty else {
                continue
            }
            let mergedCentroid: [Float]?
            if claims.count == 1 {
                mergedCentroid = validNormalized(claims[0].centroid)
            } else {
                mergedCentroid = combinedWeightedCentroid(
                    claims.map { (vector: $0.centroid, weight: Float($0.overlapSeconds)) }
                )
            }
            guard let finalCentroid = mergedCentroid else { continue }
            let primaryLabel = existingLabelByProfileID[profileID]
                ?? claims.max(by: { $0.overlapSeconds < $1.overlapSeconds })?.label
                ?? ""
            guard !primaryLabel.isEmpty else { continue }
            results.append(
                BackfilledVoiceprintMatch(
                    label: primaryLabel,
                    profileID: profileID,
                    centroid: finalCentroid
                )
            )
        }
        return results
    }

    // MARK: - Transcript timestamp parsing

    private enum ParsedTimestamp {
        case relativeSeconds(Double)
        case clockOrDuration(Double)
    }

    private struct RawParsedLine {
        let timestamp: ParsedTimestamp
        let speakerName: String?
    }

    static func parseTranscriptIntervals(
        rawTranscript: String,
        startTime: String? = nil,
        recordingDuration: TimeInterval? = nil,
        calendar: Calendar = .current
    ) -> [TranscriptSpeakerInterval] {
        let resumeMarker = MeetingResumePolicy.resumeSeparator.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedTranscript: String
        let effectiveStartTime: String?
        if !resumeMarker.isEmpty,
           let range = rawTranscript.range(of: resumeMarker, options: .backwards) {
            scopedTranscript = String(rawTranscript[range.upperBound...])
            effectiveStartTime = nil
        } else {
            scopedTranscript = rawTranscript
            effectiveStartTime = startTime
        }

        let normalized = scopedTranscript.replacingOccurrences(of: "\r\n", with: "\n")
        var rawLines: [RawParsedLine] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.hasPrefix("["),
                  let closeIndex = trimmed.firstIndex(of: "]") else {
                continue
            }
            let stampString = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex])
            guard let parsedTimestamp = parseTimestamp(stampString) else { continue }

            let remainder = trimmed[trimmed.index(after: closeIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerName = extractSpeakerName(from: remainder)
            rawLines.append(RawParsedLine(timestamp: parsedTimestamp, speakerName: speakerName))
        }

        guard !rawLines.isEmpty else { return [] }

        let anchorSeconds = resolveClockAnchor(
            rawLines: rawLines,
            startTime: effectiveStartTime,
            recordingDuration: recordingDuration,
            calendar: calendar
        )

        var resolvedEntries: [(start: Double, speakerName: String?)] = rawLines.map { line in
            let start: Double
            switch line.timestamp {
            case .relativeSeconds(let seconds):
                start = max(0, seconds)
            case .clockOrDuration(let secondsOfDay):
                if anchorSeconds == 0 {
                    start = max(0, secondsOfDay)
                } else {
                    start = wrappedSecondsOfDay(secondsOfDay - anchorSeconds)
                }
            }
            return (start: start, speakerName: line.speakerName)
        }

        // Preserve order for equal timestamps while ensuring chronological intervals.
        resolvedEntries = resolvedEntries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.start == rhs.element.start {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.start < rhs.element.start
            }
            .map(\.element)

        var intervals: [TranscriptSpeakerInterval] = []
        for index in resolvedEntries.indices {
            let entry = resolvedEntries[index]
            let end: Double
            if index + 1 < resolvedEntries.count {
                let nextStart = resolvedEntries[index + 1].start
                if nextStart > entry.start {
                    end = min(nextStart, entry.start + maxEstimatedTurnDuration)
                } else {
                    end = entry.start + 0.5
                }
            } else if let recordingDuration, recordingDuration > entry.start {
                end = min(recordingDuration, entry.start + maxEstimatedTurnDuration)
            } else {
                end = entry.start + maxEstimatedTurnDuration
            }

            if let speakerName = entry.speakerName, end > entry.start {
                intervals.append(
                    TranscriptSpeakerInterval(
                        speakerName: speakerName,
                        startSeconds: entry.start,
                        endSeconds: end
                    )
                )
            }
        }
        return intervals
    }

    private static func parseTimestamp(_ raw: String) -> ParsedTimestamp? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2,
           let minutes = Int(parts[0]), minutes >= 0,
           let seconds = Double(parts[1]), seconds >= 0, seconds < 60 {
            return .relativeSeconds(Double(minutes) * 60 + seconds)
        }
        if parts.count == 3,
           let hours = Int(parts[0]), (0..<24).contains(hours),
           let minutes = Int(parts[1]), (0..<60).contains(minutes),
           let seconds = Double(parts[2]), seconds >= 0, seconds < 60 {
            return .clockOrDuration(Double(hours) * 3600 + Double(minutes) * 60 + seconds)
        }
        return nil
    }

    private static func resolveClockAnchor(
        rawLines: [RawParsedLine],
        startTime: String?,
        recordingDuration: TimeInterval?,
        calendar: Calendar
    ) -> Double {
        let threePartValues: [Double] = rawLines.compactMap {
            if case .clockOrDuration(let seconds) = $0.timestamp { return seconds }
            return nil
        }
        guard let first = threePartValues.first, let last = threePartValues.last else {
            return 0
        }

        let startSeconds = startTime.flatMap { startSecondsOfDay($0, calendar: calendar) }
        if let duration = recordingDuration, duration > 0 {
            let tolerance = duration + 15.0
            let wallClockOffset = startSeconds.map { wrappedSecondsOfDay(first - $0) }
            let wallClockFits = wallClockOffset.map { $0 <= tolerance } ?? false
            let fromZeroFits = first <= tolerance

            if wallClockFits && !fromZeroFits, let startSeconds {
                return startSeconds
            }
            if fromZeroFits && !wallClockFits {
                return 0
            }
            if wallClockFits && fromZeroFits, let startSeconds {
                let lastWallClockOffset = wrappedSecondsOfDay(last - startSeconds)
                let lastWallClockFits = lastWallClockOffset <= tolerance
                let lastFromZeroFits = last <= tolerance
                if lastWallClockFits && !lastFromZeroFits {
                    return startSeconds
                }
                if lastFromZeroFits && !lastWallClockFits {
                    return 0
                }
                if let wallClockOffset, wallClockOffset < first {
                    return startSeconds
                }
                return 0
            }
            return first
        }

        if let startSeconds {
            let offset = wrappedSecondsOfDay(first - startSeconds)
            if first <= 300 && offset > 300 {
                return 0
            }
            if offset <= 3600 {
                return startSeconds
            }
        }
        return first <= 300 ? 0 : first
    }

    private static func startSecondsOfDay(_ raw: String, calendar: Calendar) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let date = MeetingHistoryDateParser(timeZone: calendar.timeZone).date(trimmed) else {
            return nil
        }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
            return nil
        }
        return Double(hour * 3600 + minute * 60 + second)
    }

    private static func wrappedSecondsOfDay(_ seconds: Double) -> Double {
        let mod = seconds.truncatingRemainder(dividingBy: secondsPerDay)
        return mod >= 0 ? mod : mod + secondsPerDay
    }

    private static func extractSpeakerName(from remainder: String) -> String? {
        guard let colon = remainder.firstIndex(of: ":") else { return nil }
        let candidate = remainder[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 64 else { return nil }
        return candidate
    }

    // MARK: - Helpers

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isReservedName(_ name: String) -> Bool {
        if DictationStore.isReservedSpeakerName(name) {
            return true
        }
        return name.range(of: #"^local\s+speaker(\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func validNormalized(_ vector: [Float]?) -> [Float]? {
        guard let vector, SpeakerVoiceprintMatcher.isUsable(vector) else { return nil }
        let unit = normalized(vector)
        return SpeakerVoiceprintMatcher.isUsable(unit) ? unit : nil
    }

    private static func weightedCentroid(of segments: [TimedSpeakerSegment]) -> [Float]? {
        let usable = segments.compactMap { segment -> (vector: [Float], weight: Float)? in
            guard SpeakerVoiceprintMatcher.isUsable(segment.embedding), segment.durationSeconds > 0 else {
                return nil
            }
            return (normalized(segment.embedding), segment.durationSeconds)
        }
        return combinedWeightedCentroid(usable)
    }

    private static func combinedWeightedCentroid(_ items: [(vector: [Float], weight: Float)]) -> [Float]? {
        let usable = items.compactMap { item -> (vector: [Float], weight: Float)? in
            guard item.weight > 0, item.weight.isFinite, let unit = validNormalized(item.vector) else {
                return nil
            }
            return (unit, item.weight)
        }
        let byDimension = Dictionary(grouping: usable, by: \.vector.count)
        guard let dominant = byDimension.max(by: { totalWeight($0.value) < totalWeight($1.value) })?.value,
              let dimension = dominant.first?.vector.count else {
            return nil
        }
        var sum = [Float](repeating: 0, count: dimension)
        for item in dominant {
            for index in 0..<dimension {
                sum[index] += item.vector[index] * item.weight
            }
        }
        guard SpeakerVoiceprintMatcher.isUsable(sum) else { return nil }
        let centroid = normalized(sum)
        return SpeakerVoiceprintMatcher.isUsable(centroid) ? centroid : nil
    }

    private static func totalWeight(_ items: [(vector: [Float], weight: Float)]) -> Float {
        items.reduce(0) { $0 + $1.weight }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }
}
