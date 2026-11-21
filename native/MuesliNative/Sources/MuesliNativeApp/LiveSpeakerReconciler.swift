import FluidAudio
import Foundation
import MuesliCore

/// Bridges live-call speaker labels and user edits (pre-adds, cluster renames/merges,
/// and single-turn overrides) onto post-call batch diarization and transcript formatting.
enum LiveSpeakerReconciler {
    /// Minimum overlap between a live-assigned speaker's intervals and a post-call cluster
    /// to transfer the live name onto that cluster.
    private static let minimumOverlapSeconds: TimeInterval = 0.4
    /// Minimum fraction of a post-call cluster's duration that must overlap the winning
    /// live speaker (prevents tiny boundary jitter from claiming an unnamed speaker).
    private static let minimumClusterCoverageRatio: Double = 0.25
    /// Winning live speaker must exceed any competing live speaker on the same cluster.
    private static let minimumDominanceRatio: Double = 1.25

    struct Result: Sendable {
        /// Observations to pass to `DictationStore.recordMeetingSpeakers` (carries clean
        /// biometric centroids and explicit live `assignedName`/`assignedProfileID`).
        let observations: [MeetingSpeakerObservation]
        /// Diarization segments for `TranscriptFormatter.merge`, with single-turn overrides
        /// carved out (or synthesized from live attributions if post-call diarization failed).
        let formattingDiarizationSegments: [TimedSpeakerSegment]?
        /// Maps post-call base `"Speaker N"` labels -> live-assigned names (empty if none).
        let liveClusterNames: [String: String]

        private let baseSpeakerLabelByRawID: [String: String]
        private let overrideNamesByRawID: [String: String]

        init(
            observations: [MeetingSpeakerObservation],
            formattingDiarizationSegments: [TimedSpeakerSegment]?,
            liveClusterNames: [String: String],
            baseSpeakerLabelByRawID: [String: String],
            overrideNamesByRawID: [String: String]
        ) {
            self.observations = observations
            self.formattingDiarizationSegments = formattingDiarizationSegments
            self.liveClusterNames = liveClusterNames
            self.baseSpeakerLabelByRawID = baseSpeakerLabelByRawID
            self.overrideNamesByRawID = overrideNamesByRawID
        }

        /// Builds the `speakerNames` dictionary expected by `TranscriptFormatter.merge` using
        /// `formattingDiarizationSegments`, combining store-resolved names (explicit + voiceprint +
        /// call roster) with any single-turn overrides.
        func formattingSpeakerNames(
            resolvedFromStore storeNames: [String: String],
            renderNames: Bool = true
        ) -> [String: String] {
            guard renderNames, let formattingDiarizationSegments, !formattingDiarizationSegments.isEmpty else {
                return [:]
            }
            let formattingLabels = TranscriptFormatter.speakerLabels(for: formattingDiarizationSegments)
            var result: [String: String] = [:]
            for (rawID, formattingLabel) in formattingLabels {
                if let overrideName = overrideNamesByRawID[rawID] {
                    result[formattingLabel] = overrideName
                } else if let baseLabel = baseSpeakerLabelByRawID[rawID] {
                    if let resolved = storeNames[baseLabel] ?? liveClusterNames[baseLabel] {
                        result[formattingLabel] = resolved
                    }
                }
            }
            return result
        }
    }

    static func reconcile(
        diarizationSegments: [TimedSpeakerSegment]?,
        liveInput: LiveSpeakerReconciliationInput?,
        speakerEmbeddings: [String: [Float]] = [:],
        minimumVoiceprintSeconds: Double = SpeakerCentroidBuilder.minimumVoiceprintSeconds
    ) -> Result {
        guard let liveInput else {
            let segments = diarizationSegments
            let observations = segments.map {
                SpeakerCentroidBuilder.observations(
                    from: $0,
                    speakerEmbeddings: speakerEmbeddings,
                    minimumSeconds: minimumVoiceprintSeconds
                )
            } ?? []
            let baseLabels = segments.map { TranscriptFormatter.speakerLabels(for: $0) } ?? [:]
            return Result(
                observations: observations,
                formattingDiarizationSegments: segments,
                liveClusterNames: [:],
                baseSpeakerLabelByRawID: baseLabels,
                overrideNamesByRawID: [:]
            )
        }

        if let diarizationSegments, !diarizationSegments.isEmpty {
            return reconcileWithPostCallDiarization(
                diarizationSegments: diarizationSegments,
                liveInput: liveInput,
                speakerEmbeddings: speakerEmbeddings,
                minimumVoiceprintSeconds: minimumVoiceprintSeconds
            )
        }

        return reconcileFallbackWithoutPostCallDiarization(liveInput: liveInput)
    }

