import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Real-pipeline checks for issue 46: Parakeet recognition and the S1-mini cleanup model, driven
/// through `IncrementalDictationSession` exactly as the controller drives it, on WAV fixtures.
///
/// Off unless MUESLI_INCREMENTAL_E2E=1 and MUESLI_INCREMENTAL_FIXTURE_DIR names a folder of
/// 16 kHz mono clips named cNN.wav (see the PR for how the TTS fixtures were made). It needs the
/// installed Parakeet model and S1-mini cleanup model and never downloads anything.
extension BufferedDictationFinalizerTests {
    struct IncrementalPipeline {
        static var environment: [String: String] { ProcessInfo.processInfo.environment }
        static var enabled: Bool {
            environment["MUESLI_INCREMENTAL_E2E"] == "1" && environment["MUESLI_INCREMENTAL_FIXTURE_DIR"] != nil
        }
        static var measuring: Bool { enabled && environment["MUESLI_INCREMENTAL_MEASURE"] == "1" }
        static var minimumChunkWords: Int {
            environment["MUESLI_INCREMENTAL_MIN_CHUNK"].flatMap(Int.init) ?? IncrementalDictationPolicy.minimumChunkWords
        }

        static let backend: BackendOption = .parakeetUnified

        /// One loaded recognizer and cleanup model for the whole run.
        actor Rig {
            static let shared = Rig()
            private var coordinator: TranscriptionCoordinator?
            func coordinator(failingCleanup: Bool = false) async throws -> TranscriptionCoordinator {
                if failingCleanup {
                    let broken = TranscriptionCoordinator()
                    try await broken.preloadRequired(backend: IncrementalPipeline.backend, includeMeetingHelpers: false)
                    let missing = PostProcessorOption(
                        id: "incremental-missing-\(UUID().uuidString)", label: "Missing", sizeLabel: "0", description: "",
                        downloadURL: URL(string: "https://example.invalid/none.gguf")!, filename: "none.gguf",
                        inputFormat: .s1Mini)
                    await broken.configurePostProcessor(backend: .local, option: missing,
                        systemPrompt: PostProcessorOption.defaultSystemPrompt, config: AppConfig())
                    return broken
                }
                if let coordinator { return coordinator }
                let made = TranscriptionCoordinator()
                try await made.preloadRequired(backend: IncrementalPipeline.backend, includeMeetingHelpers: false)
                let config = AppConfig()
                await made.configurePostProcessor(backend: .local, option: .s1Mini,
                    systemPrompt: PostProcessorOption.defaultSystemPrompt, config: config)
                if #available(macOS 15, *) {
                    try await made.prepareLocalCleanupForRecording(option: .s1Mini, config: config)
                }
                coordinator = made
                return made
            }
        }

        static var fixtureDirectory: URL {
            URL(fileURLWithPath: environment["MUESLI_INCREMENTAL_FIXTURE_DIR"] ?? "/nonexistent")
        }

        static func wav(_ id: String) -> URL { fixtureDirectory.appendingPathComponent("\(id).wav") }

        static func samples(_ id: String) throws -> [Float] {
            try AudioConverter().resampleAudioFile(wav(id))
        }

        struct Outcome {
            var text: String
            var keyUpToText: Double
            var resolution: String
            var passes: Int
            var chunks: Int
            var note: String
        }

        /// Hooks that wrap the real coordinator, with optional interception for race tests.
        struct Intercept: Sendable {
            var afterRecognition: @Sendable (Int, String) async -> String = { _, text in text }
            var beforeCleanup: @Sendable (Int, String) async -> Void = { _, _ in }
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            @discardableResult func next() -> Int { lock.withLock { value += 1; return value } }
            var current: Int { lock.withLock { value } }
        }

