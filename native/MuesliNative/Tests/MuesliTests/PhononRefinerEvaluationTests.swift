import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Opt-in checks that need model weights, a GPU or the network, for the Phonon refiner (LFM3-1.7B):
/// numerical parity with `transformers`, the managed install path, and the quality and latency
/// comparison against Pro Cleanup (Qwen 3.5). Each test returns at once unless its environment is set.
///
/// - `MUESLI_LFM3_PARITY_ROOT`: directory written by `scripts/phonon-refiner-parity/reference.py` (or
///   `reference64.py`): reference.json plus one `<case>.steps.bin` of float32 logits per case;
///   `MUESLI_PHONON_MODEL_DIR`: the MLX weights. See the README next to those scripts.
/// - `MUESLI_PHONON_INSTALL_ROOT`: a scratch directory; the test downloads the pinned release into it.
/// - `MUESLI_CLEANUP_EVAL_SET`: JSONL rows, `MUESLI_CLEANUP_EVAL_OUT`: output directory,
///   `MUESLI_PHONON_MODEL_DIR` and `MUESLI_PROQWEN_MODEL_DIR`: installed model folders.
@Suite(.serialized)
struct PhononRefinerEvaluationTests {
    init() {
        // Swift Build places the Metal resource in a nested test bundle.
        if let path = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"] {
            GPU.metallib = URL(fileURLWithPath: path)
        }
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: - Parity with transformers

    private struct ReferenceCase: Decodable {
        let prompt_ids: [Int]
        let greedy: [Int]
        let steps: Int
        let vocab: Int
        let decoded: String
    }

