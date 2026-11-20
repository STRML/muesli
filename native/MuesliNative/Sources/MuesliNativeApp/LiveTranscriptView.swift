// Purpose: Scrolling live transcript view with auto-scroll and inline speaker controls during active meetings
// Created: 2026-05-22

import AppKit
import MuesliCore
import Observation
import SwiftUI

enum LiveTranscriptCopyContent {
    static func text(transcript: String, partialYou: String, partialOthers: String) -> String {
        var sections: [String] = []
        let committed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty {
            sections.append(committed)
        }
        let others = partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !others.isEmpty {
            sections.append("Others: \(others)")
        }
        let you = partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
        if !you.isEmpty {
            sections.append("You: \(you)")
        }
        return sections.joined(separator: "\n")
    }
}

/// Snapshot of speaker candidates passed down to live speaker pickers so
/// unchanged paragraphs skip re-renders on normal caption chunks.
struct LiveSpeakerDirectorySnapshot: Equatable, Sendable {
    let inMeetingNames: [String]
    let profiles: [SpeakerProfileSummary]
    let knownPeople: [MeetingParticipantDraft]
    let activeClusterLabels: [String]

    static func make(
        store: LiveMeetingSpeakerStore,
        profiles: [SpeakerProfileSummary],
        participants: [MeetingParticipant]
    ) -> LiveSpeakerDirectorySnapshot {
        var names: [String] = []
        var seen = Set<String>()
        for entry in store.entries where !entry.isSelf && !entry.isGenericCluster {
            let key = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, seen.insert(key).inserted {
                names.append(entry.displayName)
            }
        }
        for participant in participants {
            let name = MeetingContactIdentity.compactDisplayName(
                participant.displayName,
                emailAddress: participant.emailAddress
            )
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, seen.insert(key).inserted {
                names.append(name)
            }
        }
        let known = participants.map {
            MeetingParticipantDraft(
                participantIdentifier: $0.participantIdentifier,
                displayName: MeetingContactIdentity.compactDisplayName(
                    $0.displayName,
                    emailAddress: $0.emailAddress
                ),
                emailAddress: $0.emailAddress
            )
        }
        return LiveSpeakerDirectorySnapshot(
            inMeetingNames: names,
            profiles: profiles,
            knownPeople: known,
            activeClusterLabels: store.activeClusterLabels
        )
    }
}

