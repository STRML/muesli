import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Shared fixtures for the issue 46 tests. Kept outside `BufferedDictationFinalizerTests` because
/// that suite is main-actor isolated and these helpers are not.
enum IncrementalTestKit {
    /// Eight-word sentences, so three of them put 16 words behind the first.
    static let a1 = "The first sentence has eight words total."
    static let a2 = "Second one follows right after it today."
    static let a3 = "Third sentence keeps the dictation going longer."
    static let a4 = "Fourth sentence is the last full one."
    static let a5 = "Fifth is still being spoken right now."

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Scripted recognition and cleanup. Passes beyond the script repeat its last transcript.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private let transcripts: [String]
        private let passGates: [Int: Gate]
        private let cleanGates: [Int: Gate]
        private let failingPass: Int?
        private var passes = 0
        private var returnedPasses = 0
        private var cleanings: [String] = []

        init(transcripts: [String], passGates: [Int: Gate] = [:],
             cleanGates: [Int: Gate] = [:], failingPass: Int? = nil) {
            self.transcripts = transcripts
            self.passGates = passGates
            self.cleanGates = cleanGates
            self.failingPass = failingPass
        }

        /// Passes that started, and passes whose result has been handed back to the session.
        var passCount: Int { lock.withLock { passes } }
        var returnedPassCount: Int { lock.withLock { returnedPasses } }
        var cleanedChunks: [String] { lock.withLock { cleanings } }

        var hooks: IncrementalDictationSession.Hooks {
            .init(transcribe: { [self] _ in
                let index = lock.withLock { () -> Int in passes += 1; return passes }
                if index == failingPass { throw CocoaError(.fileNoSuchFile) }
                let text = transcripts[min(index, transcripts.count) - 1]
                if let gate = passGates[index] { await gate.wait() }
                lock.withLock { returnedPasses += 1 }
                return text
            }, clean: { [self] text in
                let index = lock.withLock { () -> Int in cleanings.append(text); return cleanings.count }
                if let gate = cleanGates[index] { await gate.wait() }
                return "<\(text)>"
            })
        }
    }

    /// Polls instead of sleeping, so a slow CI runner delays the test rather than failing it.
    static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    /// Feeds 0.25 s of audio every millisecond, as the recorder would, until stopped.
    static func startFeeding(_ session: IncrementalDictationSession) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                session.append(Array(repeating: 0.1, count: 4_000))
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    static func makeSession(_ script: Script, fingerprint: String = "f") -> IncrementalDictationSession {
        IncrementalDictationSession(fingerprint: fingerprint, hooks: script.hooks, cadence: .milliseconds(2),
            minimumChunkWords: 0, firstPassSamples: 32_000)
    }

    static func join(_ sentences: String...) -> String { sentences.joined(separator: " ") }
}

private let a1 = IncrementalTestKit.a1
private let a2 = IncrementalTestKit.a2
private let a3 = IncrementalTestKit.a3
private let a4 = IncrementalTestKit.a4
private let a5 = IncrementalTestKit.a5

/// Issue 46 (https://github.com/STRML/muesli/issues/46): cleanup while the hold-to-talk key is held.
/// These nested suites belong to `BufferedDictationFinalizerTests` so CI's dictation shard runs them.
extension BufferedDictationFinalizerTests {
    // MARK: Setting, eligibility

    struct IncrementalEligibility {
        private func environment(_ edit: (inout IncrementalDictationPolicy.Environment) -> Void = { _ in })
            -> IncrementalDictationPolicy.Environment {
            var value = IncrementalDictationPolicy.Environment(
                settingEnabled: true, physicalMemory: 16 * 1024 * 1024 * 1024, providerIsLocal: true,
                recognizer: .parakeetUnified, cleanupEnabled: true, cleanupIsLocal: true,
                cleanupFormat: .s1Mini, outputIsPaste: true, isTestMode: false,
                capturesScreenContext: false, buffersStreamingOutput: false)
            edit(&value)
            return value
        }

        @Test func defaultOffAndMalformedValuesStayOff() throws {
            #expect(!AppConfig().enableIncrementalHoldToTalk)
            for json in ["{}", #"{"enable_incremental_hold_to_talk":"true"}"#, #"{"enable_incremental_hold_to_talk":1}"#] {
                let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
                #expect(!config.enableIncrementalHoldToTalk)
            }
            var on = AppConfig()
            on.enableIncrementalHoldToTalk = true
            let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(on))
            #expect(restored.enableIncrementalHoldToTalk)
        }

