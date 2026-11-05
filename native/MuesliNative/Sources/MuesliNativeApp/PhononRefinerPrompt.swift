import Foundation

/// Prompt contract for the Phonon refiner 1.7B (https://huggingface.co/Infatoshi/phonon-refiner-1.7b),
/// a LoRA fine-tune of LiquidAI LFM3-1.7B under the LFM Open License v1.0.
///
/// The model was trained on a system prompt, one writing-mode line picked from the app the text
/// is going to, an optional vocabulary line, and a user turn holding the bare transcript. Those
/// strings are the model card's documented contract; no code from the Phonon app (GPL-3.0) is used.
/// Qwen and LFM 2.5 cleanup models were trained without mode or vocabulary lines and keep
/// `MuesliCleanupV2Prompt`.
enum PhononRefinerPrompt {
    static let systemPrompt = "Rewrite the raw dictation transcript into the exact text the speaker intended. Fix recognition errors and technical terms, keep the speaker's wording and casing style, do not add or drop content."

    /// The most dictionary terms sent. The card says Phonon sends 30 to 80, most confident first.
    static let vocabularyLimit = 80
    /// Longer entries are phrases or pasted text, not terms the speaker would say.
    static let vocabularyTermCharacterLimit = 64

    // MARK: - Writing modes

    enum WritingMode: CaseIterable {
        case casual, formal, prompt, minimal

        var line: String {
            switch self {
            case .casual: "Writing mode: casual (a chat message)."
            case .formal: "Writing mode: formal (an email or document)."
            case .prompt: "Writing mode: prompt (an instruction to an AI assistant)."
            case .minimal: "Writing mode: minimal (notes and documents)."
            }
        }
    }

    /// Native apps by bundle ID. One table for every mode; `minimal` is the fallback, not a row.
    static let modeByBundleID: [String: WritingMode] = {
        let rows: [(WritingMode, [String])] = [
            (.casual, [
                "com.hnc.Discord", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
                "ru.keepcoder.Telegram", "org.telegram.desktop", "maccatalyst.com.atebits.Tweetie2",
            ]),
            (.formal, [
                "com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron",
                "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams",
            ]),
            (.prompt, [
                "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
                // Terminals
                "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                "org.alacritty", "net.kovidgoyal.kitty", "com.cmuxterm.app",
                // Code editors
                "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
                "dev.zed.Zed", "com.apple.dt.Xcode", "com.exafunction.windsurf", "com.sublimetext.4",
                "com.panic.Nova",
            ]),
        ]
        return Dictionary(uniqueKeysWithValues: rows.flatMap { mode, ids in ids.map { ($0.lowercased(), mode) } })
    }()

    /// Bundle ID prefixes for families of apps (every JetBrains IDE is a code editor).
    static let modeByBundleIDPrefix: [(prefix: String, mode: WritingMode)] = [
        ("com.jetbrains.", .prompt),
    ]

    /// Web apps by host. A host matches itself and its subdomains.
    static let modeByHost: [String: WritingMode] = {
        let rows: [(WritingMode, [String])] = [
            (.casual, ["discord.com", "web.whatsapp.com", "web.telegram.org", "x.com", "twitter.com"]),
            (.formal, [
                "mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com",
                "mail.superhuman.com", "slack.com", "teams.microsoft.com", "teams.live.com", "chat.google.com",
            ]),
            (.prompt, ["chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com"]),
        ]
        return Dictionary(uniqueKeysWithValues: rows.flatMap { mode, hosts in hosts.map { ($0, mode) } })
    }()

    /// The mode for the app the text is going to. Browsers are resolved from the page host when
    /// screen context supplied a URL; an unknown app, a browser without a URL, or an unknown site
    /// is `minimal`.
    static func mode(bundleID: String?, url: String?) -> WritingMode {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !bundleID.isEmpty else {
            return .minimal
        }
        if DictationContextCapture.browserBundleIDs.contains(where: { $0.lowercased() == bundleID }) {
            return host(of: url).flatMap(mode(forHost:)) ?? .minimal
        }
        if let mode = modeByBundleID[bundleID] { return mode }
        return modeByBundleIDPrefix.first { bundleID.hasPrefix($0.prefix) }?.mode ?? .minimal
    }

