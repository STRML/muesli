import Foundation
import NaturalLanguage

/// Hold-to-talk dictation that cleans up sentences while the key is still held
/// (https://github.com/STRML/muesli/issues/46).
///
/// While the key is down, an `IncrementalDictationSession` re-transcribes the audio so far on a
/// fixed cadence and cleans up sentences that stopped changing. On key-up the controller still
/// runs today's final recognition on the recorded WAV; the session then either hands back the
/// already-cleaned prefix plus the raw tail, or says "fall back" and today's finalization runs
/// unchanged. Nothing the session produces is ever pasted directly: its output only enters the
/// pipeline through `resolve`, which compares it with the final transcript.
enum IncrementalDictationPolicy {
    /// How often a background recognition pass may start while the key is held.
    static let cadence: Duration = .milliseconds(400)
    /// Clips shorter than this keep today's path (16 kHz mono samples).
    static let minimumClipSamples = 2 * 16_000
    /// No pass runs before this much audio exists: until then too few words are stable for a
    /// pass to ever pay for itself, and a pass still running at key-up only delays the final one.
    static let firstPassSamples = 12 * 16_000
    /// A pass needs at least this much new audio (0.25 s) since the previous one.
    static let minimumNewSamplesPerPass = 4_000
    /// A sentence is stable after appearing unchanged in this many consecutive passes.
    static let stablePasses = 3
    /// ... and when more than this many words follow it.
    static let minimumWordsBehind = 12
    /// A chunk is cleaned only once at least this many stable words are waiting.
    static let minimumChunkWords = 40
    /// The feature is for Macs with 16 GiB or more.
    static let minimumPhysicalMemory: UInt64 = 16 * 1024 * 1024 * 1024

    /// Recognizers whose snapshot decode is the same call as their file decode, and that were
    /// measured against today's path. Anything else keeps today's path.
    static func supportsRecognizer(_ backend: BackendOption) -> Bool {
        backend == .parakeetUnified
    }

    /// Cleanup formats whose chunked output was measured against whole-text output.
    static func supportsCleanupFormat(_ format: PostProcessorOption.InputFormat) -> Bool {
        measuredCleanupFormats.contains(format)
    }

    private static let measuredCleanupFormats: Set<PostProcessorOption.InputFormat> = [.s1Mini]

    /// Everything the controller knows when the key goes down. All must hold.
    struct Environment {
        var settingEnabled: Bool
        var physicalMemory: UInt64
        var providerIsLocal: Bool
        var recognizer: BackendOption
        var cleanupEnabled: Bool
        var cleanupIsLocal: Bool
        var cleanupFormat: PostProcessorOption.InputFormat?
        var outputIsPaste: Bool
        var isTestMode: Bool
        var capturesScreenContext: Bool
        var buffersStreamingOutput: Bool
    }

    static func ineligibleReason(_ environment: Environment) -> String? {
        if !environment.settingEnabled { return "setting_off" }
        if environment.physicalMemory < minimumPhysicalMemory { return "under_16_gb" }
        if !environment.providerIsLocal { return "hosted_provider" }
        if !supportsRecognizer(environment.recognizer) { return "recognizer_not_supported" }
        if !environment.cleanupEnabled { return "cleanup_off" }
        if !environment.cleanupIsLocal { return "cleanup_not_local" }
        guard let format = environment.cleanupFormat, supportsCleanupFormat(format) else {
            return "cleanup_model_not_supported"
        }
        if !environment.outputIsPaste { return "not_paste_output" }
        if environment.isTestMode { return "test_mode" }
        // Screen context arrives after recording starts; chunks cleaned before it lands would
        // see a different prompt than today's path does.
        if environment.capturesScreenContext { return "screen_context_on" }
        if environment.buffersStreamingOutput { return "buffered_output" }
        return nil
    }

    static func isEligible(_ environment: Environment) -> Bool {
        ineligibleReason(environment) == nil
    }
}

/// Splits a transcript into trimmed sentences.
enum IncrementalSentenceSplitter {
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Words with their positions, ignoring case and punctuation. Whole-audio recognition passes
/// disagree about punctuation near sentence ends far more often than about words, so a
/// committed prefix is matched against the final transcript word by word.
enum IncrementalWordAlignment {
    struct Word {
        let normalized: String
        let end: String.Index
    }