        @Test func everyConditionIsRequired() {
            #expect(IncrementalDictationPolicy.isEligible(environment()))
            let cases: [(String, (inout IncrementalDictationPolicy.Environment) -> Void)] = [
                ("setting_off", { $0.settingEnabled = false }),
                ("under_16_gb", { $0.physicalMemory = 8 * 1024 * 1024 * 1024 }),
                ("hosted_provider", { $0.providerIsLocal = false }),
                ("recognizer_not_supported", { $0.recognizer = .whisperSmall }),
                ("cleanup_off", { $0.cleanupEnabled = false }),
                ("cleanup_not_local", { $0.cleanupIsLocal = false }),
                ("cleanup_model_not_supported", { $0.cleanupFormat = .muesliTrainedV12Qwen08 }),
                ("cleanup_model_not_supported", { $0.cleanupFormat = nil }),
                ("not_paste_output", { $0.outputIsPaste = false }),
                ("test_mode", { $0.isTestMode = true }),
                ("screen_context_on", { $0.capturesScreenContext = true }),
                ("buffered_output", { $0.buffersStreamingOutput = true }),
            ]
            for (reason, edit) in cases {
                #expect(IncrementalDictationPolicy.ineligibleReason(environment(edit)) == reason)
            }
        }

        @Test func exactlySixteenGigabytesQualifies() {
            #expect(IncrementalDictationPolicy.isEligible(environment { $0.physicalMemory = 16 * 1024 * 1024 * 1024 }))
            #expect(!IncrementalDictationPolicy.isEligible(environment { $0.physicalMemory = 16 * 1024 * 1024 * 1024 - 1 }))
        }

