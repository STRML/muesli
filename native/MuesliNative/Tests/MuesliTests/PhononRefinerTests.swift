import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import MuesliNativeApp

/// Phonon refiner 1.7B: prompt contract, writing-mode lookup, vocabulary line, managed release pin
/// and the LFM3 model definition. The prompt goldens were rendered with the model's own
/// `chat_template.jinja` (enable_thinking false) through `transformers`.
@Suite
struct PhononRefinerTests {
    private static let base = "Rewrite the raw dictation transcript into the exact text the speaker intended. Fix recognition errors and technical terms, keep the speaker's wording and casing style, do not add or drop content."

    // MARK: - Writing mode lookup

    typealias Mode = PhononRefinerPrompt.WritingMode

    struct NativeApp: Sendable, CustomTestStringConvertible {
        let name: String
        let bundleID: String
        let mode: Mode
        var testDescription: String { name }
    }

    // Read from the apps installed on the development Mac (Info.plist): Discord, Messages, WhatsApp, Telegram,
    // Mail, Outlook, Slack, Teams, Claude, Terminal, iTerm, VS Code, Xcode, and com.openai.codex (the app named
    // ChatGPT.app there). Not verified against an install: Superhuman, ChatGPT (com.openai.chat), Ghostty,
    // Cursor, IntelliJ, and the Tweetie2 and web-wrapper IDs in the table; they come from the vendors' public IDs.
    static let nativeApps: [NativeApp] = [
        NativeApp(name: "Discord", bundleID: "com.hnc.Discord", mode: .casual),
        NativeApp(name: "Messages", bundleID: "com.apple.MobileSMS", mode: .casual),
        NativeApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", mode: .casual),
        NativeApp(name: "Telegram", bundleID: "ru.keepcoder.Telegram", mode: .casual),
        NativeApp(name: "Mail", bundleID: "com.apple.mail", mode: .formal),
        NativeApp(name: "Outlook", bundleID: "com.microsoft.Outlook", mode: .formal),
        NativeApp(name: "Superhuman", bundleID: "com.superhuman.electron", mode: .formal),
        NativeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", mode: .formal),
        NativeApp(name: "Teams", bundleID: "com.microsoft.teams2", mode: .formal),
        NativeApp(name: "ChatGPT", bundleID: "com.openai.chat", mode: .prompt),
        NativeApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop", mode: .prompt),
        NativeApp(name: "Codex", bundleID: "com.openai.codex", mode: .prompt),
        NativeApp(name: "Terminal", bundleID: "com.apple.Terminal", mode: .prompt),
        NativeApp(name: "iTerm", bundleID: "com.googlecode.iterm2", mode: .prompt),
        NativeApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty", mode: .prompt),
        NativeApp(name: "VS Code", bundleID: "com.microsoft.VSCode", mode: .prompt),
        NativeApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", mode: .prompt),
        NativeApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", mode: .prompt),
        NativeApp(name: "IntelliJ", bundleID: "com.jetbrains.intellij", mode: .prompt),
    ]

    @Test(arguments: nativeApps)
    func nativeAppPicksItsMode(app: NativeApp) {
        #expect(PhononRefinerPrompt.mode(bundleID: app.bundleID, url: nil) == app.mode)
        // The bundle ID is matched without regard to case.
        #expect(PhononRefinerPrompt.mode(bundleID: app.bundleID.uppercased(), url: nil) == app.mode)
    }

    @Test func unknownAndMissingBundlesAreMinimal() {
        #expect(PhononRefinerPrompt.mode(bundleID: "com.apple.Notes", url: nil) == .minimal)
        #expect(PhononRefinerPrompt.mode(bundleID: "", url: nil) == .minimal)
        #expect(PhononRefinerPrompt.mode(bundleID: nil, url: nil) == .minimal)
        // A URL never reclassifies a native app.
        #expect(PhononRefinerPrompt.mode(bundleID: "com.apple.Notes", url: "https://discord.com/channels/1") == .minimal)
    }

    struct Site: Sendable, CustomTestStringConvertible {
        let url: String
        let mode: Mode
        var testDescription: String { url }
    }

