import Contacts
import MuesliCore
import SwiftUI

enum ParticipantSuggestionPrivacy {
    static let disclosure = "AI may send part of this meeting to your provider."
}

extension Notification.Name {
    static let meetingParticipantsDidChange = Notification.Name("MuesliMeetingParticipantsDidChange")
}

/// Pure quick-add / search ranking for `MeetingParticipantsView`, deduplicated
/// against people already attached to the meeting.
enum MeetingParticipantQuickAddFilter {
    struct Candidate: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let subtitle: String?
        let draft: MeetingParticipantDraft
        let isCreateAction: Bool
    }

    static func isAlreadyAttached(name: String, in existingParticipants: [MeetingParticipant]) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        return existingParticipants.contains { participant in
            let raw = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let compact = MeetingContactIdentity.compactDisplayName(
                participant.displayName,
                emailAddress: participant.emailAddress
            ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return raw == key || compact == key
        }
    }

    static func candidates(
        query: String,
        existingParticipants: [MeetingParticipant],
        profiles: [SpeakerProfileSummary],
        knownPeople: [MeetingParticipantDraft]
    ) -> [Candidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmed.lowercased()
        let existingNames = Set(existingParticipants.map {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let existingIdentifiers = Set(existingParticipants.map(\.participantIdentifier))

        var seenNames = Set<String>()
        var matches: [Candidate] = []

        for person in knownPeople {
            let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !key.isEmpty,
                  !existingNames.contains(key),
                  !existingIdentifiers.contains(person.participantIdentifier),
                  !seenNames.contains(key) else { continue }
            guard normalizedQuery.isEmpty
                    || key.contains(normalizedQuery)
                    || (person.emailAddress?.lowercased().contains(normalizedQuery) == true) else { continue }
            seenNames.insert(key)
            matches.append(Candidate(
                id: "known:\(person.participantIdentifier)",
                displayName: name,
                subtitle: person.emailAddress,
                draft: person,
                isCreateAction: false
            ))
        }

        for profile in profiles {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !key.isEmpty,
                  !existingNames.contains(key),
                  !seenNames.contains(key) else { continue }
            guard normalizedQuery.isEmpty || key.contains(normalizedQuery) else { continue }
            seenNames.insert(key)
            let meetingsText = profile.meetingCount == 1 ? "1 meeting" : "\(profile.meetingCount) meetings"
            matches.append(Candidate(
                id: "profile:\(profile.id)",
                displayName: name,
                subtitle: "Saved speaker · \(meetingsText)",
                draft: MeetingParticipantDraft(
                    participantIdentifier: "manual:speaker-\(profile.id)",
                    displayName: name
                ),
                isCreateAction: false
            ))
        }

        let sortedMatches: [Candidate]
        if normalizedQuery.isEmpty {
            sortedMatches = matches
        } else {
            let prefixes = matches.filter { $0.displayName.lowercased().hasPrefix(normalizedQuery) }
            let substrings = matches.filter { !$0.displayName.lowercased().hasPrefix(normalizedQuery) }
            sortedMatches = prefixes + substrings
        }

        var result: [Candidate] = []
        if !trimmed.isEmpty {
            let exactMatchExists = existingNames.contains(normalizedQuery)
                || sortedMatches.contains { $0.displayName.lowercased() == normalizedQuery }
            if !exactMatchExists {
                result.append(Candidate(
                    id: "create:\(normalizedQuery)",
                    displayName: trimmed,
                    subtitle: "Add to this meeting",
                    draft: MeetingParticipantDraft(
                        participantIdentifier: "manual:\(UUID().uuidString)",
                        displayName: trimmed
                    ),
                    isCreateAction: true
                ))
            }
        }
        result.append(contentsOf: sortedMatches)
        return result
    }
}

struct MeetingParticipantsView: View {
    let meetingID: Int64
    let controller: MuesliController
    let compactDiscardAction: (() -> Void)?

    @State private var participants: [MeetingParticipant] = []
    @State private var profiles: [SpeakerProfileSummary] = []
    @State private var knownPeople: [MeetingParticipantDraft] = []
    @State private var quickAddQuery = ""
    @State private var isContactPickerPresented = false
    @State private var isNewContactPresented = false
    @State private var isPeoplePopoverPresented = false
    @State private var isSpeakerProfilesSheetPresented = false
    @State private var suggestions: [MeetingParticipantSuggestion] = []
    @State private var suggestionFingerprint = ""
    @State private var suggestionTask: Task<Void, Never>?
    @State private var findingPeople = false
    @State private var suggestionMessage: String?
    @State private var evidenceSuggestionID: String?
    @State private var matchingPeople: [String: [MeetingParticipantDraft]] = [:]
    @State private var errorMessage: String?
    @FocusState private var isQuickAddFocused: Bool

    init(
        meetingID: Int64,
        controller: MuesliController,
        compactDiscardAction: (() -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.controller = controller
        self.compactDiscardAction = compactDiscardAction
    }

    private var peopleDescription: String {
        participants.count == 1 ? "1 person" : "\(participants.count) people"
    }

    private var firstParticipantName: String? {
        participants.first.map {
            MeetingContactIdentity.compactDisplayName(
                $0.displayName,
                emailAddress: $0.emailAddress
            )
        }
    }

    private var quickAddCandidates: [MeetingParticipantQuickAddFilter.Candidate] {
        MeetingParticipantQuickAddFilter.candidates(
            query: quickAddQuery,
            existingParticipants: participants,
            profiles: profiles,
            knownPeople: knownPeople
        )
    }

    var body: some View {
        participantControl
            .featureTourTarget(.meetingPeople)
            .popover(isPresented: $isPeoplePopoverPresented, arrowEdge: .bottom) {
                peoplePopover
            }
            .background {
                MeetingContactPicker(isPresented: $isContactPickerPresented) { contact in
                    Task { await attach(contact) }
                }
            }
            .task(id: meetingID) {
                await reload()
                await reloadSuggestions()
            }
            .onDisappear { suggestionTask?.cancel(); suggestionTask = nil }
            .onChange(of: isPeoplePopoverPresented) { _, presented in
                if presented {
                    quickAddQuery = ""
                    Task {
                        await reload()
                        await reloadPeopleDirectory(query: "")
                        await reloadSuggestions()
                        isQuickAddFocused = true
                    }
                }
            }
            .onChange(of: meetingID) { _, _ in
                suggestionTask?.cancel(); suggestionTask = nil
                suggestions = []; matchingPeople = [:]; suggestionMessage = nil; evidenceSuggestionID = nil; findingPeople = false
                quickAddQuery = ""
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetingParticipantsDidChange)) { notification in
                guard notification.object as? Int64 == meetingID else { return }
                Task { await reload() }
            }
            .sheet(isPresented: $isNewContactPresented) {
                NewMeetingContactView { participant in
                    Task { await attach(participant) }
                }
            }
            .sheet(isPresented: $isSpeakerProfilesSheetPresented) {
                SpeakerProfilesView(controller: controller)
            }
            .alert("Couldn't Update People", isPresented: errorBinding) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "The meeting's people could not be updated.")
            }
    }

    @ViewBuilder
    private var participantControl: some View {
        if let compactDiscardAction {
            Menu {
                Button {
                    presentPeoplePopoverAfterMenuDismisses()
                } label: {
                    Label("Add people…", systemImage: "person.2")
                }

                Divider()

                Button("Discard meeting", role: .destructive) {
                    compactDiscardAction()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More recording actions")
            .accessibilityLabel("More recording actions")
        } else {
            Button {
                isPeoplePopoverPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: participants.isEmpty ? "person.2" : "person.2.fill")

                    if let firstParticipantName {
                        Text(firstParticipantName)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if participants.count > 1 {
                            Text("+\(participants.count - 1)")
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                    } else {
                        Text("Add people")
                    }
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: MeetingHeaderLayout.contextControlHeight)
                .frame(maxWidth: 220)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .help(participants.isEmpty ? "Add people to this meeting" : "Show \(peopleDescription)")
            .accessibilityLabel(
                participants.isEmpty ? "Add people to this meeting" : "\(peopleDescription) in this meeting"
            )
            .accessibilityIdentifier("meeting.participants.button")
        }
    }

    private var peoplePopover: some View {
        let candidates = quickAddCandidates
        let isSearching = !quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing8) {
                Text("People")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)

                if !participants.isEmpty {
                    Text(peopleDescription)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Spacer()

                contactsMenu
            }

            inlineQuickAddField(candidates: candidates)

            Divider()
                .background(MuesliTheme.surfaceBorder)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        if isSearching {
                            quickAddCandidatesSection(candidates)
                        } else {
                            if !candidates.isEmpty && participants.isEmpty {
                                quickAddCandidatesSection(Array(candidates.prefix(5)))
                            }

                            if participants.isEmpty && suggestions.isEmpty && candidates.isEmpty {
                                Text("No one has been added yet. Type a name above to add someone.")
                                    .font(MuesliTheme.callout())
                                    .foregroundStyle(MuesliTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, MuesliTheme.spacing4)
                            } else if !participants.isEmpty {
                                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                                    ForEach(participants) { participant in
                                        participantListRow(participant)
                                    }
                                }
                            }

                            if let suggestionMessage {
                                Text(suggestionMessage)
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(MuesliTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id("suggestionMessage")
                            }

                            if !suggestions.isEmpty {
                                suggestionsSection
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 96, maxHeight: 240)
                .onChange(of: suggestions) { _, updated in
                    if !updated.isEmpty { proxy.scrollTo("suggestions", anchor: .top) }
                }
                .onChange(of: suggestionMessage) { _, updated in
                    if updated != nil { proxy.scrollTo("suggestionMessage", anchor: .bottom) }
                }
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Button {
                        findParticipants()
                    } label: {
                        HStack(spacing: 6) {
                            if findingPeople {
                                ProgressView().controlSize(.small)
                            }
                            Text(findingPeople ? "Finding people…" : "Find participants")
                                .font(MuesliTheme.callout())
                        }
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .frame(height: 28)
                    }
                    .buttonStyle(.muesli(.secondary))
                    .disabled(findingPeople)
                    .accessibilityIdentifier("meeting.participants.findButton")

                    Spacer(minLength: 0)

                    Button {
                        isPeoplePopoverPresented = false
                        isSpeakerProfilesSheetPresented = true
                    } label: {
                        Text("Saved speakers…")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.accentText)
                            .padding(.horizontal, 6)
                            .frame(height: 28)
                    }
                    .buttonStyle(.muesli(.quiet))
                    .accessibilityIdentifier("meeting.participants.savedSpeakersButton")
                }

                Text(ParticipantSuggestionPrivacy.disclosure)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MuesliTheme.spacing16)
        .frame(width: 340)
        .background(MuesliTheme.backgroundRaised)
        .task(id: quickAddQuery) {
            let trimmed = quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            await reloadPeopleDirectory(query: trimmed)
        }
    }

    private func inlineQuickAddField(candidates: [MeetingParticipantQuickAddFilter.Candidate]) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)

            TextField("Add or find person…", text: $quickAddQuery)
                .textFieldStyle(.plain)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .focused($isQuickAddFocused)
                .onSubmit {
                    submitQuickAdd(candidates: candidates)
                }
                .accessibilityIdentifier("meeting.participants.quickAddField")

            let trimmedQuery = quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let alreadyAttached = MeetingParticipantQuickAddFilter.isAlreadyAttached(
                name: trimmedQuery,
                in: participants
            )
            if !trimmedQuery.isEmpty && !alreadyAttached {
                Button {
                    submitQuickAdd(candidates: candidates)
                } label: {
                    Text("Add")
                        .font(MuesliTheme.metadata())
                        .padding(.horizontal, MuesliTheme.spacing8)
                        .frame(height: 24)
                }
                .buttonStyle(.muesli(.primary))
                .accessibilityIdentifier("meeting.participants.quickAddButton")
            }
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .frame(height: 32)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(
                    isQuickAddFocused ? MuesliTheme.accentText : MuesliTheme.surfaceBorder,
                    lineWidth: isQuickAddFocused ? 1.5 : 1
                )
        }
        .onAppear {
            DispatchQueue.main.async {
                isQuickAddFocused = true
            }
        }
    }

    @ViewBuilder
    private func quickAddCandidatesSection(_ candidates: [MeetingParticipantQuickAddFilter.Candidate]) -> some View {
        let alreadyAttached = MeetingParticipantQuickAddFilter.isAlreadyAttached(
            name: quickAddQuery,
            in: participants
        )
        if candidates.isEmpty {
            Text(alreadyAttached ? "Already in this meeting." : "No matching people.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.vertical, MuesliTheme.spacing4)
        } else {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                ForEach(candidates) { candidate in
                    Button {
                        attachQuickAddCandidate(candidate)
                    } label: {
                        HStack(spacing: MuesliTheme.spacing8) {
                            if candidate.isCreateAction {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(MuesliTheme.accentText)
                            } else {
                                Circle()
                                    .fill(SpeakerColorPalette.color(for: candidate.displayName))
                                    .frame(width: 8, height: 8)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.isCreateAction ? "Add “\(candidate.displayName)”" : candidate.displayName)
                                    .font(candidate.isCreateAction ? MuesliTheme.callout().weight(.semibold) : MuesliTheme.callout())
                                    .foregroundStyle(candidate.isCreateAction ? MuesliTheme.accentText : MuesliTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(MuesliTheme.metadata())
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, MuesliTheme.spacing8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.muesli(.quiet, compresses: false))
                }
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Suggested")
                .font(MuesliTheme.metadata())
                .foregroundStyle(MuesliTheme.textTertiary)
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                ForEach(suggestions) { suggestion in
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(MuesliTheme.textTertiary)
                        Text(suggestion.name)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { evidenceSuggestionID = suggestion.id } label: {
                            Image(systemName: "info.circle")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.muesli(.quiet))
                        .help("Show supporting excerpt")
                        .accessibilityLabel("Show evidence for \(suggestion.name)")
                        .popover(isPresented: Binding(
                            get: { evidenceSuggestionID == suggestion.id },
                            set: { if !$0 { evidenceSuggestionID = nil } }
                        )) {
                            ScrollView {
                                Text(suggestion.excerpt)
                                    .font(MuesliTheme.callout())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 260, height: 110)
                            .padding(MuesliTheme.spacing12)
                        }
                        Menu("Add") {
                            Button("Add as new person") { resolve(suggestion, add: true) }
                            ForEach(matchingPeople[suggestion.id] ?? [], id: \.participantIdentifier) { person in
                                Button("Use \(person.displayName)\(person.emailAddress.map { " · " + $0 } ?? "")") {
                                    resolve(suggestion, add: true, existingPerson: person)
                                }
                            }
                        }
                        .fixedSize()
                        Button { resolve(suggestion, add: false) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.muesli(.quiet))
                        .help("Dismiss suggestion")
                        .accessibilityLabel("Dismiss \(suggestion.name)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .id("suggestions")
        }
    }

    private var contactsMenu: some View {
        Menu {
            Button {
                chooseExistingContact()
            } label: {
                Label("Choose from Contacts…", systemImage: "person.crop.circle.badge.plus")
            }

            Button {
                createNewContact()
            } label: {
                Label("Create New Contact…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                Text("Contacts")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .frame(height: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose or create an Apple contact")
    }

    private func participantListRow(_ participant: MeetingParticipant) -> some View {
        let displayName = MeetingContactIdentity.compactDisplayName(
            participant.displayName,
            emailAddress: participant.emailAddress
        )
        return HStack(spacing: MuesliTheme.spacing8) {
            Circle()
                .fill(SpeakerColorPalette.color(for: displayName))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                if let email = participant.emailAddress, email != displayName {
                    Text(email)
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            Spacer()

            Button {
                remove(participant)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.muesli(.quiet))
            .help("Remove \(displayName)")
            .accessibilityLabel("Remove \(displayName)")
        }
        .padding(.vertical, 2)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented {
                    errorMessage = nil
                }
            }
        )
    }

    private func submitQuickAdd(candidates: [MeetingParticipantQuickAddFilter.Candidate]) {
        let trimmed = quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !MeetingParticipantQuickAddFilter.isAlreadyAttached(name: trimmed, in: participants) else { return }
        if let first = candidates.first {
            attachQuickAddCandidate(first)
            return
        }
        let draft = MeetingParticipantDraft(
            participantIdentifier: "manual:\(UUID().uuidString)",
            displayName: trimmed
        )
        quickAddQuery = ""
        isQuickAddFocused = true
        Task { await attach(draft) }
    }

    private func attachQuickAddCandidate(_ candidate: MeetingParticipantQuickAddFilter.Candidate) {
        quickAddQuery = ""
        isQuickAddFocused = true
        Task { await attach(candidate.draft) }
    }

    private func chooseExistingContact() {
        isPeoplePopoverPresented = false
        Task { @MainActor in
            await Task.yield()
            isContactPickerPresented = true
        }
    }

    private func presentPeoplePopoverAfterMenuDismisses() {
        Task { @MainActor in
            await Task.yield()
            isPeoplePopoverPresented = true
        }
    }

    private func createNewContact() {
        isPeoplePopoverPresented = false
        Task { @MainActor in
            await Task.yield()
            isNewContactPresented = true
        }
    }

    private func reload() async {
        do {
            participants = try await controller.meetingParticipants(meetingID: meetingID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadPeopleDirectory(query: String) async {
        async let loadedProfiles = (try? controller.speakerProfiles()) ?? []
        async let loadedPeople = (try? controller.globalSearchWorker.people(matching: query)) ?? []
        let (nextProfiles, nextPeople) = await (loadedProfiles, loadedPeople)
        if nextProfiles != profiles { profiles = nextProfiles }
        if nextPeople != knownPeople { knownPeople = nextPeople }
    }

    private func reloadSuggestions() async {
        do {
            let (fingerprint, found) = try await controller.participantSuggestions(meetingID: meetingID)
            guard !Task.isCancelled else { return }
            suggestionFingerprint = fingerprint; suggestions = found
            var matches: [String: [MeetingParticipantDraft]] = [:]
            for suggestion in found {
                try Task.checkCancellation()
                matches[suggestion.id] = try await controller.globalSearchWorker.people(matching: suggestion.name)
            }
            guard !Task.isCancelled else { return }
            matchingPeople = matches
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            suggestionMessage = error.localizedDescription
        }
    }

    private func findParticipants() {
        suggestionTask?.cancel()
        findingPeople = true; suggestionMessage = nil
        suggestionTask = Task {
            defer { findingPeople = false }
            do {
                let wasTruncated = try await controller.findParticipantSuggestions(meetingID: meetingID)
                try Task.checkCancellation()
                await reloadSuggestions()
                if wasTruncated {
                    suggestionMessage = suggestions.isEmpty ? "No suggestions found. Only part of this meeting was reviewed." : "Only part of this meeting was reviewed."
                } else if suggestions.isEmpty { suggestionMessage = "No new suggestions in the reviewed text." }
            } catch is CancellationError {} catch { suggestionMessage = error.localizedDescription }
        }
    }

    private func resolve(_ suggestion: MeetingParticipantSuggestion, add: Bool, existingPerson: MeetingParticipantDraft? = nil) {
        Task {
            do {
                try await controller.resolveParticipantSuggestion(meetingID: meetingID, fingerprint: suggestionFingerprint, name: suggestion.name, add: add, existingPerson: existingPerson)
                await reloadSuggestions()
                if add { await reload() }
            } catch {
                suggestionMessage = error.localizedDescription
                await reloadSuggestions()
            }
        }
    }

    private func attach(_ contact: CNContact) async {
        let resolvedContact = await MeetingContactResolver().resolve(contact)
        await attach(
            MeetingContactIdentity.participant(
                for: resolvedContact,
                preservingIdentifierFrom: contact
            )
        )
    }

    private func attach(_ participant: MeetingParticipantDraft) async {
        do {
            try await controller.attachMeetingParticipant(
                meetingID: meetingID,
                participant: participant
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ participant: MeetingParticipant) {
        Task {
            do {
                try await controller.removeMeetingParticipant(
                    meetingID: meetingID,
                    participantIdentifier: participant.participantIdentifier
                )
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