        /// What the controller does on key-up, after the audio has been fed.
        /// `feed` receives the session and returns the key-up instant.
        static func run(
            id: String,
            coordinator: TranscriptionCoordinator,
            speed: Double,
            intercept: Intercept = Intercept(),
            stopAfterSeconds: Double? = nil,
            action: (@Sendable (IncrementalDictationSession) async -> Void)? = nil,
            finalTranscriptOverride: String? = nil
        ) async throws -> Outcome {
            let all = try samples(id)
            let limit = stopAfterSeconds.map { min(all.count, Int($0 * 16_000)) } ?? all.count
            let passes = Counter(), cleanings = Counter()
            let backend = Self.backend
            let hooks = IncrementalDictationSession.Hooks(
                transcribe: { samples in
                    let index = passes.next()
                    let text = try await coordinator.transcribeDictationSnapshot(
                        samples: samples, backend: backend)
                    return await intercept.afterRecognition(index, text)
                },
                clean: { text in
                    let index = cleanings.next()
                    await intercept.beforeCleanup(index, text)
                    return await coordinator.cleanDictationChunk(text, backend: backend)
                })
            let session = IncrementalDictationSession(fingerprint: "e2e", hooks: hooks, minimumChunkWords: Self.minimumChunkWords)
            await session.start()
            let started = ContinuousClock.now
            let step = 1_600
            var offset = 0
            while offset < limit {
                let end = min(offset + step, limit)
                session.append(Array(all[offset..<end]))
                offset = end
                let due = started + .milliseconds(Int(Double(offset) / 16.0 / speed))
                try? await Task.sleep(until: due, clock: .continuous)
            }
            if let action { await action(session) }
            // Key-up.
            let keyUp = ContinuousClock.now
            await session.keyUp()
            let result = try await finalize(id: id, session: session, coordinator: coordinator,
                recordedSamples: limit == all.count ? all.count : limit, wav: wav(id),
                finalTranscriptOverride: finalTranscriptOverride)
            let elapsed = keyUp.duration(to: .now)
            let note = await session.lastNote
            await session.cancel()
            return Outcome(text: result.text, keyUpToText: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18, resolution: result.resolution,
                passes: passes.current, chunks: cleanings.current, note: note)
        }

        static func finalize(
            id: String, session: IncrementalDictationSession, coordinator: TranscriptionCoordinator,
            recordedSamples: Int, wav: URL, finalTranscriptOverride: String?
        ) async throws -> (text: String, resolution: String) {
            let raw = try await coordinator.transcribeDictationRaw(at: wav, backend: backend)
            let final = await coordinator.artifactCleanedDictationText(raw)
            let outcome = await session.resolve(
                finalTranscript: finalTranscriptOverride ?? final,
                recordedSampleCount: recordedSamples, currentFingerprint: "e2e")
            switch outcome {
            case .reuse(let prefix, let tail):
                let result = await coordinator.finalizeIncrementalDictationTranscript(
                    cleanedPrefix: prefix, tailRaw: tail, backend: backend)
                return (result.text, "reuse")
            case .fallback(let reason):
                let result = await coordinator.finalizeDictationTranscript(
                    raw, backend: backend, enablePostProcessor: true)
                return (result.text, "fallback:\(reason.rawValue)")
            }
        }

        static func todaysPath(id: String, coordinator: TranscriptionCoordinator) async throws -> (text: String, seconds: Double) {
            let start = ContinuousClock.now
            let result = try await coordinator.transcribeDictation(at: wav(id), backend: backend, enablePostProcessor: true)
            let elapsed = start.duration(to: .now)
            return (result.text, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }

        static func words(_ text: String) -> [String] {
            text.lowercased().unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
                .reduce(into: "") { $0.append($1) }
                .split(separator: " ").map(String.init)
        }

        // MARK: Matrix rows on real audio and models

        @Test(.enabled(if: IncrementalPipeline.enabled)) func shortClipUsesTodaysPath() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let new = try await Self.run(id: "c01", coordinator: coordinator, speed: 4)
            let old = try await Self.todaysPath(id: "c01", coordinator: coordinator)
            #expect(new.resolution == "fallback:short_clip")
            #expect(new.text == old.text)
        }