    private static func floats(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test func lfm3ParityAgainstTransformers() async throws {
        guard let root = Self.environment["MUESLI_LFM3_PARITY_ROOT"],
              let modelDirectory = Self.environment["MUESLI_PHONON_MODEL_DIR"] else { return }
        let reference = try JSONDecoder().decode([String: ReferenceCase].self,
            from: Data(contentsOf: URL(fileURLWithPath: root + "/reference.json")))
        let factory = LLMModelFactory(typeRegistry: LFM3Model.typeRegistry, modelRegistry: LLMRegistry.shared)
        let container = try await factory.loadContainer(
            from: URL(fileURLWithPath: modelDirectory), using: CleanupHFTokenizerLoader())
        var worstOverall: Float = 0
        for (name, expected) in reference.sorted(by: { $0.key < $1.key }) {
            let steps = try Self.floats(at: URL(fileURLWithPath: root + "/\(name).steps.bin"))
            #expect(steps.count == expected.steps * expected.vocab, "\(name): reference logits size")
            let observed = try await container.perform { context -> (ids: [Int], tokens: [Int], diffs: [Float], top1Match: [Bool]) in
                // The model is fed the reference's own prompt ids; the tokenizer is checked separately below.
                let ids = expected.prompt_ids
                let cache = try context.model.newCache(parameters: nil)
                var logits = context.model(MLXArray(ids.map(Int32.init)).reshaped(1, -1), cache: cache)[0, -1]
                var tokens: [Int] = []
                var diffs: [Float] = []
                var top1: [Bool] = []
                for step in 0..<expected.steps {
                    let row = logits.asType(.float32).asArray(Float.self)
                    let base = step * expected.vocab
                    var worst: Float = 0
                    var referenceBest = 0
                    var referenceBestValue = -Float.infinity
                    for index in 0..<expected.vocab {
                        worst = max(worst, abs(row[index] - steps[base + index]))
                        if steps[base + index] > referenceBestValue { referenceBestValue = steps[base + index]; referenceBest = index }
                    }
                    let best = argMax(logits).item(Int.self)
                    diffs.append(worst)
                    top1.append(best == referenceBest)
                    // Teacher-force the reference token so one early flip cannot hide later steps.
                    let next = step < expected.greedy.count ? expected.greedy[step] : best
                    tokens.append(best)
                    // A reference that stops at EOS has exactly `steps` entries; one that ignores EOS runs on.
                    if step == expected.steps - 1 { break }
                    logits = context.model(MLXArray([Int32(next)]).reshaped(1, 1), cache: cache)[0, -1]
                }
                return (ids, tokens, diffs, top1)
            }
            let maxDiff = observed.diffs.max() ?? .infinity
            worstOverall = max(worstOverall, maxDiff)
            let agree = observed.top1Match.filter { $0 }.count
            let flips = observed.top1Match.enumerated().filter { !$0.element }.map(\.offset)
            let eosStep = expected.greedy.firstIndex(of: 124_900)
            print("LFM3 PARITY \(name) prompt_tokens=\(expected.prompt_ids.count) steps=\(observed.diffs.count) max_abs_logit_diff=\(maxDiff) first_step_diff=\(observed.diffs.first ?? .nan) top1_agree=\(agree)/\(observed.top1Match.count) tokens_equal=\(observed.tokens == expected.greedy) eos_step=\(eosStep.map(String.init) ?? "none") flipped_steps=\(flips)")
            // Float32 weights must agree everywhere. The shipped 4/6/8-bit weights must agree through the end
            // of the answer (the EOS step); a 64-step run that ignores EOS keeps decoding past it, where the
            // distribution is flat and quantization noise can flip a near-tie.
            let strict = Self.environment["MUESLI_LFM3_PARITY_STRICT"] == "1" || eosStep == nil
            let checkedSteps = strict ? observed.top1Match.count : (eosStep ?? 0) + 1
            // Top-1 agreement alone is a weak gate: a wrong window or rope can leave every argmax intact. The logits
            // must stay within bf16 arithmetic noise of the float32 reference (torch bf16 vs torch float32 on these
            // prompts: 0.24; the quantized weights here: 0.40; float32 weights in MLX: 0.016).
            let tolerance = Float(Self.environment["MUESLI_LFM3_PARITY_MAX_DIFF"] ?? "") ?? (strict ? 0.05 : 0.6)
            let checkedDiff = observed.diffs.prefix(checkedSteps).max() ?? .infinity
            #expect(checkedDiff <= tolerance, "\(name): max logit diff \(checkedDiff) over the answer exceeds \(tolerance)")
            #expect(observed.top1Match.prefix(checkedSteps).allSatisfy { $0 }, "\(name): top-1 token differs from transformers at steps \(flips)")
            #expect(Array(observed.tokens.prefix(checkedSteps)) == Array(expected.greedy.prefix(checkedSteps)), "\(name): greedy tokens differ from transformers")
        }
        print("LFM3 PARITY worst max_abs_logit_diff over all cases and steps = \(worstOverall)")

        // The tokenizer and the prompt builder must reproduce the reference's prompt ids exactly.
        let tokenizer = try await CleanupHFTokenizerLoader().load(from: URL(fileURLWithPath: modelDirectory))
        let prompts = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/reference.json"))) as? [String: [String: Any]] ?? [:]
        for (name, entry) in prompts {
            let text = try #require(entry["text"] as? String)
            let ids = try #require(entry["prompt_ids"] as? [Int])
            #expect(tokenizer.encode(text: text, addSpecialTokens: false) == ids, "\(name): Swift tokenizer ids")
        }
    }

    // MARK: - Production path against transformers

    private struct ParityCase {
        let name: String
        let bundleID: String
        let vocabulary: [String]
        let user: String
    }

    /// The same five dictations `reference.py` renders through the model's chat template.
    private static let parityCases: [ParityCase] = [
        ParityCase(name: "minimal_vocab", bundleID: "com.apple.Notes", vocabulary: ["Muesli", "Parakeet", "LFM"],
                   user: "um so we should ship the muesli build to the the testers on tuesday actually no thursday"),
        ParityCase(name: "casual", bundleID: "com.hnc.Discord", vocabulary: [],
                   user: "hey are you coming to the thing tonight i i think its at eight"),
        ParityCase(name: "formal_vocab", bundleID: "com.apple.mail", vocabulary: ["Phonon", "Acme Corp"],
                   user: "hi sam thanks for the update on the acme corp contract i will review it by friday best regards jordan"),
        ParityCase(name: "prompt_vocab", bundleID: "com.apple.Terminal", vocabulary: ["SwiftUI", "mlx-swift-lm"],
                   user: "add a swift ui view that shows the the model download progress using mlx swift lm and dont change the existing tests"),
        ParityCase(name: "long_sliding", bundleID: "com.apple.Notes", vocabulary: ["Muesli"],
                   user: String(repeating: "so um what i want to do is uh refactor the the cleanup post processor so that it takes the app context and the vocabulary and also the writing mode and then like it builds the the prompt in one place ", count: 6)
                       .trimmingCharacters(in: .whitespaces)),
    ]

    /// Prompt builder, tokenizer, chunked prefill, generation, output cap and guard, end to end:
    /// the text must be what `transformers` generates from the same chat-template prompt.
    @Test func productionPathMatchesTransformers() async throws {
        guard let root = Self.environment["MUESLI_LFM3_PARITY_ROOT"],
              let modelDirectory = Self.environment["MUESLI_PHONON_MODEL_DIR"] else { return }
        let reference = try JSONDecoder().decode([String: ReferenceCaseWithText].self,
            from: Data(contentsOf: URL(fileURLWithPath: root + "/reference.json")))
        let slot = try #require(CleanupModelSlot.slot(id: CleanupModelSlot.phononRefinerID))
        let engine = try await CleanupMLXEvaluation(
            directory: URL(fileURLWithPath: modelDirectory), descriptor: slot.bundled.artifact, model: .phonon)
        for testCase in Self.parityCases {
            let expected = try #require(reference[testCase.name])
            let context = PhononRefinerPrompt.Context(bundleID: testCase.bundleID, vocabulary: testCase.vocabulary)
            #expect(PhononRefinerPrompt.request(testCase.user, appContext: nil, context: context) == expected.text,
                    "\(testCase.name): prompt differs from the chat template")
            let result = try await engine.process(testCase.user, context: nil, writing: context)
            let referenceText = expected.decoded.replacingOccurrences(of: "<|im_end|>", with: "")
            print("PRODUCTION \(testCase.name) input_tokens=\(result.inputTokens) output_tokens=\(result.outputTokens) stop=\(result.stopReason) fallback=\(result.didFallback) raw_equals_transformers=\(result.raw.trimmingCharacters(in: .whitespacesAndNewlines) == referenceText)")
            #expect(result.raw.trimmingCharacters(in: .whitespacesAndNewlines) == referenceText, "\(testCase.name): \(result.raw)")
            // The long case repeats one sentence six times; the model keeps it once, which is under the
            // card's 0.4 word-ratio floor, so the guard correctly returns the transcript.
            #expect(result.didFallback == (testCase.name == "long_sliding"), "\(testCase.name) fallback")
        }
    }