    static let sites: [Site] = [
        Site(url: "https://discord.com/channels/1/2", mode: .casual),
        Site(url: "https://web.whatsapp.com/", mode: .casual),
        Site(url: "https://x.com/home", mode: .casual),
        Site(url: "https://twitter.com/home", mode: .casual),
        Site(url: "https://mail.google.com/mail/u/0/#inbox", mode: .formal),
        Site(url: "https://outlook.office.com/mail/", mode: .formal),
        Site(url: "https://mail.superhuman.com/", mode: .formal),
        Site(url: "https://acme.slack.com/", mode: .formal),
        Site(url: "https://app.slack.com/client/T1/C2", mode: .formal),
        Site(url: "https://teams.microsoft.com/v2/", mode: .formal),
        Site(url: "https://chat.google.com/room/abc", mode: .formal),
        Site(url: "https://chatgpt.com/c/123", mode: .prompt),
        Site(url: "https://claude.ai/new", mode: .prompt),
        Site(url: "https://gemini.google.com/app", mode: .prompt),
        Site(url: "https://example.com/", mode: .minimal),
        // A host is matched by its labels, never by a substring of another site's name.
        Site(url: "https://notchatgpt.com/", mode: .minimal),
        Site(url: "https://x.com.evil.example/", mode: .minimal),
    ]

    @Test(arguments: sites)
    func browserPicksModeFromThePageHost(site: Site) {
        #expect(PhononRefinerPrompt.mode(bundleID: "com.google.Chrome", url: site.url) == site.mode)
        #expect(PhononRefinerPrompt.mode(bundleID: "com.apple.Safari", url: site.url) == site.mode)
    }

    @Test func browserWithoutAUsableURLIsMinimal() {
        #expect(PhononRefinerPrompt.mode(bundleID: "com.google.Chrome", url: nil) == .minimal)
        #expect(PhononRefinerPrompt.mode(bundleID: "com.google.Chrome", url: "not a url") == .minimal)
        #expect(PhononRefinerPrompt.mode(bundleID: "company.thebrowser.Browser", url: "") == .minimal)
    }

    @Test func pageURLIsReadFromThePromptContext() {
        let chrome = DictationContextCapture.formatForPrompt(DictationContext(
            appName: "Google Chrome", bundleID: "com.google.Chrome", documentContext: "hello", selectedText: "",
            url: "https://claude.ai/new", documentIdentifier: nil, ocrText: ""))
        #expect(PhononRefinerPrompt.url(inAppContext: chrome) == "https://claude.ai/new")
        #expect(PhononRefinerPrompt.url(inAppContext: "App: Notes") == nil)
        #expect(PhononRefinerPrompt.url(inAppContext: nil) == nil)
        // A URL inside the document text is not the page.
        #expect(PhononRefinerPrompt.url(inAppContext: "App: Notes\nDocument context: see (https://claude.ai/x)") == nil)
    }

    @Test func everyModeHasItsDocumentedLine() {
        #expect(Mode.casual.line == "Writing mode: casual (a chat message).")
        #expect(Mode.formal.line == "Writing mode: formal (an email or document).")
        #expect(Mode.prompt.line == "Writing mode: prompt (an instruction to an AI assistant).")
        #expect(Mode.minimal.line == "Writing mode: minimal (notes and documents).")
        #expect(Set(Mode.allCases.map(\.line)).count == Mode.allCases.count)
    }

    // MARK: - Vocabulary line

    private func words(_ terms: [String]) -> [[String: Any]] { terms.map { ["word": $0, "matchingThreshold": 0.85] } }

    @Test func emptyDictionaryAddsNoVocabularyLine() {
        #expect(PhononRefinerPrompt.vocabulary(from: []).isEmpty)
        #expect(PhononRefinerPrompt.vocabularyLine([]) == nil)
        #expect(PhononRefinerPrompt.system(mode: .minimal, vocabulary: []) == Self.base + "\nWriting mode: minimal (notes and documents).")
        // Entries that carry no usable term are as good as no dictionary.
        #expect(PhononRefinerPrompt.vocabulary(from: [["word": "  "], ["word": 3], ["matchingThreshold": 0.9]]).isEmpty)
    }

