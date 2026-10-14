import Foundation

/// What a learned memory row is keyed on.
public enum ClassificationMemoryKind: String, Sendable, CaseIterable {
    case series, email, title
}

/// Where a folder suggestion came from. Rule sources match memory kinds.
public enum FolderSuggestionSource: String, Sendable, CaseIterable {
    case series, email, title, llm

    public var memoryKind: ClassificationMemoryKind? { ClassificationMemoryKind(rawValue: rawValue) }
}

public struct ClassificationMemoryKey: Hashable, Sendable {
    public let kind: ClassificationMemoryKind
    public let key: String

    public init(kind: ClassificationMemoryKind, key: String) {
        self.kind = kind
        self.key = key
    }
}

/// One `classification_memory` row: how often meetings with this key were filed
/// into `folderID` by the user, and how often a suggestion built on it was rejected.
public struct ClassificationMemory: Equatable, Sendable {
    public let kind: ClassificationMemoryKind
    public let key: String
    public let folderID: Int64
    public let confirmations: Int
    public let contradictions: Int

    public init(kind: ClassificationMemoryKind, key: String, folderID: Int64, confirmations: Int, contradictions: Int) {
        self.kind = kind
        self.key = key
        self.folderID = folderID
        self.confirmations = confirmations
        self.contradictions = contradictions
    }
}

/// The meeting facts the rules look at. Emails and titles are raw; the rules normalize them.
public struct ClassificationEvidence: Equatable, Sendable {
    public let seriesID: String?
    public let emails: [String]
    public let title: String

    public init(seriesID: String?, emails: [String], title: String) {
        self.seriesID = seriesID
        self.emails = emails
        self.title = title
    }
}

public struct FolderSuggestionCandidate: Equatable, Sendable {
    public let folderID: Int64
    public let source: FolderSuggestionSource
    public let confidence: Double
    public let reason: String

    public init(folderID: Int64, source: FolderSuggestionSource, confidence: Double, reason: String) {
        self.folderID = folderID
        self.source = source
        self.confidence = confidence
        self.reason = reason
    }
}

/// Pure, ordered rules. The first decisive rule wins; otherwise the result is empty.
///
/// 1. Series: the calendar series was filed into exactly one folder (confirmations >= 1)
///    and that memory has never been contradicted.
/// 2. Email: every non-self attendee with memory points to the same single folder,
///    none of them has a contradiction, and the weakest of them has >= 2 confirmations.
///    Attendees without memory are ignored; zero known attendees abstains.
/// 3. Title: the normalized title was filed into exactly one folder with >= 2
///    confirmations and no contradictions.
public enum FolderClassificationRules {
    public static let seriesConfidence = 0.95
    public static let emailConfidence = 0.85
    public static let titleConfidence = 0.75
    static let minimumEmailConfirmations = 2
    static let minimumTitleConfirmations = 2

    public static func classify(
        _ evidence: ClassificationEvidence,
        memory: [ClassificationMemory],
        selfEmails: Set<String>,
        folderNames: [Int64: String]
    ) -> [FolderSuggestionCandidate] {
        let live = memory.filter { $0.confirmations > 0 || $0.contradictions > 0 }
        let rules: [() -> FolderSuggestionCandidate?] = [
            { seriesRule(evidence, live, folderNames) },
            { emailRule(evidence, live, selfEmails, folderNames) },
            { titleRule(evidence, live, folderNames) },
        ]
        for rule in rules {
            if let candidate = rule() { return [candidate] }
        }
        return []
    }

    /// The memory keys a meeting contributes, in rule order, without duplicates or self.
    public static func memoryKeys(for evidence: ClassificationEvidence, selfEmails: Set<String>) -> [ClassificationMemoryKey] {
        var keys: [ClassificationMemoryKey] = []
        if let series = normalizedSeries(evidence.seriesID) {
            keys.append(.init(kind: .series, key: series))
        }
        keys += otherEmails(evidence, selfEmails).map { .init(kind: .email, key: $0) }
        if let title = normalizeTitle(evidence.title) {
            keys.append(.init(kind: .title, key: title))
        }
        return keys
    }

    // MARK: - Rules