/// Pure presentation model for the pinned `LiveSpeakerBar` chips and readiness status.
enum LiveSpeakerBarPresentation {
    struct Chip: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case selfSpeaker
            case activeSpeaker(clusterID: String?, entryID: String?, isGeneric: Bool)
            case unassignedParticipant(name: String, participantIdentifier: String?)
        }

        let id: String
        let title: String
        let kind: Kind
        let isInteractive: Bool
    }

    struct ReadinessBadge: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case none
            case enableLiveLabels
        }

        let label: String
        let help: String
        let action: Action
        let isWorking: Bool
        let isWarning: Bool
    }

    struct Output: Equatable, Sendable {
        let chips: [Chip]
        let unnamedClusters: [String]
        let readiness: ReadinessBadge?
    }

    static func build(
        store: LiveMeetingSpeakerStore,
        participants: [MeetingParticipant],
        diarizationStatus: LiveDiarizationStatus
    ) -> Output {
        var chips: [Chip] = []
        var representedNames = Set<String>()
        var unnamedClusters: [String] = []

        if !store.isInPerson, store.entries.contains(where: \.isSelf) {
            chips.append(Chip(
                id: LiveMeetingSpeakerStore.selfEntryID,
                title: "You",
                kind: .selfSpeaker,
                isInteractive: false
            ))
            representedNames.insert("you")
        }

        let spokenEntryIDs = Set(store.turns.compactMap(\.explicitSpeakerID))
        var hasUnassignedFallbackOthers = false
        for turn in store.turns {
            let isSelfTurn = !store.isInPerson && turn.source == "You"
            guard !isSelfTurn, turn.explicitSpeakerID == nil else { continue }
            if let cluster = turn.liveClusterID {
                if cluster == LiveSpeakerLabeler.fallbackLabel, store.clusterToEntryID[cluster] == nil {
                    hasUnassignedFallbackOthers = true
                }
            } else {
                hasUnassignedFallbackOthers = true
            }
        }

        for entry in store.entries where !entry.isSelf {
            let hasSpoken = !entry.clusterIDs.isEmpty || spokenEntryIDs.contains(entry.id)
            let key = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if hasSpoken {
                let cluster = entry.clusterIDs.sorted().first ?? (entry.isGenericCluster ? entry.displayName : nil)
                chips.append(Chip(
                    id: entry.id,
                    title: entry.displayName,
                    kind: .activeSpeaker(clusterID: cluster, entryID: entry.id, isGeneric: entry.isGenericCluster),
                    isInteractive: true
                ))
                if entry.isGenericCluster, let cluster {
                    unnamedClusters.append(cluster)
                }
            } else {
                chips.append(Chip(
                    id: entry.id,
                    title: entry.displayName,
                    kind: .unassignedParticipant(name: entry.displayName, participantIdentifier: entry.participantIdentifier),
                    isInteractive: true
                ))
            }
            if !key.isEmpty { representedNames.insert(key) }
        }

        if hasUnassignedFallbackOthers && !unnamedClusters.contains(LiveSpeakerLabeler.fallbackLabel) {
            chips.append(Chip(
                id: "fallback:Others",
                title: LiveSpeakerLabeler.fallbackLabel,
                kind: .activeSpeaker(clusterID: LiveSpeakerLabeler.fallbackLabel, entryID: nil, isGeneric: true),
                isInteractive: true
            ))
            unnamedClusters.append(LiveSpeakerLabeler.fallbackLabel)
        }

        for participant in participants {
            let name = MeetingContactIdentity.compactDisplayName(
                participant.displayName,
                emailAddress: participant.emailAddress
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !key.isEmpty,
                  !SpeakerNameValidator.isReservedLabel(name),
                  representedNames.insert(key).inserted else { continue }
            chips.append(Chip(
                id: "participant:\(participant.participantIdentifier)",
                title: name,
                kind: .unassignedParticipant(name: name, participantIdentifier: participant.participantIdentifier),
                isInteractive: true
            ))
        }

        return Output(
            chips: chips,
            unnamedClusters: unnamedClusters,
            readiness: readinessBadge(for: diarizationStatus)
        )
    }

    private static func readinessBadge(for status: LiveDiarizationStatus) -> ReadinessBadge? {
        switch status {
        case .off:
            return ReadinessBadge(
                label: "Speaker labels off · Enable",
                help: "Turn on live speaker detection (Speaker 1, Speaker 2…) for this call",
                action: .enableLiveLabels,
                isWorking: false,
                isWarning: false
            )
        case .modelNotDownloaded:
            return ReadinessBadge(
                label: "Enable speaker labels",
                help: "Download the on-device live speaker model and label speakers in this call",
                action: .enableLiveLabels,
                isWorking: false,
                isWarning: false
            )
        case .downloading(let progress):
            let suffix = progress.map { " \(Int(($0 * 100).rounded()))%" } ?? "…"
            return ReadinessBadge(
                label: "Downloading speaker model\(suffix)",
                help: "Downloading the on-device live speaker model",
                action: .none,
                isWorking: true,
                isWarning: false
            )
        case .loadingModel:
            return ReadinessBadge(
                label: "Loading speaker labels…",
                help: "Starting live speaker detection",
                action: .none,
                isWorking: true,
                isWarning: false
            )
        case .active:
            return nil
        case .failed(let reason):
            return ReadinessBadge(
                label: "Speaker labels unavailable",
                help: reason,
                action: .enableLiveLabels,
                isWorking: false,
                isWarning: true
            )
        }
    }
}