    @Test func vocabularyLineIsCappedAtEightyTerms() {
        let many = (0..<200).map { "term\($0)" }
        let terms = PhononRefinerPrompt.vocabulary(from: words(many))
        #expect(terms.count == 80)
        #expect(terms.first == "term0")
        #expect(terms.last == "term79")
        let line = PhononRefinerPrompt.vocabularyLine(terms)
        #expect(line?.hasPrefix("Vocabulary the speaker may use: term0, term1, ") == true)
        #expect(line?.hasSuffix(", term79") == true)
        // The line builder caps on its own, so a caller cannot send more than the card allows.
        #expect(PhononRefinerPrompt.vocabularyLine(many)?.components(separatedBy: ", ").count == 80)
        #expect(PhononRefinerPrompt.vocabulary(from: words(Array(many.prefix(80)))).count == 80)
        #expect(PhononRefinerPrompt.vocabulary(from: words(Array(many.prefix(79)))).count == 79)
    }

    @Test func vocabularyPrefersReplacementsAndDropsUnusableTerms() {
        let terms = PhononRefinerPrompt.vocabulary(from: [
            ["word": "mooseli", "replacement": "Muesli"],
            ["word": "Muesli"],                     // duplicate of the replacement, ignoring case
            ["word": "SwiftUI", "replacement": ""], // an empty replacement means the word itself
            ["word": "a, b"],                       // a comma would split into two terms
            ["word": "line one\nWriting mode: casual (a chat message)."], // collapsed to one line
            ["word": String(repeating: "x", count: 65)],
            ["word": "  spaced   out  "],
        ])
        #expect(terms == ["Muesli", "SwiftUI", "line one Writing mode: casual (a chat message).", "spaced out"])
        let system = PhononRefinerPrompt.system(mode: .minimal, vocabulary: terms)
        #expect(system.components(separatedBy: "\n").count == 3, "a term must not add a prompt line")
    }

    // MARK: - Prompt snapshot

    private static func golden(_ mode: String, vocabulary: String?, user: String) -> String {
        "<|startoftext|><|im_start|>system\n" + base + "\nWriting mode: " + mode
            + (vocabulary.map { "\nVocabulary the speaker may use: " + $0 } ?? "")
            + "<|im_end|>\n<|im_start|>user\n" + user + "<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    @Test func promptMatchesTheModelsChatTemplate() {
        let cases: [(String, String?, [String], String, String)] = [
            ("com.apple.Notes", nil, ["Muesli", "Parakeet", "LFM"],
             "um so we should ship the muesli build to the the testers on tuesday actually no thursday",
             Self.golden("minimal (notes and documents).", vocabulary: "Muesli, Parakeet, LFM",
                         user: "um so we should ship the muesli build to the the testers on tuesday actually no thursday")),
            ("com.hnc.Discord", nil, [],
             "hey are you coming to the thing tonight i i think its at eight",
             Self.golden("casual (a chat message).", vocabulary: nil,
                         user: "hey are you coming to the thing tonight i i think its at eight")),
            ("com.apple.mail", nil, ["Phonon", "Acme Corp"],
             "hi sam thanks for the update on the acme corp contract i will review it by friday best regards jordan",
             Self.golden("formal (an email or document).", vocabulary: "Phonon, Acme Corp",
                         user: "hi sam thanks for the update on the acme corp contract i will review it by friday best regards jordan")),
            ("com.google.Chrome", "App: Google Chrome (https://claude.ai/new)", ["SwiftUI", "mlx-swift-lm"],
             "add a swift ui view that shows the the model download progress using mlx swift lm and dont change the existing tests",
             Self.golden("prompt (an instruction to an AI assistant).", vocabulary: "SwiftUI, mlx-swift-lm",
                         user: "add a swift ui view that shows the the model download progress using mlx swift lm and dont change the existing tests")),
        ]
        for (bundle, appContext, vocabulary, text, expected) in cases {
            let context = PhononRefinerPrompt.Context(bundleID: bundle, vocabulary: vocabulary)
            #expect(PhononRefinerPrompt.request(text, appContext: appContext, context: context) == expected, "\(bundle)")
            #expect(CleanupMLXEvaluation.Model.phonon.prompt(text, context: appContext, writing: context) == expected, "\(bundle)")
        }
    }

    @Test func userTurnIsTheBareTranscriptWithNoAppContext() {
        let prompt = PhononRefinerPrompt.request("hello there", appContext: "App: Notes\nOCR screen text: secret",
                                                 context: .init(bundleID: "com.apple.Notes", vocabulary: []))
        #expect(!prompt.contains("secret"))
        #expect(!prompt.contains("APP-CONTEXT"))
        #expect(prompt.contains("<|im_start|>user\nhello there<|im_end|>"))
    }