        @Test(.enabled(if: IncrementalPipeline.enabled)) func keyUpWhileARecognitionPassIsRunning() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let held = IncrementalTestKit.Gate()
            let started = Counter()
            // Hold the third pass open past key-up, then let it return text that contradicts the audio.
            let intercept = Intercept(afterRecognition: { index, text in
                guard index == 3 else { return text }
                started.next()
                await held.wait()
                return "A stale sentence from before the key went up. " + text
            })
            let new = try await Self.run(id: "c10", coordinator: coordinator, speed: 8, intercept: intercept,
                action: { _ in
                    while started.current == 0 { try? await Task.sleep(for: .milliseconds(5)) }
                    // The final recognition takes longer than this, so the stale pass lands mid-finalization.
                    Task { try? await Task.sleep(for: .milliseconds(150)); await held.open() }
                })
            await held.open()
            #expect(started.current == 1)
            #expect(!new.text.contains("stale sentence"))
            #expect(new.resolution != "fallback:diverged")
        }

        @Test(.enabled(if: IncrementalPipeline.enabled)) func keyUpWhileACleanupRuns() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let held = IncrementalTestKit.Gate()
            let entered = Counter()
            let intercept = Intercept(beforeCleanup: { index, _ in
                guard index == 1 else { return }
                entered.next()
                await held.wait()
            })
            let new = try await Self.run(id: "c13", coordinator: coordinator, speed: 8, intercept: intercept,
                action: { _ in
                    while entered.current == 0 { try? await Task.sleep(for: .milliseconds(5)) }
                    Task { try? await Task.sleep(for: .milliseconds(300)); await held.open() }
                })
            await held.open()
            // Key-up found the chunk still being cleaned, waited for it, and used it.
            #expect(entered.current == 1)
            #expect(new.resolution == "reuse")
            #expect(!new.text.isEmpty)
        }

        @Test(.enabled(if: IncrementalPipeline.enabled)) func finalTranscriptDisagreeingWithThePrefixFallsBack() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let other = try await coordinator.transcribeDictationRaw(at: Self.wav("c11"), backend: Self.backend)
            let otherText = await coordinator.artifactCleanedDictationText(other)
            let new = try await Self.run(id: "c13", coordinator: coordinator, speed: 8, finalTranscriptOverride: otherText)
            #expect(new.resolution == "fallback:prefix_mismatch" || new.resolution == "fallback:nothing_committed")
        }

        @Test(.enabled(if: IncrementalPipeline.enabled)) func aFailingCleanupKeepsEachChunksRecognizedText() async throws {
            let coordinator = try await Rig.shared.coordinator(failingCleanup: true)
            let new = try await Self.run(id: "c13", coordinator: coordinator, speed: 8)
            let old = try await coordinator.transcribeDictation(
                at: Self.wav("c13"), backend: Self.backend, enablePostProcessor: true)
            #expect(new.resolution == "reuse")
            #expect(!new.text.isEmpty)
            #expect(Self.words(new.text) == Self.words(old.text))
        }

        @Test(.enabled(if: IncrementalPipeline.enabled)) func cancellingDropsAllInFlightWork() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let all = try Self.samples("c13")
            let calls = Counter()
            let hooks = IncrementalDictationSession.Hooks(
                transcribe: { samples in
                    _ = calls.next()
                    return try await coordinator.transcribeDictationSnapshot(
                        samples: samples, backend: Self.backend)
                }, clean: { text in
                    _ = calls.next()
                    return await coordinator.cleanDictationChunk(text, backend: Self.backend)
                })
            let session = IncrementalDictationSession(fingerprint: "e2e", hooks: hooks, minimumChunkWords: Self.minimumChunkWords)
            await session.start()
            let started = ContinuousClock.now
            for offset in stride(from: 0, to: 20 * 16_000, by: 1_600) {
                session.append(Array(all[offset..<offset + 1_600]))
                try? await Task.sleep(until: started + .milliseconds(offset / 16 / 4), clock: .continuous)
            }
            await session.cancel()
            let callsAtCancel = calls.current
            try? await Task.sleep(for: .seconds(2))
            #expect(calls.current <= callsAtCancel + 1)   // at most the call that was already running
            let outcome = await session.resolve(finalTranscript: "anything", recordedSampleCount: nil, currentFingerprint: "e2e")
            #expect(outcome == .fallback(.cancelled))
        }

        @Test(.enabled(if: IncrementalPipeline.enabled)) func aModelUnloadedMidHoldFallsBackToTodaysPath() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let unloaded = Counter()
            let intercept = Intercept(afterRecognition: { index, text in
                if index == 2, unloaded.current == 0 {
                    _ = unloaded.next()
                    await coordinator.unloadParakeetUnifiedTranscriber()
                }
                return text
            })
            // The unload happens during the hold; reload before key-up as the app would on its next use.
            let new = try await Self.run(id: "c10", coordinator: coordinator, speed: 8, intercept: intercept,
                action: { _ in try? await coordinator.preloadRequired(backend: Self.backend, includeMeetingHelpers: false) })
            let old = try await Self.todaysPath(id: "c10", coordinator: coordinator)
            #expect(new.resolution == "fallback:pass_failed")
            #expect(new.text == old.text)
        }

        @Test(.enabled(if: IncrementalPipeline.enabled), arguments: ["c19", "c20"])
        func scratchThatAndSpokenListsKeepTodaysPath(id: String) async throws {
            let coordinator = try await Rig.shared.coordinator()
            let new = try await Self.run(id: id, coordinator: coordinator, speed: 8)
            let old = try await Self.todaysPath(id: id, coordinator: coordinator)
            #expect(new.resolution.hasPrefix("fallback"))
            #expect(new.text == old.text)
        }

        // MARK: Latency and text equivalence over every clip

        @Test(.enabled(if: IncrementalPipeline.measuring)) func latencyAndTextOldVersusNew() async throws {
            let coordinator = try await Rig.shared.coordinator()
            let speed = Double(Self.environment["MUESLI_INCREMENTAL_SPEED"] ?? "1") ?? 1
            let report = Self.environment["MUESLI_INCREMENTAL_REPORT"] ?? "/tmp/incremental-latency.tsv"
            let only = Self.environment["MUESLI_INCREMENTAL_CLIPS"].map { Set($0.split(separator: ",").map(String.init)) }
            let ids = try FileManager.default.contentsOfDirectory(at: Self.fixtureDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
                .filter { only?.contains($0) ?? true }
            var rows = ["clip\tsec\told_s\tnew_s\tresolution\tchunks\tpasses\tsame\twords_same\tnote\told\tnew"]
            for id in ids {
                let seconds = Double(try Self.samples(id).count) / 16_000
                // Today's path before and after the new path, so neither side gets a warmer cache.
                let old = try await Self.todaysPath(id: id, coordinator: coordinator)
                let new = try await Self.run(id: id, coordinator: coordinator, speed: speed)
                let oldAgain = try await Self.todaysPath(id: id, coordinator: coordinator)
                let oldMean = (old.seconds + oldAgain.seconds) / 2
                rows.append([
                    id, String(format: "%.1f", seconds), String(format: "%.3f", oldMean),
                    String(format: "%.3f", new.keyUpToText), new.resolution, String(new.chunks), String(new.passes),
                    old.text == new.text ? "same" : "DIFF",
                    Self.words(old.text) == Self.words(new.text) ? "same" : "DIFF",
                    new.note,
                    old.text.replacingOccurrences(of: "\n", with: "\\n"),
                    new.text.replacingOccurrences(of: "\n", with: "\\n"),
                ].joined(separator: "\t"))
                try rows.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
            }
        }
    }
}
