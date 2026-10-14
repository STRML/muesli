import Foundation
import MuesliCore

enum FolderClassificationOutcome: Equatable, Sendable {
    /// Filed, deleted, still recording or processing: left alone.
    case ineligible
    case suggested(FolderSuggestionSource)
    case autoApplied(FolderSuggestionSource)
    case noSuggestion
}

/// Classifies one meeting: rules first, then the LLM fallback. Does blocking SQLite
/// work, so callers run it off the main actor. Logs ids and outcomes only.
struct FolderClassifier: Sendable {
    let databaseURL: URL
    let generator: MeetingTextGenerating

    init(databaseURL: URL, generator: MeetingTextGenerating = MeetingTextGenerationClient()) {
        self.databaseURL = databaseURL
        self.generator = generator
    }

    private var store: FolderClassificationStore { FolderClassificationStore(databaseURL: databaseURL) }
    private var dictationStore: DictationStore { DictationStore(databaseURL: databaseURL) }

    func classify(meetingID: Int64, config: AppConfig) async -> FolderClassificationOutcome {
        do {
            let outcome = try await classifyThrowing(meetingID: meetingID, config: config)
            fputs("[folder-classify] meeting=\(meetingID) outcome=\(outcome)\n", stderr)
            return outcome
        } catch {
            fputs("[folder-classify] meeting=\(meetingID) failed error=\(type(of: error))\n", stderr)
            return .noSuggestion
        }
    }

    private func classifyThrowing(meetingID: Int64, config: AppConfig) async throws -> FolderClassificationOutcome {
        guard let snapshot = try store.snapshot(meetingID: meetingID), snapshot.isEligible else { return .ineligible }
        let folders = try dictationStore.listFolders()
        guard !folders.isEmpty else { return .noSuggestion }

        if let candidate = try ruleCandidate(snapshot: snapshot, folders: folders) {
            if config.autoApplyFolderSuggestions {
                return try store.autoApply(meetingID: meetingID, candidate: candidate) ? .autoApplied(candidate.source) : .noSuggestion
            }
            return try store.recordSuggestion(meetingID: meetingID, candidate: candidate) ? .suggested(candidate.source) : .noSuggestion
        }

        // One LLM question per meeting: any earlier suggestion, in any state, settles it.
        guard try !store.hasAnySuggestion(meetingID: meetingID) else { return .noSuggestion }
        try Task.checkCancellation()
        // Fail closed: an unreadable private flag counts as private.
        let isPrivate = (try? dictationStore.isMeetingPrivate(id: meetingID)) ?? true
        guard let candidate = await FolderClassificationLLM.suggest(
            snapshot: snapshot, folders: folders, config: config, isPrivateMeeting: isPrivate, generator: generator
        ) else { return .noSuggestion }
        // The user may have filed the meeting while the backend was thinking.
        guard try store.snapshot(meetingID: meetingID)?.isEligible == true else { return .ineligible }
        return try store.recordSuggestion(meetingID: meetingID, candidate: candidate) ? .suggested(.llm) : .noSuggestion
    }

    private func ruleCandidate(snapshot: MeetingClassificationSnapshot, folders: [MeetingFolder]) throws -> FolderSuggestionCandidate? {
        let selfEmails = try store.selfEmails()
        let keys = FolderClassificationRules.memoryKeys(for: snapshot.evidence, selfEmails: selfEmails)
        let memory = try store.memory(for: keys)
        let names = Dictionary(FolderClassificationLLM.choices(from: folders).map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        return FolderClassificationRules.classify(snapshot.evidence, memory: memory, selfEmails: selfEmails, folderNames: names).first
    }
}

/// Runs classification off the main actor and never while a meeting is recording.
@MainActor
final class FolderClassificationRunner {
    let classifier: FolderClassifier
    private let batchSize: Int
    private var batchTask: Task<Int, Never>?

    init(classifier: FolderClassifier, batchSize: Int = 25) {
        self.classifier = classifier
        self.batchSize = batchSize
    }

    var isRunningBatch: Bool { batchTask != nil }

    /// The post-meeting trigger. Nil when the setting is off or a meeting is recording.
    @discardableResult
    func classifyCompleted(
        meetingID: Int64,
        config: AppConfig,
        isRecording: @MainActor () -> Bool
    ) async -> FolderClassificationOutcome? {
        guard config.autoClassifyMeetings, !isRecording() else { return nil }
        let classifier = classifier
        return await Task.detached(priority: .utility) {
            await classifier.classify(meetingID: meetingID, config: config)
        }.value
    }

    private var queuedMeetingIDs: [Int64] = []
    private var drainTask: Task<Void, Never>?
    /// Called on the main actor after each queued meeting is classified.
    var onChange: (@MainActor () -> Void)?

    /// Queues a just-finished meeting. A meeting that finishes while another recording
    /// is running or starting waits in the queue until `drainQueue` runs without one.
    @discardableResult
    func enqueueCompleted(
        meetingID: Int64,
        config: AppConfig,
        isRecording: @escaping @MainActor @Sendable () -> Bool
    ) -> Task<Void, Never>? {
        guard config.autoClassifyMeetings else { return nil }
        if !queuedMeetingIDs.contains(meetingID) { queuedMeetingIDs.append(meetingID) }
        return drainQueue(config: config, isRecording: isRecording)
    }

    @discardableResult
    func drainQueue(config: AppConfig, isRecording: @escaping @MainActor @Sendable () -> Bool) -> Task<Void, Never>? {
        if let drainTask { return drainTask }
        guard !queuedMeetingIDs.isEmpty, !isRecording() else { return nil }
        let task = Task { [weak self] in
            while let self, !self.queuedMeetingIDs.isEmpty, !isRecording() {
                let id = self.queuedMeetingIDs.removeFirst()
                await self.classifyCompleted(meetingID: id, config: config, isRecording: isRecording)
                self.onChange?()
            }
            self?.drainTask = nil
        }
        drainTask = task
        return task
    }

    /// Classifies every unfiled meeting in pages, newest first. Stops when cancelled or
    /// when a recording starts. Returns how many meetings were processed.
    @discardableResult
    func classifyUnfiled(config: AppConfig, isRecording: @escaping @MainActor @Sendable () -> Bool) async -> Int {
        batchTask?.cancel()
        let classifier = classifier
        let batchSize = batchSize
        let task = Task.detached(priority: .utility) { () -> Int in
            let store = FolderClassificationStore(databaseURL: classifier.databaseURL)
            var cursor: Int64?
            var processed = 0
            while !Task.isCancelled, await !isRecording() {
                guard let page = try? store.unfiledMeetingIDs(before: cursor, limit: batchSize), !page.isEmpty else { break }
                for id in page {
                    guard !Task.isCancelled, await !isRecording() else { return processed }
                    _ = await classifier.classify(meetingID: id, config: config)
                    processed += 1
                    cursor = id
                }
            }
            return processed
        }
        batchTask = task
        let processed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if batchTask == task { batchTask = nil }
        fputs("[folder-classify] batch processed=\(processed)\n", stderr)
        return processed
    }

    func cancelBatch() {
        batchTask?.cancel()
        batchTask = nil
    }
}