    private static func mode(forHost host: String) -> WritingMode? {
        var candidate = Substring(host)
        while true {
            if let mode = modeByHost[String(candidate)] { return mode }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    private static func host(of url: String?) -> String? {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// The page URL that `DictationContextCapture.formatForPrompt` appends to its `App:` line.
    static func url(inAppContext appContext: String?) -> String? {
        guard let appContext else { return nil }
        for line in appContext.components(separatedBy: "\n") where line.hasPrefix("App:") {
            guard let range = line.range(of: #" \(([A-Za-z][A-Za-z0-9+.-]*://.*)\)$"#, options: .regularExpression) else { return nil }
            return String(line[range].dropFirst(2).dropLast())
        }
        return nil
    }

    // MARK: - Vocabulary

    /// Terms the speaker may use, from the dictionary's `custom_words` entries. A replacement is
    /// the spelling the user wants in the output, so it wins over the word it replaces. Order is
    /// kept (the card wants the most confident first), duplicates and anything that cannot be a
    /// single term are dropped, and whitespace is collapsed so a term can never add a prompt line.
    static func vocabulary(from customWords: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for entry in customWords {
            let replacement = (entry["replacement"] as? String).flatMap(singleLine)
            guard let term = replacement ?? (entry["word"] as? String).flatMap(singleLine),
                  term.count <= vocabularyTermCharacterLimit,
                  !term.contains(","),
                  seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == vocabularyLimit { break }
        }
        return terms
    }

    private static func singleLine(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func vocabularyLine(_ terms: [String]) -> String? {
        let capped = terms.prefix(vocabularyLimit)
        return capped.isEmpty ? nil : "Vocabulary the speaker may use: " + capped.joined(separator: ", ")
    }

    // MARK: - Request

    /// What the app knows about where the text is going and what the speaker's dictionary holds.
    struct Context: Sendable, Equatable {
        var bundleID: String?
        var vocabulary: [String] = []
        static let none = Context()
    }

    static func system(mode: WritingMode, vocabulary: [String]) -> String {
        ([systemPrompt, mode.line] + [vocabularyLine(vocabulary)].compactMap { $0 }).joined(separator: "\n")
    }

    /// The base chat template, thinking off, as the card documents: BOS, a system turn, the bare
    /// transcript as the user turn, then an assistant turn that opens with an empty think block.
    static func request(_ text: String, appContext: String?, context: Context) -> String {
        let mode = mode(bundleID: context.bundleID, url: url(inAppContext: appContext))
        return "<|startoftext|><|im_start|>system\n" + system(mode: mode, vocabulary: context.vocabulary)
            + "<|im_end|>\n<|im_start|>user\n" + text
            + "<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    // MARK: - Output

    /// The card caps generation at 1.5 x the input's tokens + 32.
    static func outputTokenCap(inputTokens: Int) -> Int {
        Int(1.5 * Double(inputTokens)) + 32
    }

    /// The shared cleanup guard plus the card's word-count checks: more than twice the input's
    /// words, or (past 8 words) fewer than 0.4 of them, falls back to the raw transcript.
    static func guardResult(_ output: String, input: String, generationCompleted: Bool = true) -> MuesliCleanupV2Prompt.GuardedOutput {
        let guarded = MuesliCleanupV2Prompt.guardResult(output, input: input, generationCompleted: generationCompleted)
        guard !guarded.didFallback else { return guarded }
        let inputWords = input.split(whereSeparator: \.isWhitespace).count
        let outputWords = guarded.text.split(whereSeparator: \.isWhitespace).count
        let tooLong = Double(outputWords) > 2 * Double(inputWords)
        let tooShort = inputWords > 8 && Double(outputWords) < 0.4 * Double(inputWords)
        return tooLong || tooShort ? .init(text: input, didFallback: true) : guarded
    }
}
