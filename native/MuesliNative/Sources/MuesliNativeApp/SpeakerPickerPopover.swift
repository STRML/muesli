import MuesliCore
import SwiftUI

/// Scope for applying a speaker selection from the picker.
enum SpeakerPickerScope: String, Equatable, Hashable, Sendable, CaseIterable {
    case allClusterTurns
    case singleTurn
}

/// Grouping section inside `SpeakerPickerPopover`.
enum SpeakerPickerSection: Int, Comparable, CaseIterable, Sendable {
    case create = 0
    case inMeeting = 1
    case savedProfiles = 2
    case knownPeople = 3
    case mergeClusters = 4

    static func < (lhs: SpeakerPickerSection, rhs: SpeakerPickerSection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String? {
        switch self {
        case .create: return nil
        case .inMeeting: return "In this meeting"
        case .savedProfiles: return "People you've named"
        case .knownPeople: return "Known people"
        case .mergeClusters: return "Merge with active speaker"
        }
    }
}

/// A single selectable row in `SpeakerPickerPopover`.
struct SpeakerPickerCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let subtitle: String?
    let section: SpeakerPickerSection
    let profileID: Int64?
    let participantIdentifier: String?
    let mergeClusterLabel: String?
    let isCreateAction: Bool

    init(
        id: String,
        displayName: String,
        subtitle: String? = nil,
        section: SpeakerPickerSection,
        profileID: Int64? = nil,
        participantIdentifier: String? = nil,
        mergeClusterLabel: String? = nil,
        isCreateAction: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.section = section
        self.profileID = profileID
        self.participantIdentifier = participantIdentifier
        self.mergeClusterLabel = mergeClusterLabel
        self.isCreateAction = isCreateAction
    }
}

/// Outcome returned when the user chooses or creates a speaker in `SpeakerPickerPopover`.
struct SpeakerPickerSelection: Equatable, Sendable {
    let name: String
    let profileID: Int64?
    let participantIdentifier: String?
    let mergeClusterLabel: String?
    let scope: SpeakerPickerScope
    let isNewName: Bool
}

/// Validates speaker display names against transcript-line format constraints
/// (mirroring `DictationStore.validatedSpeakerName`).
enum SpeakerNameValidator {
    enum ValidationResult: Equatable, Sendable {
        case empty
        case valid(String)
        case invalid(reason: String)
    }

    static let maxLength = 64

    static func validate(_ raw: String) -> ValidationResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.contains(":") || trimmed.contains(where: \.isNewline) {
            return .invalid(reason: "Speaker names cannot contain a colon or line break.")
        }
        if isReservedLabel(trimmed) {
            return .invalid(reason: "That name is reserved for transcript labels. Choose another name.")
        }
        if trimmed.count > maxLength {
            return .invalid(reason: "Keep speaker names under \(maxLength) characters.")
        }
        return .valid(trimmed)
    }

    static func isReservedLabel(_ name: String) -> Bool {
        if SpeakerVoiceprintMatcher.reservedLabels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return true
        }
        if name.range(of: #"^speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if name.range(of: #"^local\s+speaker(\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }
}

/// Deterministic, restrained indicator colors for speaker chips and dots across
/// Light, Dark, and Ultra Dark appearances.
enum SpeakerColorPalette {
    private static let swatches: [Color] = [
        Color.adaptive(dark: 0x60A5FA, light: 0x2563EB), // Blue
        Color.adaptive(dark: 0x34D399, light: 0x059669), // Emerald
        Color.adaptive(dark: 0xFBBF24, light: 0xB45309), // Amber
        Color.adaptive(dark: 0xF472B6, light: 0xBE185D), // Pink
        Color.adaptive(dark: 0xA78BFA, light: 0x6D28D9), // Violet
        Color.adaptive(dark: 0x2DD4BF, light: 0x0F766E), // Teal
        Color.adaptive(dark: 0xFB923C, light: 0xC2410C), // Orange
        Color.adaptive(dark: 0x38BDF8, light: 0x0369A1), // Sky
    ]