    // MARK: - Output guard

    @Test func guardKeepsAGoodRewrite() {
        let input = "um so we should ship the muesli build to the the testers on tuesday actually no thursday"
        let guarded = PhononRefinerPrompt.guardResult("We should ship the Muesli build to the testers on Thursday.", input: input)
        #expect(!guarded.didFallback)
        #expect(guarded.text == "We should ship the Muesli build to the testers on Thursday.")
    }

    @Test func guardFallsBackToTheTranscript() {
        let input = "add a swift ui view that shows the the model download progress using mlx swift lm"
        // Cut off by the token cap.
        #expect(PhononRefinerPrompt.guardResult("Add a SwiftUI view", input: input, generationCompleted: false).text == input)
        // Empty or placeholder output.
        #expect(PhononRefinerPrompt.guardResult("  ", input: input).text == input)
        // More than twice the input's words.
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(PhononRefinerPrompt.guardResult(long, input: "one two three four five", generationCompleted: true).didFallback)
        // Past 8 words, fewer than 0.4 of them.
        #expect(PhononRefinerPrompt.guardResult("Add a view.", input: input).didFallback)
        // A short input may shrink freely.
        #expect(!PhononRefinerPrompt.guardResult("Hello.", input: "um hello").didFallback)
    }

    @Test func outputTokenCapIsOneAndAHalfTimesTheInputPlus32() {
        #expect(PhononRefinerPrompt.outputTokenCap(inputTokens: 0) == 32)
        #expect(PhononRefinerPrompt.outputTokenCap(inputTokens: 100) == 182)
        #expect(PhononRefinerPrompt.outputTokenCap(inputTokens: 21) == 63)
    }

    // MARK: - Managed release and catalog

    private static let expectedFiles: [(String, Int64, String)] = [
        ("model.safetensors", 1_133_072_561, "f6f5d376c422affe15b211a65d38132088712865a7ce6e044e11b150cd8a4bb2"),
        ("LICENSE", 10_574, "4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c"),
        ("NOTICE", 1293, "6e22035f2acf0564af88c389402bcda046a0ba5f6bfa46074b56741cd8df4d60"),
        ("chat_template.jinja", 12_129, "f45005c50cd2a97329722bf3a2dee9f16c04cdf825a589b280fb7e99e6827818"),
        ("config.json", 28_490, "82959de49f43ef3a185a82fa093caf4f91c2b62ad19a11d6043df7987af4bf38"),
        ("generation_config.json", 328, "bfe4a6d7d5fd2218845f716157632fff5b7b137628055a69871e41026c0750b5"),
        ("model.safetensors.index.json", 41_831, "a6b6a42bb621feacd690f99b658fc29ccbe771d61c2a8f28c936ab93c3fd203e"),
        ("tokenizer.json", 17_908_634, "41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44"),
        ("tokenizer_config.json", 1896, "236f21425c08d31bfa5062767da6a3f1354ca0b89ac4138cfa9bdbb47a6700b2"),
    ]

    @Test func bundledReleasePinsTheVerifiedRevisionAndFiles() throws {
        let slot = try #require(CleanupModelSlot.slot(id: CleanupModelSlot.phononRefinerID))
        let release = slot.bundled
        #expect(release.repo == "Infatoshi/phonon-refiner-1.7b")
        #expect(release.revision == "2b0ab74bee7ab7cf364695bbe44f64ce4c47439e")
        #expect(release.runtime == .mlxLFM3 && slot.runtime == .mlxLFM3)
        #expect(release.files.map(\.path) == Self.expectedFiles.map(\.0))
        #expect(release.files.map(\.size) == Self.expectedFiles.map(\.1))
        #expect(release.files.map(\.sha256) == Self.expectedFiles.map(\.2))
        // The GGUF and the DFlash2 drafter only run on Phonon's own engine.
        #expect(!release.files.contains { $0.path.hasSuffix(".gguf") })
        #expect(release.validationFailure(for: slot, appVersion: "1.0.0") == nil)
        for file in release.artifact.files {
            #expect(file.remoteURL.absoluteString == "https://huggingface.co/Infatoshi/phonon-refiner-1.7b/resolve/2b0ab74bee7ab7cf364695bbe44f64ce4c47439e/\(file.relativePath)?download=1")
        }
    }