        @Test @MainActor func controllerKeepsTodaysPathUnderSixteenGigabytesOrSettingOff() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("incremental-eligibility-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
            try store.migrateIfNeeded()
            let controller = MuesliController(
                runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
                dictationStore: store, configStore: makeTestConfigStore(supportDirectory: directory))
            controller.updateConfig { $0.enableIncrementalHoldToTalk = true }
            controller.incrementalDictationPhysicalMemoryForTesting = 8 * 1024 * 1024 * 1024
            controller.beginIncrementalDictationForTesting()
            #expect(!controller.hasIncrementalDictationForTesting)
            controller.incrementalDictationPhysicalMemoryForTesting = 64 * 1024 * 1024 * 1024
            controller.updateConfig { $0.enableIncrementalHoldToTalk = false }
            controller.beginIncrementalDictationForTesting()
            #expect(!controller.hasIncrementalDictationForTesting)
        }
    }

    // MARK: Stability tracking

    struct IncrementalTracking {
        @Test func sentenceCommitsAfterThreeUnchangedPassesAndTwelveWordsBehind() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 0)
            let text = IncrementalTestKit.join(a1, a2, a3)
            #expect(tracker.observe(text) == .none)
            #expect(tracker.observe(text) == .none)
            #expect(tracker.observe(text) == .commit([a1]))
            // Two sentences, eight words, behind a2 is not enough.
            #expect(tracker.observe(text) == .none)
            #expect(tracker.committed == [a1])
        }

        @Test func sentenceCloseToTheNewestWordNeverCommits() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 0)
            let text = IncrementalTestKit.join(a1, a2)
            for _ in 0..<10 { #expect(tracker.observe(text) == .none) }
        }

        @Test func aSentenceThatKeepsChangingResetsItsStreak() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 0)
            let others = IncrementalTestKit.join(a3, a4, a5)
            #expect(tracker.observe("One thing here. " + others) == .none)
            #expect(tracker.observe("Another thing here. " + others) == .none)
            #expect(tracker.observe("One thing here. " + others) == .none)
            #expect(tracker.observe("One thing here. " + others) == .none)
            // Sixteen words follow the first sentence by now, so the next one goes with it.
            #expect(tracker.observe("One thing here. " + others) == .commit(["One thing here.", a3]))
        }

        @Test func eachSentenceCommitsOnceAndInOrder() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 0)
            let long = IncrementalTestKit.join(a1, a2, a3, a4, a5)
            _ = tracker.observe(long)
            _ = tracker.observe(long)
            // Only a1 to a3 have more than twelve words behind them.
            #expect(tracker.observe(long) == .commit([a1, a2, a3]))
            #expect(tracker.observe(long) == .none)
            #expect(tracker.committed == [a1, a2, a3])
        }

        @Test func punctuationAndCaseChangesInACommittedSentenceAreNotDivergence() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 0)
            let long = IncrementalTestKit.join(a1, a2, a3, a4, a5)
            for _ in 0..<3 { _ = tracker.observe(long) }
            let repunctuated = IncrementalTestKit.join("the first sentence has eight words, total!", a2, a3, a4, a5)
            #expect(tracker.observe(repunctuated) == .none)
        }

        @Test func smallBatchesWaitUntilEnoughStableWordsAreWaiting() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 20)
            let long = IncrementalTestKit.join(a1, a2, a3, a4, a5)
            _ = tracker.observe(long)
            _ = tracker.observe(long)
            // a1 to a3 are stable: 24 words, which is enough.
            #expect(tracker.observe(long) == .commit([a1, a2, a3]))
            var strict = IncrementalSentenceTracker(minimumChunkWords: 30)
            for _ in 0..<5 { #expect(strict.observe(long) == .none) }
            #expect(strict.committed.isEmpty)
        }

        @Test func aCommittedSentenceThatChangesIsReportedAsDivergence() {
            var tracker = IncrementalSentenceTracker(minimumChunkWords: 0)
            let long = IncrementalTestKit.join(a1, a2, a3, a4, a5)
            for _ in 0..<3 { _ = tracker.observe(long) }
            let revised = IncrementalTestKit.join("A different first sentence entirely.", a2, a3, a4, a5)
            #expect(tracker.observe(revised) == .diverged)
        }

        @Test func referBackCuesAreCaughtAnywhereAndCorrectionOpenersOnlyAtTheTailStart() {
            for cue in ["Scratch that, make it Friday.", "First point, book the venue.", "Never mind about it.",
                        "Add a bullet point here.", "Start a new paragraph."] {
                #expect(IncrementalDictationCues.containsReferBackCue("Some text before. " + cue))
            }
            #expect(!IncrementalDictationCues.containsReferBackCue("The list of scratches is long."))
            // Ordinary English that merely contains a deletion phrase is not a command.
            #expect(!IncrementalDictationCues.containsReferBackCue("Don't forget that the reports are due. We never mind the rain."))
            #expect(IncrementalDictationCues.containsReferBackCue("Okay, forget that. Use Friday."))
            #expect(IncrementalDictationCues.tailStartsWithCorrection("Actually, make it Friday."))
            #expect(IncrementalDictationCues.tailStartsWithCorrection("No no, the other one."))
            #expect(!IncrementalDictationCues.tailStartsWithCorrection("We actually shipped it."))
            // The first sentence after the cut can refer back across it; later ones cannot.
            #expect(IncrementalDictationCues.tailRefersBack("Forget that detail. Then we ship."))
            #expect(IncrementalDictationCues.tailRefersBack("Yes, scratch that. Then we ship."))
            #expect(!IncrementalDictationCues.tailRefersBack("We ship it. Forget that detail."))
            #expect(!IncrementalDictationCues.tailRefersBack("Don't forget that we ship on Friday."))
        }
    }

    // MARK: Session (one test per failure-matrix row)

    struct IncrementalSessionMatrix {
        /// Three passes of three sentences commit a1; later passes with a fourth commit a2.
        static let growing = [
            IncrementalTestKit.join(a1, a2, a3),
            IncrementalTestKit.join(a1, a2, a3),
            IncrementalTestKit.join(a1, a2, a3),
            IncrementalTestKit.join(a1, a2, a3, a4),
        ]
        static let finalText = IncrementalTestKit.join(a1, a2, a3, a4, a5)

        private func ready(_ script: IncrementalTestKit.Script, cleanCalls: Int)
            async throws -> (IncrementalDictationSession, Task<Void, Never>) {
            let session = IncrementalTestKit.makeSession(script)
            let feeder = IncrementalTestKit.startFeeding(session)
            await session.start()
            #expect(await IncrementalTestKit.eventually { script.cleanedChunks.count >= cleanCalls })
            return (session, feeder)
        }

        private func resolve(_ session: IncrementalDictationSession, feeder: Task<Void, Never>,
                             final: String, fingerprint: String = "f") async -> IncrementalDictationSession.Outcome {
            feeder.cancel()
            await session.keyUp()
            return await session.resolve(finalTranscript: final, recordedSampleCount: session.receivedSamples,
                                         currentFingerprint: fingerprint)
        }

        // Row: clip under ~2 s.
        @Test func shortClipUsesTodaysPath() async {
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let session = IncrementalTestKit.makeSession(script)
            await session.start()
            session.append(Array(repeating: 0.1, count: 20_000))
            try? await Task.sleep(for: .milliseconds(40))
            let outcome = await session.resolve(finalTranscript: Self.finalText,
                recordedSampleCount: session.receivedSamples, currentFingerprint: "f")
            #expect(outcome == .fallback(.shortClip))
            #expect(script.passCount == 0)
            #expect(script.cleanedChunks.isEmpty)
        }

        // Row: key up while a background ASR pass runs.
        @Test func recognitionPassFinishingAfterKeyUpIsDiscarded() async throws {
            let gate = IncrementalTestKit.Gate()
            // Pass 5 is held open, then returns a transcript that contradicts a committed sentence.
            let stale = IncrementalTestKit.join("A stale first sentence that must never matter.", Self.growing[3])
            let script = IncrementalTestKit.Script(transcripts: Self.growing + [stale], passGates: [5: gate])
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            #expect(await IncrementalTestKit.eventually { script.passCount >= 5 })
            feeder.cancel()
            await session.keyUp()
            await gate.open()
            // Wait until the session has handled the stale result, so the outcome below proves it was ignored.
            #expect(await IncrementalTestKit.eventually { script.returnedPassCount >= 5 })
            #expect(await IncrementalTestKit.eventually { await !session.isRecognizing })
            let outcome = await session.resolve(finalTranscript: Self.finalText,
                recordedSampleCount: session.receivedSamples, currentFingerprint: "f")
            // The stale pass would have reported divergence and poisoned the session.
            #expect(outcome == .reuse(cleanedPrefix: "<\(a1)> <\(a2)>", tailRaw: IncrementalTestKit.join(a3, a4, a5)))
            #expect(!script.cleanedChunks.contains { $0.contains("stale") })
        }

        // Row: key up while a background cleanup runs and its sentences are still in the final text.
        @Test func pendingCleanupIsAwaitedWhenItsSentencesSurvive() async throws {
            let gate = IncrementalTestKit.Gate()
            let script = IncrementalTestKit.Script(transcripts: Self.growing, cleanGates: [2: gate])
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            feeder.cancel()
            await session.keyUp()
            let finished = IncrementalTestKit.Flag()
            let resolution = Task { () -> IncrementalDictationSession.Outcome in
                let outcome = await session.resolve(finalTranscript: Self.finalText,
                    recordedSampleCount: session.receivedSamples, currentFingerprint: "f")
                finished.set()
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(!finished.isSet)   // still waiting for the pending cleanup
            await gate.open()
            let outcome = await resolution.value
            #expect(outcome == .reuse(cleanedPrefix: "<\(a1)> <\(a2)>", tailRaw: IncrementalTestKit.join(a3, a4, a5)))
        }

        // Row: key up while a background cleanup runs and its sentence is gone from the final text.
        @Test func pendingCleanupIsDroppedWhenItsSentenceChanged() async throws {
            let gate = IncrementalTestKit.Gate()
            let script = IncrementalTestKit.Script(transcripts: Self.growing, cleanGates: [2: gate])
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            feeder.cancel()
            await session.keyUp()
            let revised = IncrementalTestKit.join(a1, "Second one was recognized differently now.", a3, a4, a5)
            let outcome = await session.resolve(finalTranscript: revised,
                recordedSampleCount: session.receivedSamples, currentFingerprint: "f")
            // The finished chunk for a1 stands; the pending chunk for a2 is dropped, never awaited.
            #expect(outcome == .reuse(cleanedPrefix: "<\(a1)>",
                tailRaw: IncrementalTestKit.join("Second one was recognized differently now.", a3, a4, a5)))
            await gate.open()
        }

        // The same words punctuated differently are the same prefix.
        @Test func finalTranscriptThatOnlyRepunctuatesThePrefixStillMatches() async throws {
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            let repunctuated = IncrementalTestKit.join(
                "The first sentence has eight words, total!", "Second one follows right after it today:", a3, a4, a5)
            let outcome = await resolve(session, feeder: feeder, final: repunctuated)
            #expect(outcome == .reuse(cleanedPrefix: "<\(a1)> <\(a2)>", tailRaw: IncrementalTestKit.join(a3, a4, a5)))
        }

        // Row: stable prefix differs from the final transcript.
        @Test func finishedPrefixThatDisagreesFallsBackWithoutPartialReuse() async throws {
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            // Both chunks must be finished, not merely started, for a mismatch to be fatal.
            #expect(await IncrementalTestKit.eventually { await session.finishedChunkCount == 2 })
            let revised = IncrementalTestKit.join("An entirely different opening sentence here now.", a2, a3, a4, a5)
            let outcome = await resolve(session, feeder: feeder, final: revised)
            #expect(outcome == .fallback(.prefixMismatch))
        }

        // Row: dictation cancelled (Esc).
        @Test func cancelDropsEverythingAndNothingIsReusableAfterwards() async throws {
            let gate = IncrementalTestKit.Gate()
            let script = IncrementalTestKit.Script(transcripts: Self.growing, cleanGates: [1: gate])
            let (session, feeder) = try await ready(script, cleanCalls: 1)
            await session.cancel()
            let passesAtCancel = script.passCount
            await gate.open()
            try? await Task.sleep(for: .milliseconds(40))
            feeder.cancel()
            #expect(script.passCount == passesAtCancel)
            let outcome = await session.resolve(finalTranscript: Self.finalText,
                recordedSampleCount: nil, currentFingerprint: "f")
            #expect(outcome == .fallback(.cancelled))
            #expect(session.receivedSamples == 0)
        }

        @Test @MainActor func escapeReachesTheBackgroundSession() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("incremental-cancel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
            try store.migrateIfNeeded()
            let controller = MuesliController(
                runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
                dictationStore: store, configStore: makeTestConfigStore(supportDirectory: directory))
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let session = IncrementalTestKit.makeSession(script)
            session.append(Array(repeating: 0.1, count: 1_600))
            controller.installIncrementalDictationForTesting(session)
            #expect(controller.hasIncrementalDictationForTesting)
            controller.cancelDictationForTesting()
            #expect(!controller.hasIncrementalDictationForTesting)
            // The controller cancels the session from a task it starts; cancelling empties the audio.
            #expect(await IncrementalTestKit.eventually { session.receivedSamples == 0 })
            let outcome = await session.resolve(finalTranscript: Self.finalText,
                recordedSampleCount: nil, currentFingerprint: "f")
            #expect(outcome == .fallback(.cancelled))
        }

        // Row: model unloaded or switched mid-hold.
        @Test func configurationChangeBetweenKeyDownAndKeyUpFallsBack() async throws {
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            let outcome = await resolve(session, feeder: feeder, final: Self.finalText, fingerprint: "other model")
            #expect(outcome == .fallback(.configurationChanged))
        }

        @Test func aFailingBackgroundPassPoisonsTheSession() async throws {
            let script = IncrementalTestKit.Script(transcripts: Self.growing, failingPass: 2)
            let session = IncrementalTestKit.makeSession(script)
            let feeder = IncrementalTestKit.startFeeding(session)
            await session.start()
            #expect(await IncrementalTestKit.eventually { await session.failure == .passFailed })
            let outcome = await resolve(session, feeder: feeder, final: Self.finalText)
            #expect(outcome == .fallback(.passFailed))
        }

        // Row: spoken list or "scratch that" across the cut.
        @Test func referBackCuesFallBack() async throws {
            for cue in ["Scratch that, make it Friday instead.", "First point, book the venue and second point, order lunch."] {
                let script = IncrementalTestKit.Script(transcripts: Self.growing)
                let (session, feeder) = try await ready(script, cleanCalls: 2)
                let outcome = await resolve(session, feeder: feeder, final: Self.finalText + " " + cue)
                #expect(outcome == .fallback(.referBackCue))
            }
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            // a1 and a2 are committed, so the tail opens with the correction.
            let tail = IncrementalTestKit.join(a1, a2, "Actually, make that the third sentence.")
            #expect(await resolve(session, feeder: feeder, final: tail) == .fallback(.referBackCue))
        }

        @Test func aCueInsideAStableSentenceStopsBackgroundCleanup() async throws {
            let cued = "Scratch that and write the following down instead."
            let script = IncrementalTestKit.Script(transcripts: [IncrementalTestKit.join(cued, a2, a3, a4)])
            let session = IncrementalTestKit.makeSession(script)
            let feeder = IncrementalTestKit.startFeeding(session)
            await session.start()
            // The third pass would commit the cued sentence; the session stops there instead.
            #expect(await IncrementalTestKit.eventually { await session.failure == .referBackCue })
            #expect(script.passCount == 3)
            #expect(script.cleanedChunks.isEmpty)
            feeder.cancel()
            await session.keyUp()
            let outcome = await session.resolve(finalTranscript: Self.finalText,
                recordedSampleCount: session.receivedSamples, currentFingerprint: "f")
            #expect(outcome == .fallback(.referBackCue))
        }

        // Guard: the live samples must be exactly the recorded ones.
        @Test func audioThatDoesNotMatchTheRecordingFallsBack() async throws {
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            feeder.cancel()
            await session.keyUp()
            let outcome = await session.resolve(finalTranscript: Self.finalText,
                recordedSampleCount: session.receivedSamples + 160, currentFingerprint: "f")
            #expect(outcome == .fallback(.coverageMismatch))
        }

        @Test func nothingCommittedMeansTodaysPath() async throws {
            let script = IncrementalTestKit.Script(transcripts: [IncrementalTestKit.join(a1, a2)])
            let session = IncrementalTestKit.makeSession(script)
            let feeder = IncrementalTestKit.startFeeding(session)
            await session.start()
            #expect(await IncrementalTestKit.eventually { script.passCount >= 6 })
            let outcome = await resolve(session, feeder: feeder, final: IncrementalTestKit.join(a1, a2))
            #expect(outcome == .fallback(.nothingCommitted))
        }

        @Test func healthyDictationReusesTheCleanedPrefixOnce() async throws {
            let script = IncrementalTestKit.Script(transcripts: Self.growing)
            let (session, feeder) = try await ready(script, cleanCalls: 2)
            let outcome = await resolve(session, feeder: feeder, final: Self.finalText)
            #expect(outcome == .reuse(cleanedPrefix: "<\(a1)> <\(a2)>", tailRaw: IncrementalTestKit.join(a3, a4, a5)))
            #expect(script.cleanedChunks == [a1, a2])
        }
    }

    // MARK: Coordinator

    struct IncrementalCoordinator {
        private func failingCleanupCoordinator() async -> TranscriptionCoordinator {
            let coordinator = TranscriptionCoordinator()
            let missing = PostProcessorOption(
                id: "incremental-missing-\(UUID().uuidString)", label: "Missing", sizeLabel: "0", description: "",
                downloadURL: URL(string: "https://example.invalid/none.gguf")!, filename: "none.gguf")
            await coordinator.configurePostProcessor(
                backend: .local, option: missing, systemPrompt: PostProcessorOption.defaultSystemPrompt, config: AppConfig())
            return coordinator
        }

        // Row: cleanup fails or the guard rejects a chunk.
        @Test func aFailedChunkKeepsItsRecognizedTextLikeTodaysPath() async {
            let coordinator = await failingCleanupCoordinator()
            let chunk = "Um, this is the chunk that cleanup cannot handle."
            let viaChunk = await coordinator.cleanDictationChunk(chunk, backend: .parakeetUnified)
            let viaToday = await coordinator.finalizeDictationTranscript(
                .init(text: chunk, segments: []), backend: .parakeetUnified, enablePostProcessor: true)
            #expect(viaChunk == viaToday.text)
            #expect(!viaChunk.isEmpty)
        }

        @Test func joiningAppliesCustomWordsAndLayoutOnceToTheWholeText() async {
            let coordinator = await failingCleanupCoordinator()
            let words: [[String: Any]] = [["word": "muesly", "replacement": "Muesli", "matchingThreshold": 1.0]]
            let result = await coordinator.finalizeIncrementalDictationTranscript(
                cleanedPrefix: "Hello muesly.", tailRaw: "Goodbye muesly.", backend: .parakeetUnified, customWords: words)
            let today = await coordinator.finalizeDictationTranscript(
                .init(text: "Hello muesly. Goodbye muesly.", segments: []), backend: .parakeetUnified,
                enablePostProcessor: true, customWords: words)
            #expect(result.text == today.text)
            #expect(result.text.contains("Muesli"))
        }
    }
}
