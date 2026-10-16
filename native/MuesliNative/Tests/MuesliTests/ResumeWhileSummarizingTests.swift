import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

// Failure matrix rows are named R1...R10 in the test names; see the PR body.

@Suite("Resume availability policy")
struct ResumeAvailabilityPolicyTests {
    private func availability(
        _ status: MeetingStatus,
        retranscribing: Bool = false,
        otherRecording: Bool = false,
        finalizing: Bool = false
    ) -> MeetingResumePolicy.Availability {
        MeetingResumePolicy.availability(
            status: status,
            isRetranscriptionRunning: retranscribing,
            isAnotherRecordingActive: otherRecording,
            hasActiveFinalization: finalizing
        )
    }

    @Test("R1: a processing row with a live post-Stop pipeline offers Resume")
    func processingWithFinalizationIsEnabled() {
        #expect(availability(.processing, finalizing: true) == .enabled)
    }

    @Test("R1: a processing row without a pipeline (stale, or being retranscribed) hides Resume")
    func processingWithoutFinalizationIsHidden() {
        #expect(availability(.processing) == .hidden)
    }

    @Test("a completed row offers Resume")
    func completedIsEnabled() {
        #expect(availability(.completed) == .enabled)
    }

    @Test("R7: retranscription shows Resume disabled with the reason, never hidden")
    func retranscriptionDisablesWithReason() {
        let expected = MeetingResumePolicy.Availability.disabled(reason: MeetingResumePolicy.retranscriptionDisabledReason)
        #expect(availability(.completed, retranscribing: true) == expected)
        #expect(availability(.processing, retranscribing: true) == expected)
        #expect(!MeetingResumePolicy.retranscriptionDisabledReason.isEmpty)
    }

    @Test("R8: no Resume while a recording is active or starting")
    func activeRecordingHidesResume() {
        #expect(availability(.completed, otherRecording: true) == .hidden)
        #expect(availability(.processing, otherRecording: true, finalizing: true) == .hidden)
        #expect(availability(.recording) == .hidden)
    }

    @Test("R10: note-only and failed rows are unchanged")
    func noteOnlyAndFailedStayHidden() {
        #expect(availability(.noteOnly) == .hidden)
        #expect(availability(.failed) == .hidden)
    }
}

@Suite("Late summary policy")
struct LateSummaryPolicyTests {
    @Test("a summary lands on a finished, uncancelled row")
    func persistsOnCompletedRow() {
        #expect(MeetingResumePolicy.shouldPersistSummary(rowStatus: .completed, wasCancelled: false))
    }

    @Test("R3: a summary that finishes after the row is recording or processing is dropped")
    func dropsWhenRowMoved() {
        for status in [MeetingStatus.recording, .processing] {
            #expect(!MeetingResumePolicy.shouldPersistSummary(rowStatus: status, wasCancelled: false))
        }
        #expect(!MeetingResumePolicy.shouldPersistSummary(rowStatus: nil, wasCancelled: false))
    }

    @Test("summaries still land on note-only and failed rows, which users can summarize today")
    func stillPersistsOnNoteOnlyAndFailed() {
        for status in [MeetingStatus.noteOnly, .failed] {
            #expect(MeetingResumePolicy.shouldPersistSummary(rowStatus: status, wasCancelled: false))
            #expect(MeetingResumePolicy.shouldSurfaceSummaryFailure(rowStatus: status, wasCancelled: false))
        }
    }

    @Test("R2: a cancelled summary never persists, even on a completed row")
    func dropsWhenCancelled() {
        #expect(!MeetingResumePolicy.shouldPersistSummary(rowStatus: .completed, wasCancelled: true))
    }

    @Test("R4: failures are shown only for an uncancelled summary on a finished row")
    func failureSurfacing() {
        #expect(MeetingResumePolicy.shouldSurfaceSummaryFailure(rowStatus: .completed, wasCancelled: false))
        #expect(!MeetingResumePolicy.shouldSurfaceSummaryFailure(rowStatus: .completed, wasCancelled: true))
        #expect(!MeetingResumePolicy.shouldSurfaceSummaryFailure(rowStatus: .recording, wasCancelled: false))
    }

    @Test("R6: a cancelled summary leaves blank notes, so the resumed stop must summarize everything")
    func regenerationCoversBlankNotes() {
        #expect(MeetingResumePolicy.needsSummaryRegeneration(hasNewContent: true, existingNotes: "## Notes", combinedTranscript: "a"))
        #expect(MeetingResumePolicy.needsSummaryRegeneration(hasNewContent: false, existingNotes: "  \n", combinedTranscript: "a"))
        #expect(MeetingResumePolicy.needsSummaryRegeneration(hasNewContent: false, existingNotes: nil, combinedTranscript: "a"))
        #expect(!MeetingResumePolicy.needsSummaryRegeneration(hasNewContent: false, existingNotes: "## Notes", combinedTranscript: "a"))
        #expect(!MeetingResumePolicy.needsSummaryRegeneration(hasNewContent: false, existingNotes: "", combinedTranscript: " "))
    }
}