    static func words(_ text: String) -> [Word] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [Word] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(Word(normalized: text[range].lowercased(), end: range.upperBound))
            return true
        }
        return result
    }

    static func normalizedWords(_ text: String) -> [String] {
        words(text).map(\.normalized)
    }

    /// The text after the first `count` words, without the punctuation that closed them.
    static func remainder(of text: String, afterWords count: Int, in words: [Word]) -> String {
        guard count < words.count else { return "" }
        guard count > 0 else { return text }
        let rest = text[words[count - 1].end...]
        return String(rest.drop(while: { !$0.isLetter && !$0.isNumber }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Phrases that make a cut between two chunks unsafe: the cleanup model treats the text on both
/// sides of the cut as one document when it formats lists and applies "scratch that".
enum IncrementalDictationCues {
    private static let deletionPhrases = [
        "scratch that", "scratch this", "delete that", "forget that", "never mind", "strike that",
        "cancel that", "undo that", "start over", "no wait",
    ]

    /// A deletion phrase said as a command: opening a sentence or clause. "Don't forget that the
    /// report is due" is ordinary English and must not count.
    private static let deletionCommand = try! NSRegularExpression(
        pattern: #"(?:^|[.!?,;:\n]\s*|\b(?:and|so|okay|ok|um|uh|oh|well)\s+)(?:"#
            + deletionPhrases.joined(separator: "|") + #")\b"#,
        options: [.caseInsensitive])

    /// Spoken list and layout commands.
    private static let listAndLayoutCues = [
        "bullet point", "bulleted list", "numbered list", "first point", "second point",
        "third point", "next point", "new line", "new paragraph",
    ]

    private static let correctionOpeners = [
        "actually", "wait", "no no", "sorry", "i mean", "correction", "rather", "or rather",
        "make that", "change that", "instead", "hold on", "um actually", "uh actually",
    ]

    /// Anywhere in the dictation. Erring wide only costs the speed-up for that dictation.
    static func containsReferBackCue(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if deletionCommand.firstMatch(in: text, range: range) != nil { return true }
        let padded = " " + words(text).joined(separator: " ") + " "
        return listAndLayoutCues.contains { padded.contains(" " + $0 + " ") }
    }

    /// The first sentence after the cut is the one that can refer back across it: an opening that
    /// corrects what came before, or a deletion command anywhere in that sentence.
    static func tailRefersBack(_ tail: String) -> Bool {
        if tailStartsWithCorrection(tail) { return true }
        guard let first = IncrementalSentenceSplitter.sentences(tail).first else { return false }
        return deletionCommand.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil
    }

    /// The tail opens by correcting what came before the cut.
    static func tailStartsWithCorrection(_ tail: String) -> Bool {
        let opening = " " + words(tail).prefix(4).joined(separator: " ") + " "
        return correctionOpeners.contains { opening.hasPrefix(" " + $0 + " ") }
    }

    private static func words(_ text: String) -> [String] {
        let letters = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(letters).split(separator: " ").map(String.init)
    }
}

/// Decides which sentences have stopped changing across successive whole-audio passes.
struct IncrementalSentenceTracker {
    enum Event: Equatable {
        case none
        /// Newly stable sentences, in order, to be cleaned as one chunk.
        case commit([String])
        /// A sentence that was already committed changed.
        case diverged
    }

    /// Committed sentences, as recognized when they were committed.
    private(set) var committed: [String] = []
    /// The same text word by word. Later passes may punctuate it differently; the words are
    /// what must not change.
    private var committedWords: [String] = []
    private var previous: [String] = []
    private var streaks: [Int] = []
    private let stablePasses: Int
    private let minimumWordsBehind: Int
    private let minimumChunkWords: Int

    init(
        stablePasses: Int = IncrementalDictationPolicy.stablePasses,
        minimumWordsBehind: Int = IncrementalDictationPolicy.minimumWordsBehind,
        minimumChunkWords: Int = IncrementalDictationPolicy.minimumChunkWords
    ) {
        self.stablePasses = stablePasses
        self.minimumWordsBehind = minimumWordsBehind
        self.minimumChunkWords = minimumChunkWords
    }

    mutating func observe(_ transcript: String) -> Event {
        let sentences = IncrementalSentenceSplitter.sentences(transcript)
        let words = IncrementalWordAlignment.normalizedWords(transcript)
        if !committedWords.isEmpty {
            guard words.count >= committedWords.count,
                  Array(words[0..<committedWords.count]) == committedWords else { return .diverged }
        }
        streaks = sentences.indices.map { index in
            index < previous.count && previous[index] == sentences[index] ? streaks[index] + 1 : 1
        }
        previous = sentences
        guard let start = firstUncommittedSentence(in: sentences) else { return .none }
        let wordCounts = sentences.map(IncrementalSentenceSplitter.wordCount)
        var wordsAfter = Array(repeating: 0, count: sentences.count)
        var running = 0
        for index in sentences.indices.reversed() {
            wordsAfter[index] = running
            running += wordCounts[index]
        }
        var end = start
        while end < sentences.count, streaks[end] >= stablePasses, wordsAfter[end] > minimumWordsBehind {
            end += 1
        }
        guard end > start else { return .none }
        let batch = Array(sentences[start..<end])
        // Fewer, larger chunks leave fewer seams for the cleanup model to treat differently
        // from the whole dictation. Small batches wait for more sentences to become stable.
        guard batch.map(IncrementalSentenceSplitter.wordCount).reduce(0, +) >= minimumChunkWords else { return .none }
        committed += batch
        committedWords += IncrementalWordAlignment.normalizedWords(batch.joined(separator: " "))
        return .commit(batch)
    }

    /// The sentence that begins right after the committed words, or nil when this pass draws its
    /// sentence boundary somewhere inside them. Nothing new can commit on such a pass.
    private func firstUncommittedSentence(in sentences: [String]) -> Int? {
        guard !committedWords.isEmpty else { return 0 }
        var offset = 0
        for (index, sentence) in sentences.enumerated() {
            if offset == committedWords.count { return index }
            offset += IncrementalWordAlignment.normalizedWords(sentence).count
        }
        return offset == committedWords.count ? sentences.count : nil
    }
}

/// Lock-protected sample buffer: the recorder calls `append` from its own thread.
private final class IncrementalAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var accepting = true

    func append(_ incoming: [Float]) {
        // Match what the recorder writes to the WAV (16-bit PCM read back as Float) so a
        // background pass hears the same signal the final pass will.
        let quantized = incoming.map { Float(Int16(max(-1, min(1, $0)) * 32767)) / 32768 }
        lock.lock()
        if accepting { samples.append(contentsOf: quantized) }
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func close() {
        lock.lock()
        accepting = false
        samples = []
        lock.unlock()
    }
}

actor IncrementalDictationSession {
    struct Hooks: Sendable {
        /// Recognizes the audio so far. Must not load or download a model.
        let transcribe: @Sendable ([Float]) async throws -> String
        /// Cleans one chunk exactly as today's finalization cleans a whole dictation,
        /// including its fallback when cleanup fails. Never throws.
        let clean: @Sendable (String) async -> String
    }

    enum Fallback: String, Sendable, Equatable {
        case shortClip = "short_clip"
        case nothingCommitted = "nothing_committed"
        case cancelled
        case passFailed = "pass_failed"
        case diverged
        case referBackCue = "refer_back_cue"
        case prefixMismatch = "prefix_mismatch"
        case coverageMismatch = "coverage_mismatch"
        case configurationChanged = "configuration_changed"
    }

    enum Outcome: Equatable, Sendable {
        /// `cleanedPrefix` is already cleaned; `tailRaw` still needs cleanup.
        case reuse(cleanedPrefix: String, tailRaw: String)
        case fallback(Fallback)
    }

    private enum Phase: Equatable {
        case running
        case keyUp
        case cancelled
        case failed(Fallback)
    }

    private struct Chunk {
        /// The chunk's recognized text, and its normalized words, which are compared with the
        /// final transcript at key-up.
        let text: String
        let words: [String]
        let task: Task<String, Never>
        var cleaned: String?
    }

    private let hooks: Hooks
    private let fingerprint: String
    private let cadence: Duration
    private nonisolated let audio = IncrementalAudioBuffer()
    private var tracker: IncrementalSentenceTracker
    private var chunks: [Chunk] = []
    private var loop: Task<Void, Never>?
    private var phase: Phase = .running
    private var generation = 0
    private var passInFlight = false
    private var lastPassSampleCount = 0
    private var lastPassDuration: Duration = .zero
    private let firstPassSamples: Int
    private(set) var passCount = 0
    /// Why the last comparison with the final transcript went the way it did. Diagnostics only.
    private(set) var lastNote = ""

    /// `fingerprint` identifies the recognizer and cleanup configuration in force when the key
    /// went down; `resolve` refuses to reuse anything if it differs at key-up.
    init(
        fingerprint: String,
        hooks: Hooks,
        cadence: Duration = IncrementalDictationPolicy.cadence,
        minimumChunkWords: Int = IncrementalDictationPolicy.minimumChunkWords,
        firstPassSamples: Int = IncrementalDictationPolicy.firstPassSamples
    ) {
        self.fingerprint = fingerprint
        self.hooks = hooks
        self.cadence = cadence
        self.firstPassSamples = firstPassSamples
        self.tracker = IncrementalSentenceTracker(minimumChunkWords: minimumChunkWords)
    }

    /// Called from the recorder's thread.
    nonisolated func append(_ samples: [Float]) {
        audio.append(samples)
    }

    /// Chunks whose cleanup has finished. Lets tests and diagnostics wait for a state
    /// instead of sleeping.
    var finishedChunkCount: Int { chunks.filter { $0.cleaned != nil }.count }

    /// A recognition pass is running, or its result has not been handled yet.
    var isRecognizing: Bool { passInFlight }

    /// Set once the session has given up for a reason other than key-up or cancel.
    var failure: Fallback? {
        if case .failed(let reason) = phase { return reason }
        return nil
    }

    nonisolated var receivedSamples: Int { audio.count }

    func start() {
        guard loop == nil, phase == .running else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.nextPassDelay() else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                await self.runPass()
            }
        }
    }

    /// The cadence, stretched so that recognition is busy at most a third of the time. A pass
    /// still running at key-up delays the final recognition, and the longer the audio the longer a pass.
    private func nextPassDelay() -> Duration {
        max(cadence, lastPassDuration * 2)
    }

    /// The key went up. No further pass or cleanup may start; whatever is in flight can finish
    /// but its recognition result is discarded.
    func keyUp() {
        guard phase == .running else { return }
        phase = .keyUp
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// Escape, a meeting taking over, a recorder failure, or any other reason the dictation will
    /// not finish. Everything in flight is cancelled and nothing is reusable afterwards.
    func cancel() {
        phase = .cancelled
        generation += 1
        loop?.cancel()
        loop = nil
        chunks.forEach { $0.task.cancel() }
        chunks = []
        audio.close()
    }

    func resolve(
        finalTranscript: String,
        recordedSampleCount: Int?,
        currentFingerprint: String
    ) async -> Outcome {
        keyUp()
        let outcome = await decide(finalTranscript, recordedSampleCount, currentFingerprint)
        if case .fallback = outcome { cancel() }
        return outcome
    }

    private func decide(
        _ finalTranscript: String,
        _ recordedSampleCount: Int?,
        _ currentFingerprint: String
    ) async -> Outcome {
        switch phase {
        case .cancelled: return .fallback(.cancelled)
        case .failed(let reason): return .fallback(reason)
        case .running, .keyUp: break
        }
        guard fingerprint == currentFingerprint else { return .fallback(.configurationChanged) }
        let received = audio.count
        guard received >= IncrementalDictationPolicy.minimumClipSamples else { return .fallback(.shortClip) }
        guard recordedSampleCount == received else { return .fallback(.coverageMismatch) }
        guard !chunks.isEmpty else { return .fallback(.nothingCommitted) }
        guard !IncrementalDictationCues.containsReferBackCue(finalTranscript) else {
            return .fallback(.referBackCue)
        }

        let finalWords = IncrementalWordAlignment.words(finalTranscript)
        let finalTokens = finalWords.map(\.normalized)
        var offset = 0
        var kept = 0
        var repunctuated = 0
        for (index, chunk) in chunks.enumerated() {
            let end = offset + chunk.words.count
            if end <= finalTokens.count, Array(finalTokens[offset..<end]) == chunk.words {
                // The words match; note when the final pass punctuated them differently.
                let from = offset == 0 ? finalTranscript.startIndex : finalWords[offset - 1].end
                let slice = finalTranscript[from..<finalWords[max(end, 1) - 1].end]
                if Self.core(String(slice)) != Self.core(chunk.text) { repunctuated += 1 }
                offset = end
                kept += 1
                continue
            }
            // A finished chunk that disagrees with the final transcript means the whole
            // prefix is in doubt. A chunk still being cleaned is simply dropped.
            lastNote = "chunk \(index) of \(chunks.count) at word \(offset): expected "
                + chunk.words.prefix(8).joined(separator: " ") + " | final "
                + finalTokens.dropFirst(offset).prefix(8).joined(separator: " ")
            if chunk.cleaned != nil { return .fallback(.prefixMismatch) }
            break
        }
        chunks[kept...].forEach { $0.task.cancel() }
        chunks.removeSubrange(kept...)
        guard !chunks.isEmpty else { return .fallback(.nothingCommitted) }

        var cleanedChunks: [String] = []
        for chunk in chunks {
            let cleaned = await chunk.task.value
            guard phase != .cancelled else { return .fallback(.cancelled) }
            cleanedChunks.append(cleaned)
        }
        let tail = IncrementalWordAlignment.remainder(of: finalTranscript, afterWords: offset, in: finalWords)
        guard !IncrementalDictationCues.tailRefersBack(tail) else {
            return .fallback(.referBackCue)
        }
        let prefix = cleanedChunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        lastNote = "reuse chunks=\(chunks.count) repunctuated=\(repunctuated)"
        return .reuse(cleanedPrefix: prefix, tailRaw: tail)
    }

    /// The text without the punctuation around it, for comparing wording alone.
    private static func core(_ text: String) -> String {
        var body = Substring(text)
        while let first = body.first, !first.isLetter && !first.isNumber { body = body.dropFirst() }
        while let last = body.last, !last.isLetter && !last.isNumber { body = body.dropLast() }
        return String(body)
    }

    private func runPass() async {
        guard phase == .running, !passInFlight else { return }
        let snapshot = audio.snapshot()
        guard snapshot.count >= firstPassSamples,
              snapshot.count - lastPassSampleCount >= IncrementalDictationPolicy.minimumNewSamplesPerPass
        else { return }
        passInFlight = true
        lastPassSampleCount = snapshot.count
        passCount += 1
        let started = generation
        let passStart = ContinuousClock.now
        do {
            let text = try await hooks.transcribe(snapshot)
            lastPassDuration = passStart.duration(to: .now)
            passInFlight = false
            // A pass that finishes after key-up or cancel describes audio the final pass
            // supersedes; it must never start cleanup.
            guard started == generation, phase == .running else { return }
            apply(text)
        } catch {
            passInFlight = false
            guard started == generation, phase == .running else { return }
            fail(.passFailed)
        }
    }

    private func apply(_ transcript: String) {
        switch tracker.observe(transcript) {
        case .none:
            return
        case .diverged:
            fail(.diverged)
        case .commit(let sentences):
            let text = sentences.joined(separator: " ")
            guard !IncrementalDictationCues.containsReferBackCue(text) else {
                fail(.referBackCue)
                return
            }
            let index = chunks.count
            let hooks = hooks
            let task = Task { [weak self] () -> String in
                let cleaned = await hooks.clean(text)
                await self?.markCleaned(index, cleaned)
                return cleaned
            }
            chunks.append(Chunk(text: text, words: IncrementalWordAlignment.normalizedWords(text), task: task, cleaned: nil))
        }
    }

    private func markCleaned(_ index: Int, _ text: String) {
        guard index < chunks.count else { return }
        chunks[index].cleaned = text
    }

    private func fail(_ reason: Fallback) {
        phase = .failed(reason)
        generation += 1
        loop?.cancel()
        loop = nil
        chunks.forEach { $0.task.cancel() }
    }
}