    private static func seriesRule(
        _ evidence: ClassificationEvidence,
        _ memory: [ClassificationMemory],
        _ folderNames: [Int64: String]
    ) -> FolderSuggestionCandidate? {
        guard let series = normalizedSeries(evidence.seriesID) else { return nil }
        let rows = memory.filter { $0.kind == .series && $0.key == series }
        guard rows.count == 1, let row = rows.first,
              row.confirmations >= 1, row.contradictions == 0,
              let name = folderNames[row.folderID] else { return nil }
        return FolderSuggestionCandidate(
            folderID: row.folderID,
            source: .series,
            confidence: seriesConfidence,
            reason: "Same recurring series as \(meetingCount(row.confirmations)) in \(name)"
        )
    }

    private static func emailRule(
        _ evidence: ClassificationEvidence,
        _ memory: [ClassificationMemory],
        _ selfEmails: Set<String>,
        _ folderNames: [Int64: String]
    ) -> FolderSuggestionCandidate? {
        var votedFolders = Set<Int64>()
        var weakest = Int.max
        var known = 0
        for email in otherEmails(evidence, selfEmails) {
            let rows = memory.filter { $0.kind == .email && $0.key == email }
            guard !rows.isEmpty else { continue }
            guard rows.count == 1, let row = rows.first, row.contradictions == 0 else { return nil }
            known += 1
            votedFolders.insert(row.folderID)
            weakest = min(weakest, row.confirmations)
        }
        guard known > 0, votedFolders.count == 1, let folderID = votedFolders.first,
              weakest >= minimumEmailConfirmations,
              let name = folderNames[folderID] else { return nil }
        let reason = known == 1
            ? "Attendee was in \(meetingCount(weakest)) in \(name)"
            : "All \(known) known attendees were in at least \(weakest) meetings in \(name)"
        return FolderSuggestionCandidate(folderID: folderID, source: .email, confidence: emailConfidence, reason: reason)
    }

    private static func titleRule(
        _ evidence: ClassificationEvidence,
        _ memory: [ClassificationMemory],
        _ folderNames: [Int64: String]
    ) -> FolderSuggestionCandidate? {
        guard let title = normalizeTitle(evidence.title) else { return nil }
        let rows = memory.filter { $0.kind == .title && $0.key == title }
        guard rows.count == 1, let row = rows.first,
              row.confirmations >= minimumTitleConfirmations, row.contradictions == 0,
              let name = folderNames[row.folderID] else { return nil }
        return FolderSuggestionCandidate(
            folderID: row.folderID,
            source: .title,
            confidence: titleConfidence,
            reason: "Same title as \(meetingCount(row.confirmations)) in \(name)"
        )
    }

    private static func meetingCount(_ count: Int) -> String {
        count == 1 ? "1 meeting" : "\(count) meetings"
    }

    // MARK: - Normalization

    private static func normalizedSeries(_ seriesID: String?) -> String? {
        let trimmed = seriesID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func otherEmails(_ evidence: ClassificationEvidence, _ selfEmails: Set<String>) -> [String] {
        let selfSet = Set(selfEmails.compactMap(normalizeEmail))
        var seen = Set<String>()
        return evidence.emails
            .compactMap(normalizeEmail)
            .filter { !selfSet.contains($0) && seen.insert($0).inserted }
    }

    /// Lowercased address without a `mailto:` prefix, or nil when it is not an address.
    public static func normalizeEmail(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("mailto:") { value.removeFirst("mailto:".count) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = value.firstIndex(of: "@"), at != value.startIndex,
              value.index(after: at) != value.endIndex else { return nil }
        return value
    }

    private static let titlePrefix = try! NSRegularExpression(
        pattern: #"^\s*(zoom meeting|zoom|google meet|meet|microsoft teams meeting|microsoft teams|teams meeting|teams|webex|facetime|updated invitation|invitation|fwd|fw|re)\s*[:\-–—]\s*"#
    )
    private static let titleNoise: [NSRegularExpression] = [
        #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?\b"#,
        #"\d+"#,
        #"[^\p{L}]+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Title with meeting-app prefixes, dates, times, digits and punctuation removed,
    /// so occurrences of one recurring meeting share a key. Nil when nothing is left.
    public static func normalizeTitle(_ raw: String) -> String? {
        var title = raw.lowercased()
        while let match = titlePrefix.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range, in: title) {
            title.removeSubrange(range)
        }
        for pattern in titleNoise {
            title = pattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: " ")
        }
        let words = title.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