private final class RanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

private struct GateTestError: Error {}

@Suite("Summary stage gate")
struct MeetingSummaryStageGateTests {
    @Test("an uncancelled gate returns the work result")
    func returnsResult() async throws {
        let gate = MeetingSummaryStageGate()
        #expect(try await gate.run { 7 } == 7)
    }

    @Test("R2: cancelling mid-flight drops the result even though the work completes")
    func cancelMidFlightDropsResult() async throws {
        let gate = MeetingSummaryStageGate()
        let run = Task {
            try await gate.run { () async -> Int in
                try? await Task.sleep(for: .milliseconds(300))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        gate.cancel()
        #expect(try await run.value == nil)
        #expect(gate.isCancelled)
    }

    @Test("a gate cancelled before the stage starts never runs the work")
    func cancelBeforeRunSkipsWork() async throws {
        let gate = MeetingSummaryStageGate()
        gate.cancel()
        let ran = RanFlag()
        let result = try await gate.run { () async -> Int in ran.set(); return 1 }
        #expect(result == nil)
        #expect(!ran.value)
    }

    @Test("R4: a failure after cancellation is swallowed, not thrown")
    func failureAfterCancelIsSwallowed() async throws {
        let gate = MeetingSummaryStageGate()
        let run = Task {
            try await gate.run { () async throws -> Int in
                try? await Task.sleep(for: .milliseconds(200))
                throw GateTestError()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        gate.cancel()
        #expect(try await run.value == nil)
    }

    @Test("a failure with no cancellation still throws")
    func failureWithoutCancelThrows() async {
        let gate = MeetingSummaryStageGate()
        await #expect(throws: GateTestError.self) {
            _ = try await gate.run { () async throws -> Int in throw GateTestError() }
        }
    }
}

@MainActor
@Suite("Resume while summarizing: controller")
struct ResumeWhileSummarizingControllerTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-resume-sum-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeController(store: DictationStore) -> MuesliController {
        MuesliController(
            runtime: RuntimePaths(repoRoot: FileManager.default.temporaryDirectory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("muesli-resume-sum-support-\(UUID().uuidString)", isDirectory: true))
        )
    }

    private func insertCompletedMeeting(_ store: DictationStore) throws -> Int64 {
        let now = Date()
        return try store.insertMeeting(
            title: "Standup", calendarEventID: nil, startTime: now, endTime: now.addingTimeInterval(60),
            rawTranscript: "Prior transcript", formattedNotes: "## Notes", micAudioPath: nil, systemAudioPath: nil
        )
    }

    /// A fake `claude` CLI that answers after `delay` seconds.
    private func makeFakeClaude(delay: Double, success: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-resume-sum-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("claude")
        let payload = success
            ? #"{"type":"result","subtype":"success","result":"Fresh notes"}"#
            : #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}"#
        try "#!/bin/sh\nsleep \(delay)\nprintf '%s' '\(payload)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func configure(_ controller: MuesliController, cli: URL) {
        controller.updateConfig {
            $0.meetingSummaryBackend = MeetingSummaryBackendOption.claudeCode.backend
            $0.claudeCodeExecutablePath = cli.path
        }
    }

    @Test("R1/R2: Resume on a processing row defers behind the pipeline, cancels its summary, and writes nothing")
    func resumeOnProcessingRowDefersAndCancelsSummary() throws {
        let store = try makeStore()
        let id = try insertCompletedMeeting(store)
        try store.updateMeetingStatus(id: id, status: .processing)
        let controller = makeController(store: store)
        let gate = MeetingSummaryStageGate()
        let row = try #require(try store.meeting(id: id))

        #expect(controller.resumeAvailability(for: row) == .hidden)
        controller.trackMeetingFinalization(meetingID: id, gate: gate)
        #expect(controller.resumeAvailability(for: row) == .enabled)

        controller.resumeFinishedMeeting(meetingID: id)

        #expect(gate.isCancelled)
        #expect(controller.hasDeferredResume(meetingID: id))
        #expect(controller.resumeAvailability(for: row) == .disabled(reason: MeetingResumePolicy.resumePendingReason))
        let after = try #require(try store.meeting(id: id))
        #expect(after.status == .processing)
        #expect(after.rawTranscript == "Prior transcript")
        #expect(after.formattedNotes == "## Notes")

        #expect(controller.finishMeetingFinalizationTracking(meetingID: id))
        #expect(!controller.hasDeferredResume(meetingID: id))
        #expect(!controller.finishMeetingFinalizationTracking(meetingID: id))
    }

    @Test("finishing the pipeline without a Resume request starts nothing")
    func finishWithoutResumeRequest() throws {
        let store = try makeStore()
        let id = try insertCompletedMeeting(store)
        let controller = makeController(store: store)
        controller.trackMeetingFinalization(meetingID: id, gate: MeetingSummaryStageGate())
        #expect(!controller.finishMeetingFinalizationTracking(meetingID: id))
    }

    @Test("R2/R6: a cancelled re-summarize never writes notes and the previous notes stay")
    func cancelledResummaryKeepsPreviousNotes() async throws {
        let store = try makeStore()
        let id = try insertCompletedMeeting(store)
        let controller = makeController(store: store)
        configure(controller, cli: try makeFakeClaude(delay: 0.5, success: true))
        let meeting = try #require(try store.meeting(id: id))

        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            controller.resummarize(meeting: meeting) { continuation.resume(returning: $0) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                controller.cancelInFlightResummary(meetingID: id)
            }
        }
        guard case .failure(let error) = outcome else { Issue.record("expected cancellation"); return }
        #expect(error is CancellationError)
        #expect(try store.meeting(id: id)?.formattedNotes == "## Notes")
    }

    @Test("R3: a summary that completes after the row became recording does not overwrite it")
    func lateSummaryDoesNotOverwriteRecordingRow() async throws {
        let store = try makeStore()
        let id = try insertCompletedMeeting(store)
        let controller = makeController(store: store)
        configure(controller, cli: try makeFakeClaude(delay: 0.4, success: true))
        let meeting = try #require(try store.meeting(id: id))

        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            controller.resummarize(meeting: meeting) { continuation.resume(returning: $0) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                _ = try? store.prepareMeetingForResume(id: id)
            }
        }
        guard case .failure(let error) = outcome else { Issue.record("expected the late result to be dropped"); return }
        #expect(error is CancellationError)
        let row = try #require(try store.meeting(id: id))
        #expect(row.status == .recording)
        #expect(row.formattedNotes == "## Notes")
    }