    @Test func optionRunsThroughTheManagedCleanupPath() throws {
        let option = PostProcessorOption.phononRefiner
        #expect(PostProcessorOption.all.contains(option))
        #expect(option.cleanupSlot?.id == CleanupModelSlot.phononRefinerID)
        #expect(option.inputFormat == .phononRefiner)
        #expect(option.modelURL.lastPathComponent == "model.safetensors")
        #expect(option.modelURL.pathExtension == "safetensors")
        #expect(option.effectiveSystemPrompt(configuredSystemPrompt: "custom") == Self.base)
        #expect(option.attribution?.license == "LFM Open License v1.0")
        #expect(option.attribution?.sourceURL.absoluteString == "https://huggingface.co/Infatoshi/phonon-refiner-1.7b")
        // The other models keep their own prompts and carry no third-party attribution.
        for other in PostProcessorOption.all where other != option { #expect(other.attribution == nil) }
        #expect(Set(PostProcessorOption.all.map(\.id)).count == PostProcessorOption.all.count)
    }

    @Test func englishOnlyRefinerIsNotOfferedForBodhan() {
        for model in BackendOption.bodhanFamily {
            #expect(!PostProcessorOption.phononRefiner.isCompatible(with: model))
            #expect(!TranscriptCleanupBackendOption.local.isCompatible(with: model, inputFormat: .phononRefiner))
            #expect(TranscriptCleanupBackendOption.local.isCompatible(with: model, inputFormat: .muesliTrainedV12Qwen))
        }
        #expect(PostProcessorOption.phononRefiner.isCompatible(with: .parakeetMultilingual))
        #expect(TranscriptCleanupBackendOption.local.isCompatible(with: .parakeetMultilingual, inputFormat: .phononRefiner))
    }

    @Test func thirdPartySlotTrustsOnlyItsOwnRepository() throws {
        let phonon = try #require(CleanupModelSlot.slot(id: CleanupModelSlot.phononRefinerID))
        let lite = try #require(CleanupModelSlot.slot(id: CleanupModelSlot.liteID))
        func release(_ base: CleanupModelRelease, repo: String, revision: String? = nil) -> CleanupModelRelease {
            CleanupModelRelease(slot: base.slot, version: "v2", sequence: base.sequence + 1, runtime: base.runtime,
                repo, revision ?? base.revision, base.files.map { ($0.path, $0.size, $0.sha256) })
        }
        // A newer revision of the same repository is accepted.
        let sameRepo = release(phonon.bundled, repo: phonon.bundled.repo, revision: String(repeating: "a", count: 40))
        #expect(sameRepo.validationFailure(for: phonon, appVersion: "1.0.0") == nil)
        // Another third-party repository is not, and neither is a lookalike.
        for repo in ["Infatoshi/other-model", "Evil/phonon-refiner-1.7b", "Infatoshi/phonon-refiner-1.7b-x"] {
            #expect(release(phonon.bundled, repo: repo).validationFailure(for: phonon, appVersion: "1.0.0") != nil, "\(repo)")
        }
        // The exception is per slot: Muesli's own slots still demand Muesli-HQ.
        #expect(release(lite.bundled, repo: phonon.bundled.repo).validationFailure(for: lite, appVersion: "1.0.0") != nil)
        // A Muesli-HQ repository can still back the Phonon slot, as before for any slot.
        #expect(release(phonon.bundled, repo: "Muesli-HQ/phonon-refiner-mlx").validationFailure(for: phonon, appVersion: "1.0.0") == nil)
    }

    @Test func publishedCatalogHasThePhononEntry() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/models/cleanup-models.json")
        let document = try JSONDecoder().decode(CleanupModelCatalog.Document.self, from: Data(contentsOf: url))
        let entry = try #require(document.releases.first { $0.slot == CleanupModelSlot.phononRefinerID })
        #expect(entry == CleanupModelSlot.slot(id: CleanupModelSlot.phononRefinerID)?.bundled)
        #expect(entry.runtime.rawValue == "mlx-lfm3")
    }

    // MARK: - LFM3 model definition