    // MARK: - Post-call diarization present

    private static func reconcileWithPostCallDiarization(
        diarizationSegments: [TimedSpeakerSegment],
        liveInput: LiveSpeakerReconciliationInput,
        speakerEmbeddings: [String: [Float]],
        minimumVoiceprintSeconds: Double
    ) -> Result {
        let baseLabels = TranscriptFormatter.speakerLabels(for: diarizationSegments)
        let baseObservations = SpeakerCentroidBuilder.observations(
            from: diarizationSegments,
            speakerEmbeddings: speakerEmbeddings,
            minimumSeconds: minimumVoiceprintSeconds
        )

        // Aggregate live-assigned intervals per target speaker entry (handles merged live clusters).
        struct TargetGroup {
            let entryID: String
            let displayName: String
            let profileID: Int64?
            var intervals: [LiveSpeakerInterval]
        }
        var targetsByEntryID: [String: TargetGroup] = [:]
        for assignment in liveInput.clusterAssignments {
            guard !assignment.intervals.isEmpty else { continue }
            if var existing = targetsByEntryID[assignment.targetEntryID] {
                existing.intervals.append(contentsOf: assignment.intervals)
                targetsByEntryID[assignment.targetEntryID] = existing
            } else {
                targetsByEntryID[assignment.targetEntryID] = TargetGroup(
                    entryID: assignment.targetEntryID,
                    displayName: assignment.displayName,
                    profileID: assignment.profileID,
                    intervals: assignment.intervals
                )
            }
        }

        let segmentsBySpeakerID = Dictionary(grouping: diarizationSegments, by: \.speakerId)
        var liveAssignedByBaseLabel: [String: (name: String, profileID: Int64?)] = [:]
        var liveClusterNames: [String: String] = [:]

        for (rawSpeakerID, baseLabel) in baseLabels {
            let clusterSegments = segmentsBySpeakerID[rawSpeakerID] ?? []
            let clusterDuration = clusterSegments.reduce(0.0) { $0 + Double(max(0, $1.durationSeconds)) }
            guard clusterDuration > 0 else { continue }

            var scores: [(target: TargetGroup, overlap: TimeInterval)] = []
            for target in targetsByEntryID.values {
                let overlap = totalOverlap(segments: clusterSegments, intervals: target.intervals)
                if overlap > 0 {
                    scores.append((target, overlap))
                }
            }
            scores.sort {
                if $0.overlap == $1.overlap { return $0.target.entryID < $1.target.entryID }
                return $0.overlap > $1.overlap
            }

            guard let best = scores.first else { continue }
            let requiredOverlap = min(minimumOverlapSeconds, clusterDuration * 0.5)
            guard best.overlap >= requiredOverlap,
                  best.overlap / clusterDuration >= minimumClusterCoverageRatio else { continue }
            if scores.count > 1, scores[1].overlap > 0, best.overlap < scores[1].overlap * minimumDominanceRatio {
                continue
            }

            liveAssignedByBaseLabel[baseLabel] = (best.target.displayName, best.target.profileID)
            liveClusterNames[baseLabel] = best.target.displayName
        }

        let enrichedObservations = baseObservations.map { observation in
            if let assigned = liveAssignedByBaseLabel[observation.label] {
                return MeetingSpeakerObservation(
                    label: observation.label,
                    centroid: observation.centroid,
                    speechSeconds: observation.speechSeconds,
                    assignedName: assigned.name,
                    assignedProfileID: assigned.profileID
                )
            }
            return observation
        }

        let (formattingSegments, overrideNamesByRawID) = applyTurnOverrides(
            to: diarizationSegments,
            overrides: liveInput.turnOverrides
        )

        return Result(
            observations: enrichedObservations,
            formattingDiarizationSegments: formattingSegments,
            liveClusterNames: liveClusterNames,
            baseSpeakerLabelByRawID: baseLabels,
            overrideNamesByRawID: overrideNamesByRawID
        )
    }