    @Test("R4: a summary that fails after Resume reports cancellation, not an error, and leaves the row recording")
    func failedSummaryAfterResumeIsSilent() async throws {
        let store = try makeStore()
        let id = try insertCompletedMeeting(store)
        let controller = makeController(store: store)
        configure(controller, cli: try makeFakeClaude(delay: 0.4, success: false))
        let meeting = try #require(try store.meeting(id: id))

        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            controller.resummarize(meeting: meeting) { continuation.resume(returning: $0) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                controller.cancelInFlightResummary(meetingID: id)
                _ = try? store.prepareMeetingForResume(id: id)
            }
        }
        guard case .failure(let error) = outcome else { Issue.record("expected failure"); return }
        #expect(error is CancellationError)
        #expect(try store.meeting(id: id)?.status == .recording)
    }
}

@Suite("Resume start failure and crash recovery")
struct ResumeStartFailureStoreTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-resume-store-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func insert(_ store: DictationStore, notes: String) throws -> Int64 {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return try store.insertMeeting(
            title: "Standup", calendarEventID: nil, startTime: now, endTime: now.addingTimeInterval(120),
            rawTranscript: "Prior transcript", formattedNotes: notes, micAudioPath: nil, systemAudioPath: nil
        )
    }

    @Test("R5: a failed resume start returns the row to completed with transcript and notes intact")
    func failedStartRestoresRow() throws {
        let store = try makeStore()
        let id = try insert(store, notes: "")
        _ = try store.prepareMeetingForResume(id: id)
        #expect(try store.restoreResumedMeetingIfNeeded(id: id))
        let row = try #require(try store.meeting(id: id))
        #expect(row.status == .completed)
        #expect(row.rawTranscript == "Prior transcript")
        #expect(row.formattedNotes == "")
    }

    @Test("R9: a crash during a resume of a summary-cancelled row recovers a consistent completed row")
    func crashRecoveryAfterCancelledSummary() throws {
        let store = try makeStore()
        let id = try insert(store, notes: "")
        _ = try store.prepareMeetingForResume(id: id)
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "10:03:01", speaker: "You", startSeconds: 1, endSeconds: 3, text: "More words")
        ])
        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id))
        let row = try #require(try store.meeting(id: id))
        #expect(row.status == .completed)
        #expect(row.rawTranscript.hasPrefix("Prior transcript"))
        #expect(row.rawTranscript.contains("More words"))
    }
}