    static func color(for speaker: String) -> Color {
        let normalized = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "you" {
            return MuesliTheme.accentText
        }
        if normalized.isEmpty
            || normalized == "others"
            || normalized == "unknown speaker"
            || normalized == "multiple speakers" {
            return MuesliTheme.textTertiary
        }
        let hash = fnv1a64(normalized)
        return swatches[Int(hash % UInt64(swatches.count))]
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

/// Extracts concise 1-line sample quotes per speaker from a meeting transcript so
/// users can immediately recognize who `"Speaker 1"` or `"Speaker 2"` is.
enum SpeakerSampleQuoteExtractor {
    static func sampleQuote(for speakerLabel: String, in transcript: String, maxLength: Int = 72) -> String? {
        sampleQuotes(for: [speakerLabel], in: transcript, maxLength: maxLength)[speakerLabel]
    }

    static func sampleQuotes(for labels: [String], in transcript: String, maxLength: Int = 72) -> [String: String] {
        let targets = labels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !targets.isEmpty, !transcript.isEmpty else { return [:] }

        let targetByKey = Dictionary(
            targets.map { ($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let messages = TranscriptChatMessage.messages(from: transcript)
        var bestByKey: [String: String] = [:]

        for message in messages {
            guard let speaker = message.speaker else { continue }
            let key = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard targetByKey[key] != nil else { continue }
            let cleaned = collapsedWhitespace(message.text)
            guard !cleaned.isEmpty else { continue }

            if let existing = bestByKey[key] {
                if existing.count < 16 && cleaned.count >= 16 {
                    bestByKey[key] = cleaned
                }
            } else {
                bestByKey[key] = cleaned
            }
        }

        var result: [String: String] = [:]
        for (key, originalLabel) in targetByKey {
            if let quote = bestByKey[key] {
                result[originalLabel] = truncated(quote, maxLength: maxLength)
            }
        }
        return result
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1, text.count > maxLength else { return text }
        let limit = maxLength - 1
        let prefix = text.prefix(limit)
        let cutIndex = text.index(text.startIndex, offsetBy: limit)
        if cutIndex < text.endIndex, !text[cutIndex].isWhitespace,
           let lastSpace = prefix.lastIndex(where: \.isWhitespace),
           prefix.distance(from: prefix.startIndex, to: lastSpace) >= limit / 2 {
            return "\(prefix[..<lastSpace].trimmingCharacters(in: .whitespaces))…"
        }
        return "\(prefix.trimmingCharacters(in: .whitespaces))…"
    }
}

/// Pure ranking, filtering, and case-insensitive deduplication for `SpeakerPickerPopover`.
enum SpeakerPickerFilter {
    struct Output: Equatable, Sendable {
        let candidates: [SpeakerPickerCandidate]
        let validationError: String?
        let defaultHighlightedID: String?

        var sections: [(section: SpeakerPickerSection, items: [SpeakerPickerCandidate])] {
            var grouped: [SpeakerPickerSection: [SpeakerPickerCandidate]] = [:]
            for item in candidates {
                grouped[item.section, default: []].append(item)
            }
            return SpeakerPickerSection.allCases.compactMap { section in
                guard let items = grouped[section], !items.isEmpty else { return nil }
                return (section, items)
            }
        }
    }

    static func filter(
        query: String,
        currentClusterLabel: String? = nil,
        currentAssignedName: String? = nil,
        inMeetingNames: [String] = [],
        profiles: [SpeakerProfileSummary] = [],
        knownPeople: [MeetingParticipantDraft] = [],
        activeClusterLabels: [String] = [],
        allowMergeClusters: Bool = true
    ) -> Output {
        let validation = SpeakerNameValidator.validate(query)
        let normalizedQuery: String
        let validationError: String?
        switch validation {
        case .empty:
            normalizedQuery = ""
            validationError = nil
        case .valid(let valid):
            normalizedQuery = valid.lowercased()
            validationError = nil
        case .invalid(let reason):
            normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            validationError = reason
        }

        let currentClusterKey = currentClusterLabel.map(normalizedKey)
        let currentAssignedKey = currentAssignedName.map(normalizedKey)

        // Index profile and known-person metadata so in-meeting entries inherit
        // voiceprint / participant metadata instead of losing it during deduplication.
        var profileByKey: [String: SpeakerProfileSummary] = [:]
        for profile in profiles {
            let key = normalizedKey(profile.name)
            guard !key.isEmpty, profileByKey[key] == nil else { continue }
            profileByKey[key] = profile
        }

        var knownByKey: [String: MeetingParticipantDraft] = [:]
        for person in knownPeople {
            let key = normalizedKey(person.displayName)
            guard !key.isEmpty, knownByKey[key] == nil else { continue }
            knownByKey[key] = person
        }

        var seenKeys = Set<String>()
        var inMeetingCandidates: [SpeakerPickerCandidate] = []
        for rawName in inMeetingNames {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(trimmed)
            guard !key.isEmpty,
                  !SpeakerNameValidator.isReservedLabel(trimmed),
                  key != currentAssignedKey,
                  !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            let matchedProfile = profileByKey[key]
            let matchedKnown = knownByKey[key]
            inMeetingCandidates.append(SpeakerPickerCandidate(
                id: "meeting:\(key)",
                displayName: trimmed,
                subtitle: matchedKnown?.emailAddress ?? matchedProfile.map(profileSubtitle),
                section: .inMeeting,
                profileID: matchedProfile?.id,
                participantIdentifier: matchedKnown?.participantIdentifier
            ))
        }

        var profileCandidates: [SpeakerPickerCandidate] = []
        for profile in profiles {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(trimmed)
            guard !key.isEmpty,
                  !SpeakerNameValidator.isReservedLabel(trimmed),
                  key != currentAssignedKey,
                  !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            let matchedKnown = knownByKey[key]
            profileCandidates.append(SpeakerPickerCandidate(
                id: "profile:\(profile.id)",
                displayName: trimmed,
                subtitle: profileSubtitle(profile),
                section: .savedProfiles,
                profileID: profile.id,
                participantIdentifier: matchedKnown?.participantIdentifier
            ))
        }

        var knownCandidates: [SpeakerPickerCandidate] = []
        for person in knownPeople {
            let trimmed = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(trimmed)
            guard !key.isEmpty,
                  !SpeakerNameValidator.isReservedLabel(trimmed),
                  key != currentAssignedKey,
                  !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            knownCandidates.append(SpeakerPickerCandidate(
                id: "known:\(person.participantIdentifier)",
                displayName: trimmed,
                subtitle: person.emailAddress,
                section: .knownPeople,
                profileID: nil,
                participantIdentifier: person.participantIdentifier
            ))
        }

        var mergeCandidates: [SpeakerPickerCandidate] = []
        if allowMergeClusters, currentClusterLabel != nil {
            var seenClusterKeys = Set<String>()
            for label in activeClusterLabels {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalizedKey(trimmed)
                guard !key.isEmpty,
                      key != currentClusterKey,
                      key != currentAssignedKey,
                      !SpeakerVoiceprintMatcher.reservedLabels.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }),
                      !seenKeys.contains(key),
                      !seenClusterKeys.contains(key) else { continue }
                seenClusterKeys.insert(key)
                mergeCandidates.append(SpeakerPickerCandidate(
                    id: "cluster:\(key)",
                    displayName: trimmed,
                    subtitle: "Merge all turns into \(trimmed)",
                    section: .mergeClusters,
                    mergeClusterLabel: trimmed
                ))
            }
        }

        let filteredInMeeting = rankedMatches(inMeetingCandidates, query: normalizedQuery)
        let filteredProfiles = rankedMatches(profileCandidates, query: normalizedQuery)
        let filteredKnown = rankedMatches(knownCandidates, query: normalizedQuery)
        let filteredMerge = rankedMatches(mergeCandidates, query: normalizedQuery)

        let existingMatches = filteredInMeeting + filteredProfiles + filteredKnown + filteredMerge
        let hasExactMatch = !normalizedQuery.isEmpty && existingMatches.contains {
            normalizedKey($0.displayName) == normalizedQuery
        }

        var finalCandidates: [SpeakerPickerCandidate] = []
        if case .valid(let validName) = validation, !hasExactMatch {
            finalCandidates.append(SpeakerPickerCandidate(
                id: "create:\(validName.lowercased())",
                displayName: validName,
                subtitle: currentClusterLabel.map { "Add and assign to \($0)" } ?? "Add to this meeting",
                section: .create,
                isCreateAction: true
            ))
        }
        finalCandidates.append(contentsOf: existingMatches)

        let defaultHighlightedID: String?
        if hasExactMatch {
            defaultHighlightedID = existingMatches.first(where: { normalizedKey($0.displayName) == normalizedQuery })?.id
        } else if let createCandidate = finalCandidates.first(where: \.isCreateAction) {
            defaultHighlightedID = createCandidate.id
        } else {
            defaultHighlightedID = finalCandidates.first?.id
        }

        return Output(
            candidates: finalCandidates,
            validationError: validationError,
            defaultHighlightedID: defaultHighlightedID
        )
    }

    private static func rankedMatches(_ items: [SpeakerPickerCandidate], query: String) -> [SpeakerPickerCandidate] {
        guard !query.isEmpty else { return items }
        var prefixes: [SpeakerPickerCandidate] = []
        var substrings: [SpeakerPickerCandidate] = []
        for item in items {
            let candidateKey = normalizedKey(item.displayName)
            let subtitleKey = item.subtitle.map(normalizedKey) ?? ""
            if candidateKey.hasPrefix(query) {
                prefixes.append(item)
            } else if candidateKey.contains(query) || subtitleKey.contains(query) {
                substrings.append(item)
            }
        }
        return prefixes + substrings
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func profileSubtitle(_ profile: SpeakerProfileSummary) -> String {
        let prints = profile.voiceprintCount == 1 ? "1 voiceprint" : "\(profile.voiceprintCount) voiceprints"
        let meetings = profile.meetingCount == 1 ? "1 meeting" : "\(profile.meetingCount) meetings"
        return "\(prints) · \(meetings)"
    }
}

/// Unified, keyboard-driven 1-click speaker picker popover shared across the
/// live speaker bar, live transcript turns, and post-call speaker controls.
struct SpeakerPickerPopover: View {
    let title: String
    var currentClusterLabel: String? = nil
    var currentAssignedName: String? = nil
    var sampleQuote: String? = nil
    var inMeetingNames: [String] = []
    var profiles: [SpeakerProfileSummary] = []
    var knownPeople: [MeetingParticipantDraft] = []
    var activeClusterLabels: [String] = []
    var allowMergeClusters: Bool = true
    var showsScopeSwitcher: Bool = false
    var initialScope: SpeakerPickerScope = .allClusterTurns
    var showsBackButton: Bool = false
    var searchPeople: (@MainActor (String) async -> [MeetingParticipantDraft])? = nil
    let onSelect: (SpeakerPickerSelection) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var scope: SpeakerPickerScope
    @State private var searchedPeople: [MeetingParticipantDraft] = []
    @State private var highlightedID: String?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        currentClusterLabel: String? = nil,
        currentAssignedName: String? = nil,
        sampleQuote: String? = nil,
        inMeetingNames: [String] = [],
        profiles: [SpeakerProfileSummary] = [],
        knownPeople: [MeetingParticipantDraft] = [],
        activeClusterLabels: [String] = [],
        allowMergeClusters: Bool = true,
        showsScopeSwitcher: Bool = false,
        initialScope: SpeakerPickerScope = .allClusterTurns,
        showsBackButton: Bool = false,
        searchPeople: (@MainActor (String) async -> [MeetingParticipantDraft])? = nil,
        onSelect: @escaping (SpeakerPickerSelection) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.currentClusterLabel = currentClusterLabel
        self.currentAssignedName = currentAssignedName
        self.sampleQuote = sampleQuote
        self.inMeetingNames = inMeetingNames
        self.profiles = profiles
        self.knownPeople = knownPeople
        self.activeClusterLabels = activeClusterLabels
        self.allowMergeClusters = allowMergeClusters
        self.showsScopeSwitcher = showsScopeSwitcher
        self.initialScope = initialScope
        self.showsBackButton = showsBackButton
        self.searchPeople = searchPeople
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        _scope = State(initialValue: initialScope)
    }

    private var mergedKnownPeople: [MeetingParticipantDraft] {
        searchedPeople.isEmpty ? knownPeople : searchedPeople
    }

    private var filterOutput: SpeakerPickerFilter.Output {
        SpeakerPickerFilter.filter(
            query: query,
            currentClusterLabel: currentClusterLabel,
            currentAssignedName: currentAssignedName,
            inMeetingNames: inMeetingNames,
            profiles: profiles,
            knownPeople: mergedKnownPeople,
            activeClusterLabels: activeClusterLabels,
            allowMergeClusters: allowMergeClusters
        )
    }

    var body: some View {
        let output = filterOutput
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            header

            if let sampleQuote, !sampleQuote.isEmpty {
                Text("“\(sampleQuote)”")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            searchField(output: output)

            if let error = output.validationError {
                Text(error)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsScopeSwitcher {
                scopeSwitcher
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            candidateList(output: output)
        }
        .padding(MuesliTheme.spacing12)
        .frame(width: 312)
        .background(MuesliTheme.backgroundRaised)
        .onAppear {
            highlightedID = output.defaultHighlightedID
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: output.candidates) { _, _ in
            let validIDs = Set(output.candidates.map(\.id))
            if let highlightedID, validIDs.contains(highlightedID), query.isEmpty {
                return
            }
            highlightedID = output.defaultHighlightedID
        }
        .task(id: query) {
            guard let searchPeople else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            let results = await searchPeople(trimmed)
            guard !Task.isCancelled else { return }
            searchedPeople = results
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if showsBackButton {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.muesli(.quiet))
                .accessibilityLabel("Back")
                .help("Back")
            }

            if let label = currentAssignedName ?? currentClusterLabel {
                Circle()
                    .fill(SpeakerColorPalette.color(for: label))
                    .frame(width: 8, height: 8)
            }

            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if !showsBackButton {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.muesli(.quiet))
                .accessibilityLabel("Close speaker picker")
                .help("Close (Esc)")
            }
        }
    }

    private func searchField(output: SpeakerPickerFilter.Output) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)

            TextField("Name or pick speaker…", text: $query)
                .textFieldStyle(.plain)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .focused($isSearchFocused)
                .onSubmit {
                    submitHighlighted(in: output)
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(offset: -1, in: output)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(offset: 1, in: output)
                    return .handled
                }
                .accessibilityIdentifier("speaker.picker.searchField")

            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .frame(height: 32)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(
                    isSearchFocused ? MuesliTheme.accentText : MuesliTheme.surfaceBorder,
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
        }
    }

    private var scopeSwitcher: some View {
        let clusterTitle = currentClusterLabel.map { "All \($0) turns" } ?? "All turns"
        return HStack(spacing: MuesliTheme.spacing8) {
            scopeButton(title: clusterTitle, target: .allClusterTurns)
            scopeButton(title: "Only this turn", target: .singleTurn)
        }
    }

    private func scopeButton(title: String, target: SpeakerPickerScope) -> some View {
        let isSelected = scope == target
        return Button {
            scope = target
        } label: {
            Text(title)
                .font(MuesliTheme.metadata())
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, MuesliTheme.spacing8)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.muesli(isSelected ? .tinted : .secondary))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func candidateList(output: SpeakerPickerFilter.Output) -> some View {
        let sections = output.sections
        return Group {
            if sections.isEmpty {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Type a name to add your first speaker."
                         : "No matching speakers.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, MuesliTheme.spacing8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            ForEach(sections, id: \.section) { group in
                                if let title = group.section.title {
                                    Text(title)
                                        .font(MuesliTheme.metadata())
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                        .padding(.horizontal, MuesliTheme.spacing8)
                                        .padding(.top, MuesliTheme.spacing4)
                                }
                                ForEach(group.items) { candidate in
                                    candidateRow(candidate, isHighlighted: candidate.id == highlightedID)
                                        .id(candidate.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 230)
                    .onChange(of: highlightedID) { _, id in
                        guard let id else { return }
                        if reduceMotion {
                            proxy.scrollTo(id, anchor: .center)
                        } else {
                            withAnimation(MuesliMotion.feedback) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: SpeakerPickerCandidate, isHighlighted: Bool) -> some View {
        Button {
            select(candidate)
        } label: {
            HStack(spacing: MuesliTheme.spacing8) {
                if candidate.isCreateAction {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accentText)
                } else if candidate.mergeClusterLabel != nil {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SpeakerColorPalette.color(for: candidate.displayName))
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

                if isHighlighted {
                    Text("↵")
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(isHighlighted ? MuesliTheme.surfaceSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.muesli(.quiet, compresses: false))
        .onHover { hovering in
            if hovering {
                highlightedID = candidate.id
            }
        }
        .accessibilityIdentifier(candidate.isCreateAction ? "speaker.picker.createAction" : "speaker.picker.candidate")
    }

    private func moveHighlight(offset: Int, in output: SpeakerPickerFilter.Output) {
        let items = output.candidates
        guard !items.isEmpty else { return }
        guard let currentID = highlightedID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            highlightedID = offset >= 0 ? items.first?.id : items.last?.id
            return
        }
        let nextIndex = (currentIndex + offset + items.count) % items.count
        highlightedID = items[nextIndex].id
    }

    private func submitHighlighted(in output: SpeakerPickerFilter.Output) {
        if let id = highlightedID,
           let candidate = output.candidates.first(where: { $0.id == id }) {
            select(candidate)
        } else if let first = output.candidates.first {
            select(first)
        }
    }

    private func select(_ candidate: SpeakerPickerCandidate) {
        onSelect(SpeakerPickerSelection(
            name: candidate.displayName,
            profileID: candidate.profileID,
            participantIdentifier: candidate.participantIdentifier,
            mergeClusterLabel: candidate.mergeClusterLabel,
            scope: showsScopeSwitcher ? scope : .allClusterTurns,
            isNewName: candidate.isCreateAction
        ))
    }
}