    // MARK: - Fallback when post-call diarizer failed / unavailable

    private static func reconcileFallbackWithoutPostCallDiarization(
        liveInput: LiveSpeakerReconciliationInput
    ) -> Result {
        // Only synthesize diarization when live diarization or user edits actually produced
        // speaker distinctions beyond plain unattributed "Others".
        let remoteTurns = liveInput.turns.filter { liveInput.isInPerson || $0.source != "You" }
        guard !remoteTurns.isEmpty else {
            return Result(
                observations: [],
                formattingDiarizationSegments: nil,
                liveClusterNames: [:],
                baseSpeakerLabelByRawID: [:],
                overrideNamesByRawID: [:]
            )
        }

        let assignmentByCluster = Dictionary(
            uniqueKeysWithValues: liveInput.clusterAssignments.map { ($0.clusterID, $0) }
        )
        let overrideByTurnID = Dictionary(
            uniqueKeysWithValues: liveInput.turnOverrides.map { ($0.turnID, $0) }
        )

        struct ResolvedTurn {
            let speakerKey: String
            let displayName: String
            let profileID: Int64?
            let isExplicitName: Bool
            let start: TimeInterval
            let end: TimeInterval
        }

        var resolvedTurns: [ResolvedTurn] = []
        var hasDistinctAttribution = false

        for turn in remoteTurns {
            let end = max(turn.endSeconds, turn.startSeconds + 0.1)
            if let override = overrideByTurnID[turn.id] {
                hasDistinctAttribution = true
                resolvedTurns.append(
                    ResolvedTurn(
                        speakerKey: "entry:\(override.targetEntryID)",
                        displayName: override.displayName,
                        profileID: override.profileID,
                        isExplicitName: true,
                        start: turn.startSeconds,
                        end: end
                    )
                )
            } else {
                let cluster = turn.liveClusterID ?? "Others"
                if let assigned = assignmentByCluster[cluster] {
                    hasDistinctAttribution = true
                    resolvedTurns.append(
                        ResolvedTurn(
                            speakerKey: "entry:\(assigned.targetEntryID)",
                            displayName: assigned.displayName,
                            profileID: assigned.profileID,
                            isExplicitName: true,
                            start: turn.startSeconds,
                            end: end
                        )
                    )
                } else {
                    if cluster != LiveSpeakerLabeler.fallbackLabel {
                        hasDistinctAttribution = true
                    }
                    resolvedTurns.append(
                        ResolvedTurn(
                            speakerKey: "cluster:\(cluster)",
                            displayName: cluster,
                            profileID: nil,
                            isExplicitName: false,
                            start: turn.startSeconds,
                            end: end
                        )
                    )
                }
            }
        }

        guard hasDistinctAttribution else {
            return Result(
                observations: [],
                formattingDiarizationSegments: nil,
                liveClusterNames: [:],
                baseSpeakerLabelByRawID: [:],
                overrideNamesByRawID: [:]
            )
        }

        let syntheticSegments = resolvedTurns.map { turn in
            TimedSpeakerSegment(
                speakerId: turn.speakerKey,
                embedding: [],
                startTimeSeconds: Float(turn.start),
                endTimeSeconds: Float(turn.end),
                qualityScore: 1
            )
        }

        let baseLabels = TranscriptFormatter.speakerLabels(for: syntheticSegments)
        var metadataByKey: [String: (name: String, profileID: Int64?, isExplicit: Bool, seconds: Double)] = [:]
        for turn in resolvedTurns {
            let duration = max(0, turn.end - turn.start)
            if var existing = metadataByKey[turn.speakerKey] {
                existing.seconds += duration
                metadataByKey[turn.speakerKey] = existing
            } else {
                metadataByKey[turn.speakerKey] = (turn.displayName, turn.profileID, turn.isExplicitName, duration)
            }
        }

        var liveClusterNames: [String: String] = [:]
        var observations: [MeetingSpeakerObservation] = []

        for (rawID, baseLabel) in baseLabels.sorted(by: { speakerNumber($0.value) < speakerNumber($1.value) }) {
            guard let meta = metadataByKey[rawID] else { continue }
            if meta.isExplicit {
                liveClusterNames[baseLabel] = meta.name
            } else if rawID == "cluster:\(LiveSpeakerLabeler.fallbackLabel)" {
                // Keep "Others" turns in syntheticSegments so TranscriptFormatter's single-speaker
                // shortcut does not label all other turns as the overridden speaker, while
                // preserving "Others" as the displayed name and omitting a bogus Speaker N row.
                liveClusterNames[baseLabel] = LiveSpeakerLabeler.fallbackLabel
                continue
            }
            observations.append(
                MeetingSpeakerObservation(
                    label: baseLabel,
                    centroid: nil,
                    speechSeconds: meta.seconds,
                    assignedName: meta.isExplicit ? meta.name : nil,
                    assignedProfileID: meta.isExplicit ? meta.profileID : nil
                )
            )
        }

        return Result(
            observations: observations,
            formattingDiarizationSegments: syntheticSegments,
            liveClusterNames: liveClusterNames,
            baseSpeakerLabelByRawID: baseLabels,
            overrideNamesByRawID: [:]
        )
    }