    private struct ReferenceCaseWithText: Decodable {
        let text: String
        let decoded: String
    }

    // MARK: - Managed install path

    @Test func phononReleaseInstallsThroughTheManagedPath() async throws {
        guard let root = Self.environment["MUESLI_PHONON_INSTALL_ROOT"] else { return }
        let slot = try #require(CleanupModelSlot.slot(id: CleanupModelSlot.phononRefinerID))
        let release = slot.bundled
        let live = URL(fileURLWithPath: root).appendingPathComponent("postproc-\(slot.id)")
        let staging = try CleanupModelInstallation.prepareStaging(for: release, liveDirectory: live, installed: nil)
        try await ModelDownloadCoordinator.shared.download(release.artifact.manifest(id: slot.id), to: staging) { _ in }
        try CleanupModelInstallation.commit(release, staging: staging, liveDirectory: live)

        let installed = try #require(CleanupModelInstallation.installedRelease(for: slot, in: live))
        #expect(installed == release)
        // Every pinned file is on disk with its pinned size, and loads through the production engine.
        try release.artifact.validate(modelURL: live.appendingPathComponent(release.artifact.modelFilename))
        let engine = try await CleanupMLXEvaluation(directory: live, descriptor: release.artifact, model: .phonon)
        let result = try await engine.process(
            "um so we should ship the muesli build to the the testers on tuesday actually no thursday", context: nil,
            writing: .init(bundleID: "com.apple.Notes", vocabulary: ["Muesli"]))
        print("PHONON INSTALL output=\(String(reflecting: result.output)) fallback=\(result.didFallback) stop=\(result.stopReason)")
        #expect(!result.didFallback)
        #expect(result.output.contains("Muesli"))
        // A damaged file is refused.
        let tokenizer = live.appendingPathComponent("tokenizer_config.json")
        try Data("{}".utf8).write(to: tokenizer)
        #expect(throws: (any Error).self) { try release.artifact.validate(modelURL: live.appendingPathComponent("model.safetensors")) }
    }