/// One speaker turn as flowing text under a quiet header line. The committed text and the
/// still-changing tail share one font and size, so firming a tail up only changes its color.
struct LiveTranscriptParagraphView: View, Equatable {
    let paragraph: LiveTranscriptParagraph
    var onOpen: (() -> Void)? = nil
    var canEditSpeaker: Bool = false
    var speakerDirectory: LiveSpeakerDirectorySnapshot? = nil
    var onSelectSpeaker: ((_ clusterID: String?, _ turnID: UUID?, _ selection: SpeakerPickerSelection) -> Void)? = nil
    var onSearchPeople: (@MainActor (String) async -> [MeetingParticipantDraft])? = nil

    @State private var isSpeakerPickerPresented = false
    @State private var isHoveringSpeaker = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.paragraph == rhs.paragraph
            && lhs.canEditSpeaker == rhs.canEditSpeaker
            && lhs.speakerDirectory == rhs.speakerDirectory
    }

    private var isInteractiveSpeakerHeader: Bool {
        canEditSpeaker && !paragraph.isUser && paragraph.speaker != nil && onSelectSpeaker != nil
    }

    var body: some View {
        if paragraph.isBoundary {
            HStack(spacing: MuesliTheme.spacing8) {
                Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
                Text("Resumed")
                    .font(MuesliTheme.metadata())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
            }
            .padding(.vertical, MuesliTheme.spacing8)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let speaker = paragraph.speaker {
                    speakerHeader(speaker: speaker)
                }
                Text(flowingText)
                    .font(MuesliTheme.font(size: 13))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
            }
            .padding(.leading, MuesliTheme.spacing8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(paragraph.isUser ? MuesliTheme.accentText.opacity(0.55) : SpeakerColorPalette.color(for: paragraph.speaker ?? "Others").opacity(0.55))
                    .frame(width: 2)
            }
        }
    }

    @ViewBuilder
    private func speakerHeader(speaker: String) -> some View {
        let headerColor = paragraph.isUser ? MuesliTheme.accentText : MuesliTheme.textSecondary
        if isInteractiveSpeakerHeader {
            Button {
                isSpeakerPickerPresented = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(SpeakerColorPalette.color(for: speaker))
                        .frame(width: 6, height: 6)
                    Text(speaker)
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(headerColor)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .opacity(isHoveringSpeaker || isSpeakerPickerPresented ? 1 : 0.45)
                    if let timestamp = paragraph.timestamp {
                        Text(timestamp)
                            .font(MuesliTheme.metadata())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.muesli(.quiet))
            .onHover { isHoveringSpeaker = $0 }
            .help("Assign or rename \(speaker)")
            .accessibilityLabel("Speaker \(speaker), click to assign or rename")
            .popover(isPresented: $isSpeakerPickerPresented, arrowEdge: .bottom) {
                let cluster = paragraph.liveClusterID ?? speaker
                let assignedName = SpeakerNameValidator.isReservedLabel(speaker) ? nil : speaker
                let title = assignedName != nil ? "Rename \(speaker)" : "Assign \(speaker)"
                SpeakerPickerPopover(
                    title: title,
                    currentClusterLabel: cluster,
                    currentAssignedName: assignedName,
                    sampleQuote: speakerQuote(from: paragraph.committed),
                    inMeetingNames: speakerDirectory?.inMeetingNames ?? [],
                    profiles: speakerDirectory?.profiles ?? [],
                    knownPeople: speakerDirectory?.knownPeople ?? [],
                    activeClusterLabels: speakerDirectory?.activeClusterLabels ?? [],
                    allowMergeClusters: true,
                    showsScopeSwitcher: paragraph.turnID != nil,
                    initialScope: .allClusterTurns,
                    searchPeople: onSearchPeople,
                    onSelect: { selection in
                        isSpeakerPickerPresented = false
                        onSelectSpeaker?(cluster, paragraph.turnID, selection)
                    },
                    onDismiss: {
                        isSpeakerPickerPresented = false
                    }
                )
            }
        } else {
            HStack(spacing: 5) {
                if !paragraph.isUser {
                    Circle()
                        .fill(SpeakerColorPalette.color(for: speaker))
                        .frame(width: 6, height: 6)
                }
                Text(speaker + (paragraph.timestamp.map { "  \($0)" } ?? ""))
                    .font(MuesliTheme.metadata())
                    .foregroundStyle(paragraph.isUser ? MuesliTheme.accentText : MuesliTheme.textTertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
        }
    }

    private func speakerQuote(from text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 72 { return collapsed }
        return "\(collapsed.prefix(71).trimmingCharacters(in: .whitespaces))…"
    }

    private var flowingText: AttributedString {
        var committed = AttributedString(paragraph.committed)
        committed.foregroundColor = MuesliTheme.textPrimary
        guard !paragraph.tail.isEmpty else { return committed }
        var tail = AttributedString((paragraph.committed.isEmpty ? "" : " ") + paragraph.tail)
        tail.foregroundColor = MuesliTheme.textTertiary
        return committed + tail
    }
}

@MainActor
@Observable
final class LiveTranscriptPresentationModel {
    var transcript = ""
    var partialYou = ""
    var partialOthers = ""
    var messages: [TranscriptChatMessage] = []
    private(set) var paragraphs: [LiveTranscriptParagraph] = []
    private var lastPriorTranscript = ""
    private var lastSpeakerStore: LiveMeetingSpeakerStore?

    func update(transcript: String, partialYou: String, partialOthers: String) {
        guard lastSpeakerStore != nil ||
                self.transcript != transcript ||
                self.partialYou != partialYou ||
                self.partialOthers != partialOthers else { return }

        lastSpeakerStore = nil
        lastPriorTranscript = ""

        if transcript != self.transcript {
            if transcript.hasPrefix(self.transcript) {
                let appended = String(transcript.dropFirst(self.transcript.count))
                messages.append(contentsOf: TranscriptChatMessage.messages(
                    from: appended,
                    startingAt: messages.count
                ))
            } else {
                messages = TranscriptChatMessage.messages(from: transcript)
            }
            self.transcript = transcript
        }
        self.partialYou = partialYou
        self.partialOthers = partialOthers
        paragraphs = LiveTranscriptParagraphs.build(
            messages: messages, partialYou: partialYou, partialOthers: partialOthers
        )
    }

    func update(
        priorTranscript: String,
        speakerStore: LiveMeetingSpeakerStore?,
        transcript: String,
        partialYou: String,
        partialOthers: String
    ) {
        guard let speakerStore else {
            update(transcript: transcript, partialYou: partialYou, partialOthers: partialOthers)
            return
        }

        let useStructured = !speakerStore.turns.isEmpty || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard useStructured else {
            update(transcript: transcript, partialYou: partialYou, partialOthers: partialOthers)
            return
        }

        guard self.lastSpeakerStore != speakerStore ||
                self.lastPriorTranscript != priorTranscript ||
                self.transcript != transcript ||
                self.partialYou != partialYou ||
                self.partialOthers != partialOthers else { return }

        self.lastSpeakerStore = speakerStore
        self.lastPriorTranscript = priorTranscript
        self.transcript = transcript
        self.partialYou = partialYou
        self.partialOthers = partialOthers
        self.messages = TranscriptChatMessage.messages(from: transcript)

        let trimmedPrior = priorTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveParagraphs = LiveTranscriptParagraphs.build(
            turns: speakerStore.turns,
            store: speakerStore,
            partialYou: partialYou,
            partialOthers: partialOthers
        )

        if trimmedPrior.isEmpty {
            paragraphs = liveParagraphs
        } else {
            let priorInput = trimmedPrior + "\n" + MeetingResumePolicy.resumeSeparator
            let priorMessages = TranscriptChatMessage.messages(from: priorInput, startingAt: -10_000_000)
            let priorParagraphs = LiveTranscriptParagraphs.build(
                messages: priorMessages,
                partialYou: "",
                partialOthers: ""
            )
            paragraphs = priorParagraphs + liveParagraphs
        }
    }

    func reset() {
        transcript = ""
        partialYou = ""
        partialOthers = ""
        lastPriorTranscript = ""
        lastSpeakerStore = nil
        messages = []
        paragraphs = []
    }
}

struct LiveTranscriptFeedView: View {
    let paragraphs: [LiveTranscriptParagraph]
    var horizontalPadding: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var onOpen: (() -> Void)? = nil
    /// The live tab reads newest first, so the open paragraph and its growing tail sit on top.
    var newestFirst = false
    var canEditSpeakers: Bool = false
    var speakerDirectory: LiveSpeakerDirectorySnapshot? = nil
    var onSelectSpeaker: ((_ clusterID: String?, _ turnID: UUID?, _ selection: SpeakerPickerSelection) -> Void)? = nil
    var onSearchPeople: (@MainActor (String) async -> [MeetingParticipantDraft])? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if paragraphs.isEmpty {
                Text("Waiting for speech…")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MuesliTheme.spacing8)
            } else {
                ForEach(newestFirst ? Array(paragraphs.reversed()) : paragraphs) { paragraph in
                    LiveTranscriptParagraphView(
                        paragraph: paragraph,
                        onOpen: onOpen,
                        canEditSpeaker: canEditSpeakers,
                        speakerDirectory: speakerDirectory,
                        onSelectSpeaker: onSelectSpeaker,
                        onSearchPeople: onSearchPeople
                    )
                    .equatable()
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
}

/// Pinned live speaker strip above the live transcript feed: 1-click cluster renaming,
/// pre-adding speakers, quick-assigning roster participants, and readiness status.
struct LiveSpeakerBar: View {
    let speakerStore: LiveMeetingSpeakerStore
    let diarizationStatus: LiveDiarizationStatus
    let directory: LiveSpeakerDirectorySnapshot
    let participants: [MeetingParticipant]
    let copyText: String
    let didCopy: Bool
    let onCopy: () -> Void
    var onEnableLiveLabels: (() -> Void)? = nil
    var onSelectSpeaker: ((_ clusterID: String?, _ turnID: UUID?, _ selection: SpeakerPickerSelection) -> Void)? = nil
    var onRenameSpeakerEntry: ((_ entryID: String, _ selection: SpeakerPickerSelection) -> Void)? = nil
    var onSearchPeople: (@MainActor (String) async -> [MeetingParticipantDraft])? = nil

    @State private var activeChipPopoverID: String?
    @State private var isAddPopoverPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: LiveSpeakerBarPresentation.Output {
        LiveSpeakerBarPresentation.build(
            store: speakerStore,
            participants: participants,
            diarizationStatus: diarizationStatus
        )
    }

    var body: some View {
        let model = presentation
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
                WrappingHStack(spacing: 6, lineSpacing: 6) {
                    ForEach(model.chips) { chip in
                        chipView(chip, unnamedClusters: model.unnamedClusters)
                    }

                    if onSelectSpeaker != nil {
                        addSpeakerChip
                    }

                    if let readiness = model.readiness {
                        readinessView(readiness)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                copyButton
            }
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundBase)
    }

    @ViewBuilder
    private func chipView(_ chip: LiveSpeakerBarPresentation.Chip, unnamedClusters: [String]) -> some View {
        switch chip.kind {
        case .selfSpeaker:
            HStack(spacing: 5) {
                Circle()
                    .fill(MuesliTheme.accentText)
                    .frame(width: 6, height: 6)
                Text(chip.title)
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.accentText)
                    .lineLimit(1)
            }
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(minHeight: 28)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.accentText.opacity(0.28), lineWidth: 1)
            }
            .fixedSize()
            .accessibilityLabel("You")

        case .activeSpeaker(let clusterID, let entryID, let isGeneric):
            Button {
                activeChipPopoverID = chip.id
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(SpeakerColorPalette.color(for: chip.title))
                        .frame(width: 6, height: 6)
                    Text(chip.title)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(isGeneric ? MuesliTheme.textSecondary : MuesliTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(minHeight: 28)
            }
            .buttonStyle(.muesli(.secondary))
            .fixedSize()
            .help(isGeneric ? "Name \(chip.title)" : "Rename or merge \(chip.title)")
            .popover(isPresented: chipPopoverBinding(for: chip.id), arrowEdge: .bottom) {
                let targetCluster = clusterID ?? chip.title
                let assignedName = isGeneric ? nil : chip.title
                SpeakerPickerPopover(
                    title: isGeneric ? "Name \(chip.title)" : "Rename \(chip.title)",
                    currentClusterLabel: targetCluster,
                    currentAssignedName: assignedName,
                    inMeetingNames: directory.inMeetingNames,
                    profiles: directory.profiles,
                    knownPeople: directory.knownPeople,
                    activeClusterLabels: directory.activeClusterLabels,
                    allowMergeClusters: true,
                    showsScopeSwitcher: false,
                    searchPeople: onSearchPeople,
                    onSelect: { selection in
                        activeChipPopoverID = nil
                        if !isGeneric, let entryID, let onRenameSpeakerEntry {
                            onRenameSpeakerEntry(entryID, selection)
                        } else {
                            onSelectSpeaker?(targetCluster, nil, selection)
                        }
                    },
                    onDismiss: {
                        activeChipPopoverID = nil
                    }
                )
            }

        case .unassignedParticipant(let name, let identifier):
            Button {
                activeChipPopoverID = chip.id
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(SpeakerColorPalette.color(for: name).opacity(0.75))
                        .frame(width: 6, height: 6)
                    Text(name)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(minHeight: 28)
            }
            .buttonStyle(.muesli(.raised))
            .fixedSize()
            .help("In this meeting — click to assign to an active speaker")
            .popover(isPresented: chipPopoverBinding(for: chip.id), arrowEdge: .bottom) {
                unassignedParticipantPopover(
                    name: name,
                    identifier: identifier,
                    unnamedClusters: unnamedClusters
                )
            }
        }
    }

    private func unassignedParticipantPopover(
        name: String,
        identifier: String?,
        unnamedClusters: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Assign \(name)")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)

            if unnamedClusters.isEmpty {
                Text("\(name) is in this call. Once they speak, click any speaker label in the transcript to assign them.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose which speaker in the transcript is \(name):")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    ForEach(unnamedClusters, id: \.self) { cluster in
                        Button {
                            activeChipPopoverID = nil
                            onSelectSpeaker?(
                                cluster,
                                nil,
                                SpeakerPickerSelection(
                                    name: name,
                                    profileID: nil,
                                    participantIdentifier: identifier,
                                    mergeClusterLabel: nil,
                                    scope: .allClusterTurns,
                                    isNewName: false
                                )
                            )
                        } label: {
                            HStack(spacing: MuesliTheme.spacing8) {
                                Circle()
                                    .fill(SpeakerColorPalette.color(for: cluster))
                                    .frame(width: 8, height: 8)
                                Text(cluster)
                                    .font(MuesliTheme.callout())
                                    .foregroundStyle(MuesliTheme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, MuesliTheme.spacing8)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.muesli(.quiet, compresses: false))
                    }
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .frame(width: 264)
        .background(MuesliTheme.backgroundRaised)
    }

    private var addSpeakerChip: some View {
        Button {
            isAddPopoverPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add")
                    .font(MuesliTheme.captionMedium())
            }
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(minHeight: 28)
        }
        .buttonStyle(.muesli(.tinted))
        .fixedSize()
        .help("Add a speaker to this call")
        .accessibilityIdentifier("live.speakerBar.addButton")
        .popover(isPresented: $isAddPopoverPresented, arrowEdge: .bottom) {
            SpeakerPickerPopover(
                title: "Add speaker",
                currentClusterLabel: nil,
                currentAssignedName: nil,
                inMeetingNames: directory.inMeetingNames,
                profiles: directory.profiles,
                knownPeople: directory.knownPeople,
                activeClusterLabels: directory.activeClusterLabels,
                allowMergeClusters: false,
                showsScopeSwitcher: false,
                searchPeople: onSearchPeople,
                onSelect: { selection in
                    isAddPopoverPresented = false
                    onSelectSpeaker?(nil, nil, selection)
                },
                onDismiss: {
                    isAddPopoverPresented = false
                }
            )
        }
    }

    @ViewBuilder
    private func readinessView(_ badge: LiveSpeakerBarPresentation.ReadinessBadge) -> some View {
        if badge.action == .enableLiveLabels, let onEnableLiveLabels {
            Button(action: onEnableLiveLabels) {
                HStack(spacing: 5) {
                    Image(systemName: badge.isWarning ? "exclamationmark.triangle" : "person.wave.2")
                        .font(.system(size: 10, weight: .semibold))
                    Text(badge.label)
                        .font(MuesliTheme.metadata())
                        .lineLimit(1)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(minHeight: 28)
            }
            .buttonStyle(.muesli(badge.isWarning ? .secondary : .tinted))
            .fixedSize()
            .help(badge.help)
            .accessibilityIdentifier("live.speakerBar.enableLabelsButton")
        } else {
            HStack(spacing: 5) {
                if badge.isWorking && !reduceMotion {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: badge.isWorking ? "person.wave.2" : "info.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                Text(badge.label)
                    .font(MuesliTheme.metadata())
                    .lineLimit(1)
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(minHeight: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
            .fixedSize()
            .help(badge.help)
        }
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            HStack(spacing: 6) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(didCopy ? "Copied" : "Copy")
                    .font(MuesliTheme.captionMedium())
            }
            .foregroundStyle(didCopy ? MuesliTheme.successText : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 28)
        }
        .buttonStyle(.muesli(.secondary))
        .fixedSize()
        .disabled(copyText.isEmpty)
        .accessibilityIdentifier("live.transcript.copyButton")
    }

    private func chipPopoverBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { activeChipPopoverID == id },
            set: { if !$0 && activeChipPopoverID == id { activeChipPopoverID = nil } }
        )
    }
}

struct LiveTranscriptView: View {
    let transcript: String
    /// Provisional streaming tails render above committed captions and remain
    /// outside the durable transcript until their chunk is committed.
    var partialYou: String = ""
    var partialOthers: String = ""
    var priorTranscript: String = ""
    var speakerStore: LiveMeetingSpeakerStore? = nil
    var diarizationStatus: LiveDiarizationStatus = .off
    var speakerProfiles: [SpeakerProfileSummary] = []
    var meetingParticipants: [MeetingParticipant] = []
    var onEnableLiveLabels: (() -> Void)? = nil
    var onSelectSpeaker: ((_ clusterID: String?, _ turnID: UUID?, _ selection: SpeakerPickerSelection) -> Void)? = nil
    var onRenameSpeakerEntry: ((_ entryID: String, _ selection: SpeakerPickerSelection) -> Void)? = nil
    var onSearchPeople: (@MainActor (String) async -> [MeetingParticipantDraft])? = nil
    @State var presentation = LiveTranscriptPresentationModel()
    @State private var didCopy = false
    @State private var follow = LiveTranscriptFollowState()
    private let topID = "liveTranscriptTop"

    private var input: LiveTranscriptInput {
        .init(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers,
            priorTranscript: priorTranscript,
            speakerStore: speakerStore
        )
    }

    private func refreshPresentation() {
        presentation.update(
            priorTranscript: priorTranscript,
            speakerStore: speakerStore,
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    private var speakerDirectory: LiveSpeakerDirectorySnapshot? {
        guard let speakerStore else { return nil }
        return LiveSpeakerDirectorySnapshot.make(
            store: speakerStore,
            profiles: speakerProfiles,
            participants: meetingParticipants
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let speakerStore {
                LiveSpeakerBar(
                    speakerStore: speakerStore,
                    diarizationStatus: diarizationStatus,
                    directory: speakerDirectory ?? LiveSpeakerDirectorySnapshot.make(
                        store: speakerStore,
                        profiles: speakerProfiles,
                        participants: meetingParticipants
                    ),
                    participants: meetingParticipants,
                    copyText: copyText,
                    didCopy: didCopy,
                    onCopy: copyTranscript,
                    onEnableLiveLabels: onEnableLiveLabels,
                    onSelectSpeaker: onSelectSpeaker,
                    onRenameSpeakerEntry: onRenameSpeakerEntry,
                    onSearchPeople: onSearchPeople
                )
                Divider()
                    .background(MuesliTheme.surfaceBorder)
            }

            ZStack(alignment: .topTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 1).id(topID)
                            LiveTranscriptFeedView(
                                paragraphs: presentation.paragraphs,
                                horizontalPadding: MuesliTheme.spacing16,
                                topPadding: speakerStore == nil ? 44 : MuesliTheme.spacing12,
                                bottomPadding: MuesliTheme.spacing8,
                                newestFirst: true,
                                canEditSpeakers: speakerStore != nil && onSelectSpeaker != nil,
                                speakerDirectory: speakerDirectory,
                                onSelectSpeaker: onSelectSpeaker,
                                onSearchPeople: onSearchPeople
                            )
                        }
                        .background {
                            LiveTranscriptScrollObserver { top in
                                var next = follow
                                let shouldRefresh = next.updateTop(top)
                                if next != follow { follow = next }
                                if shouldRefresh { refreshPresentation() }
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .onChange(of: input) { _, _ in
                        if follow.receiveUpdate() { refreshPresentation() }
                    }
                    .onAppear {
                        follow.showLatest()
                        refreshPresentation()
                        proxy.scrollTo(topID, anchor: .top)
                    }
                    .overlay(alignment: .top) {
                        if follow.hasPendingUpdates {
                            Button {
                                follow.showLatest()
                                refreshPresentation()
                                proxy.scrollTo(topID, anchor: .top)
                            } label: {
                                Label("New messages", systemImage: "arrow.up")
                                    .font(MuesliTheme.callout())
                                    .padding(.horizontal, MuesliTheme.spacing12)
                                    .frame(height: 28)
                            }
                            .buttonStyle(.muesli(.tinted))
                            .padding(.top, MuesliTheme.spacing8)
                        }
                    }
                }

                if speakerStore == nil {
                    Button(action: copyTranscript) {
                        HStack(spacing: 6) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                            Text(didCopy ? "Copied" : "Copy")
                                .font(MuesliTheme.captionMedium())
                        }
                        .foregroundStyle(didCopy ? MuesliTheme.successText : MuesliTheme.textPrimary)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .frame(height: 30)
                    }
                    .buttonStyle(.muesli(.secondary))
                    .disabled(copyText.isEmpty)
                    .padding(.top, MuesliTheme.spacing8)
                    .padding(.trailing, MuesliTheme.spacing16)
                }
            }
        }
    }

    private func copyTranscript() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}

private struct LiveTranscriptInput: Equatable {
    let transcript: String
    let partialYou: String
    let partialOthers: String
    let priorTranscript: String
    let speakerStore: LiveMeetingSpeakerStore?
}

/// Observe the actual clip view: SwiftUI geometry preferences on macOS do not
/// reliably update when the native scroll view moves its content.
private struct LiveTranscriptScrollObserver: NSViewRepresentable {
    var onTopChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onTopChanged = onTopChanged
        view.attach()
    }

    final class ObserverView: NSView {
        var onTopChanged: ((CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private var observation: NSObjectProtocol?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }

        func attach() {
            let next = window == nil ? nil : enclosingScrollView?.contentView
            guard next !== clip else { return }
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            clip = next
            guard let next else { return }
            next.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: next, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            // Deliver outside SwiftUI layout/update callbacks.
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.clip else { return }
                self.onTopChanged?(-clip.bounds.minY)
            }
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }
    }
}

/// Hold the visible snapshot while reading history. Prepending captions or
/// growing partials cannot shift that snapshot; pending updates appear on return.
struct LiveTranscriptFollowState: Equatable {
    private(set) var isFollowing = true
    private(set) var hasPendingUpdates = false

    mutating func updateTop(_ minY: CGFloat) -> Bool {
        isFollowing = minY >= -24
        guard isFollowing, hasPendingUpdates else { return false }
        hasPendingUpdates = false
        return true
    }

    mutating func receiveUpdate() -> Bool {
        if !isFollowing { hasPendingUpdates = true }
        return isFollowing
    }

    mutating func showLatest() {
        isFollowing = true
        hasPendingUpdates = false
    }
}