    // MARK: - Turn overrides

    private static func applyTurnOverrides(
        to segments: [TimedSpeakerSegment],
        overrides: [LiveTurnOverrideRecord]
    ) -> ([TimedSpeakerSegment], [String: String]) {
        guard !overrides.isEmpty else { return (segments, [:]) }

        var working = segments
        var overrideNamesByRawID: [String: String] = [:]

        for override in overrides {
            let cutStart = Float(override.startSeconds)
            let cutEnd = Float(max(override.endSeconds, override.startSeconds + 0.1))
            guard cutEnd > cutStart else { continue }

            var nextSegments: [TimedSpeakerSegment] = []
            nextSegments.reserveCapacity(working.count + 2)

            for segment in working {
                if segment.endTimeSeconds <= cutStart || segment.startTimeSeconds >= cutEnd {
                    nextSegments.append(segment)
                    continue
                }
                if segment.startTimeSeconds < cutStart {
                    nextSegments.append(
                        TimedSpeakerSegment(
                            speakerId: segment.speakerId,
                            embedding: segment.embedding,
                            startTimeSeconds: segment.startTimeSeconds,
                            endTimeSeconds: cutStart,
                            qualityScore: segment.qualityScore
                        )
                    )
                }
                if segment.endTimeSeconds > cutEnd {
                    nextSegments.append(
                        TimedSpeakerSegment(
                            speakerId: segment.speakerId,
                            embedding: segment.embedding,
                            startTimeSeconds: cutEnd,
                            endTimeSeconds: segment.endTimeSeconds,
                            qualityScore: segment.qualityScore
                        )
                    )
                }
            }

            let overrideID = "override:\(override.turnID.uuidString)"
            nextSegments.append(
                TimedSpeakerSegment(
                    speakerId: overrideID,
                    embedding: [],
                    startTimeSeconds: cutStart,
                    endTimeSeconds: cutEnd,
                    qualityScore: 1
                )
            )
            overrideNamesByRawID[overrideID] = override.displayName
            working = nextSegments
        }

        working.sort { lhs, rhs in
            if lhs.startTimeSeconds == rhs.startTimeSeconds {
                return lhs.endTimeSeconds < rhs.endTimeSeconds
            }
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        return (working, overrideNamesByRawID)
    }

    private static func totalOverlap(
        segments: [TimedSpeakerSegment],
        intervals: [LiveSpeakerInterval]
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for segment in segments {
            let segStart = TimeInterval(segment.startTimeSeconds)
            let segEnd = TimeInterval(segment.endTimeSeconds)
            guard segEnd > segStart else { continue }
            for interval in intervals {
                let start = max(segStart, interval.start)
                let end = min(segEnd, interval.end)
                if end > start {
                    total += end - start
                }
            }
        }
        return total
    }

    private static func speakerNumber(_ label: String) -> Int {
        guard label.hasPrefix("Speaker ") else { return .max }
        return Int(label.dropFirst("Speaker ".count)) ?? .max
    }
}