    // MARK: - Quality and latency against Pro Cleanup (Qwen 3.5)

    private struct EvalRow: Decodable {
        let id: String
        let app_name: String
        let bundle_id: String
        let url: String?
        let vocabulary: [String]
        let raw: String
        let reference: String
    }

    private struct EvalOutput: Encodable {
        let id: String
        let model: String
        let output: String
        /// `output` after the dictionary pass every cleanup model gets in the app.
        let final: String
        let raw_output: String
        let fallback: Bool
        let seconds: Double
    }

    @Test func phononAndProQwenOnTheSameSet() async throws {
        guard #available(macOS 15, *),
              let setPath = Self.environment["MUESLI_CLEANUP_EVAL_SET"],
              let outPath = Self.environment["MUESLI_CLEANUP_EVAL_OUT"],
              let phononDirectory = Self.environment["MUESLI_PHONON_MODEL_DIR"],
              let qwenDirectory = Self.environment["MUESLI_PROQWEN_MODEL_DIR"] else { return }
        let rows = try String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(EvalRow.self, from: Data($0.utf8)) }
        try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let candidates: [(String, PostProcessorOption, String)] = [
            ("phonon_refiner", .phononRefiner, phononDirectory),
            ("pro_qwen_v14", .qwenV12, qwenDirectory),
        ]
        for (name, option, directory) in candidates {
            let modelURL = URL(fileURLWithPath: directory).appendingPathComponent("model.safetensors")
            let processor = Qwen3PostProcessor(modelURL: modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let configuration = Qwen3PostProcessor.Configuration(modelURL: modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let loadStart = Date()
            try await processor.prepare()
            print("EVAL \(name) load_and_prime_seconds=\(Date().timeIntervalSince(loadStart))")
            _ = try await processor.process("Hello world.", configuration: configuration)
            var lines: [String] = []
            var seconds: [Double] = []
            for row in rows {
                // The Qwen models read the app as screen context; the refiner reads its bundle ID and dictionary.
                let appContext = "App: \(row.app_name)" + (row.url.map { " (\($0))" } ?? "")
                let writing = PhononRefinerPrompt.Context(bundleID: row.bundle_id, vocabulary: row.vocabulary)
                let start = Date()
                let result = try await processor.processResult(row.raw, appContext: appContext, writing: writing, configuration: configuration)
                let elapsed = Date().timeIntervalSince(start)
                seconds.append(elapsed)
                let dictionary = row.vocabulary.map { CustomWord(word: $0, replacement: nil, matchingThreshold: 0.85) }
                let final = CustomWordMatcher.apply(text: result.text, customWords: dictionary)
                let output = EvalOutput(id: row.id, model: name, output: result.text, final: final, raw_output: result.rawOutput,
                                        fallback: result.didFallback, seconds: elapsed)
                lines.append(String(decoding: try encoder.encode(output), as: UTF8.self))
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: outPath + "/\(name).jsonl", atomically: true, encoding: .utf8)
            let first20 = Array(seconds.prefix(20)).sorted()
            let median20 = (first20[first20.count / 2 - 1] + first20[first20.count / 2]) / 2
            let all = seconds.sorted()
            print("EVAL \(name) rows=\(rows.count) median_seconds_first20=\(median20) median_seconds_all=\(all[all.count / 2]) p90_seconds_all=\(all[Int(Double(all.count) * 0.9)]) max_seconds=\(all.last ?? 0)")
            await processor.shutdown()
        }
    }

    // MARK: - Key-up to cleaned text

    /// Time from a finished recording to cleaned text: Parakeet Unified on the WAV, then the cleanup model.
    /// The recorder's tail, the paste and the dictionary pass are outside it. `MUESLI_LATENCY_AUDIO_DIR`
    /// holds one `<row id>.wav` (16 kHz mono) per row of the eval set; the first two rows warm both engines
    /// and the next twenty are measured.
    @Test func keyUpToCleanedTextLatency() async throws {
        guard #available(macOS 15, *),
              let audioPath = Self.environment["MUESLI_LATENCY_AUDIO_DIR"],
              let setPath = Self.environment["MUESLI_CLEANUP_EVAL_SET"],
              let outPath = Self.environment["MUESLI_CLEANUP_EVAL_OUT"],
              let phononDirectory = Self.environment["MUESLI_PHONON_MODEL_DIR"],
              let qwenDirectory = Self.environment["MUESLI_PROQWEN_MODEL_DIR"] else { return }
        let rows = try String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(EvalRow.self, from: Data($0.utf8)) }
            .filter { FileManager.default.fileExists(atPath: audioPath + "/\($0.id).wav") }
        try #require(rows.count >= 22)
        let backend = BackendOption.parakeetUnified
        let coordinator = TranscriptionCoordinator()
        try await coordinator.preloadRequired(backend: backend, enablePostProcessor: false, includeMeetingHelpers: false)
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        var report: [String: [String: Double]] = [:]
        let candidates: [(String, PostProcessorOption, String)] = [
            ("phonon_refiner", .phononRefiner, phononDirectory),
            ("pro_qwen_v14", .qwenV12, qwenDirectory),
        ]
        for (name, option, directory) in candidates {
            let modelURL = URL(fileURLWithPath: directory).appendingPathComponent("model.safetensors")
            let processor = Qwen3PostProcessor(modelURL: modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let configuration = Qwen3PostProcessor.Configuration(modelURL: modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            try await processor.prepare()
            var totals: [Double] = [], asr: [Double] = [], cleanup: [Double] = []
            for (index, row) in rows.prefix(22).enumerated() {
                let wav = URL(fileURLWithPath: audioPath + "/\(row.id).wav")
                let appContext = "App: \(row.app_name)" + (row.url.map { " (\($0))" } ?? "")
                let writing = PhononRefinerPrompt.Context(bundleID: row.bundle_id, vocabulary: row.vocabulary)
                let start = ProcessInfo.processInfo.systemUptime
                let transcript = try await coordinator.transcribeDictation(
                    at: wav, backend: backend, enablePostProcessor: false, customWords: [], appContext: nil)
                let asrDone = ProcessInfo.processInfo.systemUptime
                _ = try await processor.processResult(transcript.text, appContext: appContext, writing: writing, configuration: configuration)
                let done = ProcessInfo.processInfo.systemUptime
                guard index >= 2 else { continue }
                totals.append(done - start)
                asr.append(asrDone - start)
                cleanup.append(done - asrDone)
            }
            report[name] = ["dictations": Double(totals.count), "median_total": median(totals), "median_asr": median(asr),
                            "median_cleanup": median(cleanup), "max_total": totals.max() ?? 0, "min_total": totals.min() ?? 0]
            print("LATENCY \(name) \(report[name]!.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " "))")
            await processor.shutdown()
        }
        try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outPath + "/latency.json"))
    }
}