    private static let configJSON = """
    {"architectures":["Lfm3ForCausalLM"],"conv_L_cache":7,"conv_bias":false,"head_dim":128,"hidden_size":2048,
     "intermediate_size":7680,"layer_types":["conv","conv","full_attention","conv","sliding_attention","conv",
     "full_attention","conv","sliding_attention","conv","full_attention","conv","sliding_attention","conv",
     "full_attention","conv","sliding_attention","conv","full_attention","conv","sliding_attention","conv",
     "full_attention","conv"],"model_type":"lfm3","norm_eps":1e-05,"num_attention_heads":16,"num_hidden_layers":24,
     "num_key_value_heads":4,"rope_parameters":{"full_attention":{"partial_rotary_factor":0.5,"rope_theta":1000000.0,
     "rope_type":"default"},"sliding_attention":{"rope_theta":10000,"rope_type":"default"}},"sliding_window":256,
     "tie_word_embeddings":true,"use_sandwich_norm":true,"vocab_size":128000,
     "quantization":{"group_size":64,"bits":4,"mode":"affine","model.embed_tokens":{"bits":8,"group_size":64}}}
    """

    @Test func lfm3ConfigurationDecodesTheCheckpointConfig() throws {
        let config = try JSONDecoder().decode(LFM3Configuration.self, from: Data(Self.configJSON.utf8))
        #expect(config.hiddenLayers == 24 && config.layerTypes.count == 24)
        #expect(config.layerTypes.filter { $0 == .conv }.count == 13)
        #expect(config.layerTypes.filter { $0 == .fullAttention }.count == 6)
        #expect(config.layerTypes.filter { $0 == .slidingAttention }.count == 5)
        #expect(config.attentionHeads == 16 && config.kvHeads == 4 && config.headDim == 128)
        #expect(config.hiddenSize == 2048 && config.intermediateSize == 7680 && config.vocabularySize == 128_000)
        #expect(config.slidingWindow == 256 && config.useSandwichNorm && config.convLCache == 7)
        #expect(config.fullAttentionRope.theta == 1_000_000 && config.fullAttentionRope.partialRotaryFactor == 0.5)
        #expect(config.slidingAttentionRope.theta == 10_000 && config.slidingAttentionRope.partialRotaryFactor == 1)
    }

    @Test func lfm3ConfigurationDefaultsMatchTheReferenceAndRejectsBadLayouts() throws {
        let minimal = try JSONDecoder().decode(LFM3Configuration.self, from: Data(#"{"model_type":"lfm3"}"#.utf8))
        // Reference default: attention every fourth layer from the third, sliding in between.
        #expect(minimal.layerTypes.prefix(8) == [.conv, .conv, .fullAttention, .conv, .slidingAttention, .conv, .fullAttention, .conv])
        #expect(minimal.headDim == 128 && minimal.slidingWindow == 256)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LFM3Configuration.self, from: Data(#"{"num_hidden_layers":3,"layer_types":["conv","conv"]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LFM3Configuration.self, from: Data(#"{"layer_types":["conv"],"num_hidden_layers":1,"rope_parameters":{"full_attention":{"rope_theta":1,"rope_type":"yarn"}}}"#.utf8))
        }
    }

    @Test func slidingMaskKeepsAtMostWindowKeysPerQuery() throws {
        guard ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"] != nil else { return }
        let metallib = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"]!
        GPU.metallib = URL(fileURLWithPath: metallib)
        // 6 queries after 4 cached tokens, window 5: query i sees keys i-4 ... i.
        guard case .array(let mask) = LFM3ModelInner.slidingMask(length: 6, offset: 4, window: 5) else {
            Issue.record("expected an array mask")
            return
        }
        #expect(mask.shape == [6, 10])
        let rows = mask.asArray(Bool.self)
        for query in 0..<6 {
            let position = 4 + query
            for key in 0..<10 {
                let visible = key <= position && position - key < 5
                #expect(rows[query * 10 + key] == visible, "query \(position) key \(key)")
            }
        }
        // Inside the window the cheap symbolic masks are used.
        if case .causal = LFM3ModelInner.slidingMask(length: 8, offset: 0, window: 256) {} else { Issue.record("expected causal") }
        if case .none = LFM3ModelInner.slidingMask(length: 1, offset: 200, window: 256) {} else { Issue.record("expected none") }
        if case .array = LFM3ModelInner.slidingMask(length: 1, offset: 256, window: 256) {} else { Issue.record("expected array") }
    }
}
