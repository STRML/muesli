import MuesliCore
import SwiftUI

/// "Speakers" control in the meeting header: name a diarized speaker once ("This is
/// Alex") so later meetings recognize the voice. Hidden when the meeting has no
/// diarized speakers.
struct MeetingSpeakersView: View {
    let meetingID: Int64
    let controller: MuesliController

    @State private var speakers: [MeetingSpeaker] = []
    @State private var profiles: [SpeakerProfileSummary] = []
    /// The meeting's participants: the invitees and the people read from the call.
    @State private var participantNames: [String] = []
    @State private var knownPeople: [MeetingParticipantDraft] = []
    @State private var sampleQuotes: [String: String] = [:]
    @State private var editingSpeaker: MeetingSpeaker?
    @State private var isPopoverPresented = false
    @State private var isPeopleSheetPresented = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !speakers.isEmpty {
                Button {
                    editingSpeaker = nil
                    isPopoverPresented = true
                } label: {
                    Label(summary, systemImage: "person.wave.2")
                        .font(MuesliTheme.caption())
                        .lineLimit(1)
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: MeetingHeaderLayout.contextControlHeight)
                        .background(MuesliTheme.backgroundRaised)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Name the speakers in this meeting")
                .accessibilityIdentifier("meeting.speakers.button")
                .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) { popover }
                .sheet(isPresented: $isPeopleSheetPresented) {
                    SpeakerProfilesView(controller: controller)
                }
            }
        }
        .task(id: meetingID) { await reload() }
        .onChange(of: isPopoverPresented) { _, presented in
            if presented {
                Task { await reload() }
            } else {
                editingSpeaker = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingSpeakersDidChange)) { notification in
            if let id = notification.object as? Int64, id != meetingID { return }
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingParticipantsDidChange)) { notification in
            if let id = notification.object as? Int64, id != meetingID { return }
            Task { await reload() }
        }
        .alert("Couldn't Name Speaker", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var summary: String {
        let named = speakers.filter { $0.profileID != nil }.count
        return named == 0 ? "\(speakers.count) speakers" : "\(named)/\(speakers.count) named"
    }

    @ViewBuilder
    private var popover: some View {
        if let speaker = editingSpeaker {
            let currentName = speaker.profileName
            let title = (currentName != nil && currentName != speaker.label)
                ? "Rename \(currentName!)"
                : "Name \(speaker.label)"
            SpeakerPickerPopover(
                title: title,
                currentClusterLabel: speaker.label,
                currentAssignedName: currentName,
                sampleQuote: sampleQuotes[speaker.label],
                inMeetingNames: participantNames,
                profiles: profiles,
                knownPeople: knownPeople,
                activeClusterLabels: speakers.map(\.label),
                allowMergeClusters: true,
                showsScopeSwitcher: false,
                showsBackButton: true,
                searchPeople: { query in
                    (try? await controller.globalSearchWorker.people(matching: query)) ?? []
                },
                onSelect: { selection in
                    editingSpeaker = nil
                    Task { await assign(speaker, selection: selection) }
                },
                onDismiss: {
                    editingSpeaker = nil
                }
            )
            .accessibilityIdentifier("meeting.speakers.pickerPopover")
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Speakers")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Name a voice once and muesli recognizes it in later meetings. Voiceprints stay on this Mac.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    ForEach(speakers) { speaker in
                        MeetingSpeakerRow(
                            speaker: speaker,
                            sampleQuote: sampleQuotes[speaker.label],
                            onEdit: { editingSpeaker = speaker },
                            onForget: { await forget(speaker) },
                            onDelete: { await deletePerson(speaker) }
                        )
                    }
                }

                Divider()
                    .background(MuesliTheme.surfaceBorder)

                Button {
                    isPopoverPresented = false
                    isPeopleSheetPresented = true
                } label: {
                    Text("Manage People…")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.accentText)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.muesli(.quiet))
                .accessibilityIdentifier("meeting.speakers.managePeople")
            }
            .padding(MuesliTheme.spacing16)
            .frame(width: 340)
            .background(MuesliTheme.backgroundRaised)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func reload() async {
        do {
            let loadedSpeakers = try await controller.meetingSpeakers(meetingID: meetingID)
            let loadedProfiles = try await controller.speakerProfiles()
            let loadedParticipants = ((try? await controller.meetingParticipants(meetingID: meetingID)) ?? []).map(\.displayName)
            let loadedPeople = (try? await controller.globalSearchWorker.people(matching: "")) ?? []
            let transcript = controller.meeting(id: meetingID)?.rawTranscript ?? ""
            let quotes = SpeakerSampleQuoteExtractor.sampleQuotes(
                for: loadedSpeakers.map(\.label),
                in: transcript
            )
            if loadedSpeakers != speakers { speakers = loadedSpeakers }
            if loadedProfiles != profiles { profiles = loadedProfiles }
            if loadedParticipants != participantNames { participantNames = loadedParticipants }
            if loadedPeople != knownPeople { knownPeople = loadedPeople }
            if quotes != sampleQuotes { sampleQuotes = quotes }
        } catch {
            fputs("[speakers] failed to load meeting speakers\n", stderr)
        }
    }

    private func assign(_ speaker: MeetingSpeaker, selection: SpeakerPickerSelection) async {
        do {
            try await controller.assignPostCallSpeaker(
                meetingID: meetingID,
                label: speaker.label,
                selection: selection
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func forget(_ speaker: MeetingSpeaker) async {
        guard let profileID = speaker.profileID else { return }
        do {
            try await controller.forgetSpeakerVoiceprints(profileID: profileID, sourceMeetingID: meetingID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func deletePerson(_ speaker: MeetingSpeaker) async {
        guard let profileID = speaker.profileID else { return }
        do {
            try await controller.deleteSpeakerProfile(id: profileID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }
}

private struct MeetingSpeakerRow: View {
    let speaker: MeetingSpeaker
    let sampleQuote: String?
    let onEdit: () -> Void
    let onForget: () async -> Void
    let onDelete: () async -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Button(action: onEdit) {
                HStack(alignment: .center, spacing: MuesliTheme.spacing8) {
                    Circle()
                        .fill(SpeakerColorPalette.color(for: speaker.profileName ?? speaker.label))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(MuesliTheme.callout().weight(.medium))
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if !speaker.hasVoiceprintSource {
                                Text("· too little audio")
                                    .font(MuesliTheme.metadata())
                                    .foregroundStyle(MuesliTheme.textTertiary)
                                    .lineLimit(1)
                            }
                        }

                        if let sampleQuote, !sampleQuote.isEmpty {
                            Text("“\(sampleQuote)”")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(speaker.profileID == nil ? "Name…" : "Change")
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(MuesliTheme.accentText)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.muesli(.secondary, compresses: false))
            .accessibilityIdentifier("meeting.speakers.rowButton")

            if speaker.profileID != nil {
                assignedMenu
            }
        }
        .confirmationDialog(
            "Delete \(speaker.profileName ?? "this person")?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete Person", role: .destructive) { Task { await onDelete() } }
        } message: {
            Text("Removes the person and every voiceprint. Names already written into transcripts stay.")
        }
    }

    private var title: String {
        guard let name = speaker.profileName, name != speaker.label else { return speaker.label }
        return "\(speaker.label) — \(name)"
    }

    private var assignedMenu: some View {
        Menu {
            if speaker.hasVoiceprintFromMeeting {
                Button("Forget This Voiceprint") { Task { await onForget() } }
            }
            Button("Delete Person…", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Speaker options")
        .accessibilityLabel("Options for \(speaker.profileName ?? speaker.label)")
    }
}

/// "People" sheet: every saved speaker profile with counts, forget and delete actions.
struct SpeakerProfilesView: View {
    let controller: MuesliController

    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [SpeakerProfileSummary] = []
    @State private var pendingDelete: SpeakerProfileSummary?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("People")
                .font(MuesliTheme.title2())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Voices muesli recognizes in meetings. Voiceprints are stored only on this Mac and are never synced.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if profiles.isEmpty {
                Text("No people yet. Name a speaker from a meeting's Speakers button.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(profiles) { profile in
                    HStack(spacing: MuesliTheme.spacing8) {
                        Circle()
                            .fill(SpeakerColorPalette.color(for: profile.name))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(MuesliTheme.callout().weight(.medium))
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Text(counts(profile))
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }
                        Spacer()
                        Button {
                            Task { await forget(profile) }
                        } label: {
                            Text("Forget Voiceprints")
                                .font(MuesliTheme.caption())
                                .padding(.horizontal, MuesliTheme.spacing8)
                                .frame(height: 28)
                        }
                        .buttonStyle(.muesli(.secondary))
                        .disabled(profile.voiceprintCount == 0)

                        Button(role: .destructive) {
                            pendingDelete = profile
                        } label: {
                            Text("Delete")
                                .font(MuesliTheme.caption())
                                .padding(.horizontal, MuesliTheme.spacing8)
                                .frame(height: 28)
                        }
                        .buttonStyle(.muesli(.destructive))
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.destructiveText)
            }
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(MuesliTheme.callout().weight(.semibold))
                        .padding(.horizontal, MuesliTheme.spacing16)
                        .frame(height: 30)
                }
                .buttonStyle(.muesli(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MuesliTheme.spacing20)
        .frame(width: 500)
        .background(MuesliTheme.backgroundBase)
        .task { await reload() }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "person")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Person", role: .destructive) {
                if let profile = pendingDelete { Task { await delete(profile) } }
            }
        } message: {
            Text("Removes the person and every voiceprint. Names already written into transcripts stay.")
        }
    }

    private func counts(_ profile: SpeakerProfileSummary) -> String {
        let prints = profile.voiceprintCount == 1 ? "1 voiceprint" : "\(profile.voiceprintCount) voiceprints"
        let meetings = profile.meetingCount == 1 ? "1 meeting" : "\(profile.meetingCount) meetings"
        return "\(prints) · \(meetings)"
    }

    private func reload() async {
        do {
            let loaded = try await controller.speakerProfiles()
            if loaded != profiles { profiles = loaded }
        } catch {
            errorMessage = "People could not be loaded."
        }
    }

    private func forget(_ profile: SpeakerProfileSummary) async {
        do { try await controller.forgetSpeakerVoiceprints(profileID: profile.id, sourceMeetingID: nil) } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func delete(_ profile: SpeakerProfileSummary) async {
        pendingDelete = nil
        do { try await controller.deleteSpeakerProfile(id: profile.id) } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }
}
