# Phonon refiner (cleanup model)

The Phonon refiner 1.7B is a fourth local cleanup model next to Cleanup Lite, Pro Cleanup (Qwen 3.5) and Pro Cleanup
(LFM 2.5). It is a LoRA fine-tune of LiquidAI LFM3-1.7B by [Infatoshi](https://huggingface.co/Infatoshi/phonon-refiner-1.7b),
the author of the Phonon voice-typing app, under the LFM Open License v1.0. Muesli takes the weights and the prompt
contract printed on the model card. It takes no code from the Phonon app (GPL-3.0).

```
today                                   after
Lite      Qwen3.5 0.8B  MLX            Lite      Qwen3.5 0.8B  MLX
Pro Qwen  Qwen3.5 2B    MLX            Pro Qwen  Qwen3.5 2B    MLX
Pro LFM   LFM2.5 1.2B   GGUF           Pro LFM   LFM2.5 1.2B   GGUF
                                     + Phonon    LFM3 1.7B     MLX  (mode + vocabulary lines)
```

## What ships

| Piece | Where |
|---|---|
| LFM3 model (mlx-swift-lm 3.32.3 has no `lfm3`) | `LFM3.swift`, registered through `LFM3Model.typeRegistry` |
| Prompt, mode table, vocabulary line, output guard | `PhononRefinerPrompt.swift` |
| Managed release: slot `phonon-refiner-1.7b`, runtime `mlx-lfm3` | `CleanupModelRelease.swift`, `docs/models/cleanup-models.json` |
| Option and model card (license and source link) | `Models.swift`, `ModelsView.swift` |
| Plumbing: frontmost app's bundle ID and dictionary reach the prompt | `TranscriptionRuntime.swift`, `Qwen3PostProcessor.swift`, `MuesliController.swift` |

The release is pinned to revision `2b0ab74bee7ab7cf364695bbe44f64ce4c47439e` and installs the nine MLX files only
(`model.safetensors`, `config.json`, `generation_config.json`, `model.safetensors.index.json`, `tokenizer.json`,
`tokenizer_config.json`, `chat_template.jinja`, `LICENSE`, `NOTICE`). The GGUF and the DFlash2 drafter in the repository
only run on Phonon's own engine. Download, size and SHA-256 checks, the staged swap and the loaded-engine reset are the
same `CleanupModelInstallation` path the other managed models use. The catalog may move this slot to a newer revision of
the same repository and nowhere else (`CleanupModelRelease.validationFailure`).

## Prompt contract

System prompt, then one writing-mode line, then an optional vocabulary line; the user turn is the bare transcript; base
chat template with thinking off; greedy decoding; no repetition penalty.

| Mode | Native apps (bundle IDs) and sites | Line |
|---|---|---|
| casual | Discord, Messages, WhatsApp, Telegram; x.com, discord.com, web.whatsapp.com | `Writing mode: casual (a chat message).` |
| formal | Mail, Outlook, Superhuman, Slack, Teams; Gmail, outlook.office.com, slack.com, chat.google.com | `Writing mode: formal (an email or document).` |
| prompt | ChatGPT, Claude, Codex, terminals, code editors (every `com.jetbrains.*` IDE); chatgpt.com, claude.ai, gemini.google.com | `Writing mode: prompt (an instruction to an AI assistant).` |
| minimal | everything else, and a browser without a recognized URL host | `Writing mode: minimal (notes and documents).` |

The vocabulary line is `Vocabulary the speaker may use: a, b, c`, at most 80 terms from the dictionary (a replacement
wins over the word it replaces; duplicates, terms containing a comma, and terms over 64 characters are dropped; whitespace
is collapsed so a term cannot add a prompt line). The model card caps generation at 1.5 x the input's tokens + 32 and
falls back to the raw transcript when the output has more than twice the input's words or, past 8 words, fewer than 0.4
of them. `PhononRefinerPrompt.guardResult` applies those two checks on top of the shared guard.

Bundle IDs were read from the installed apps for Discord, Messages, WhatsApp, Telegram, Mail, Outlook, Slack, Teams,
Claude, Terminal, iTerm, VS Code and Xcode, and `com.openai.codex` (the app named ChatGPT.app on the development Mac).
Superhuman, ChatGPT (`com.openai.chat`), Ghostty, Cursor, IntelliJ and the web hosts are the vendors' public identifiers,
not checked against an install.

## LFM3 port: parity with `transformers`

Reference: the model's own `modeling_lfm3.py` (LiquidAI/LFM3-1.7B, `trust_remote_code`, `transformers` 5.20), run on the
MLX weights dequantized to float32. `transformers` 5.20 has no `lfm3` module. Five dictations, 79 to 322 prompt tokens
(the 322-token one crosses the 256-token sliding window), prompts rendered by the model's own chat template.
Scripts and layout: [scripts/phonon-refiner-parity](../scripts/phonon-refiner-parity/README.md).

| Run (Swift side) | Steps compared | Top-1 agreement | Max abs logit diff |
|---|---|---|---|
| Shipped 4/6/8-bit weights, decode to EOS | 122 | 122 / 122, greedy tokens identical in 5 of 5 | 0.403 (0.328 to 0.403 per prompt) |
| Shipped weights, 64 steps with EOS ignored | 320 | 316 / 320 | 1.774 |
| Float32 dequantized weights, 64 steps with EOS ignored | 320 | 320 / 320, greedy tokens identical in 5 of 5 | 0.025 (0.014 to 0.025 per prompt) |
| Production path (`CleanupMLXEvaluation.process`: prompt builder, tokenizer, chunked prefill, generation, cap, guard) | 5 dictations | text equals the `transformers` decode in 5 of 5; prompt string equals the chat template render in 5 of 5; Swift token ids equal the Hugging Face ids | |

Reading the table:

- Float32 against float32 isolates the port. 0.025 is arithmetic noise, 16 times below the quantized runs.
- The quantized runs add bf16 arithmetic and 4-bit weights. `transformers` in bf16 against its own float32 gives 0.243 on
  these prompts, so 0.40 is the same order.
- The four top-1 flips in the 64-step shipped-weights run are at steps 32, 45, 47 and 17, after the EOS steps (25, 36,
  36 and 15) of their prompts, where the distribution is flat. Agreement through the end of every answer is 122 of 122.
- Falsified: disabling the sliding-window mask raises the 322-token prompt's diff from 0.34 to 1.94 and the test fails; a
  wrong RoPE (full rotation) fails the float32 gate on all five prompts (0.31 to 2.27 against 0.025). Top-1 agreement
  alone did not catch either, so the test also gates on the logit difference.

## Evaluation against Pro Cleanup (Qwen 3.5 v14)

`docs/models/eval/writing-modes-eval.jsonl`: 48 dictations, 12 per writing mode, authored for this comparison. They are
synthetic, with raw text written in a speech recognizer's style (fillers, false starts, self-corrections, misheard
terms) and an intended text per row. The references keep the speaker's contractions and were written without looking at
either model's output. This is a smoke comparison on a small self-authored set, not a quality claim.

Both models ran through the production path (`Qwen3PostProcessor.processResult`) on the same rows, release build.
Pro Qwen gets the app as screen context (its training contract); the refiner gets the bundle ID and the dictionary
terms; both outputs then go through the dictionary pass the app applies to every cleanup model.

WER after lowercasing and removing punctuation (`scripts/phonon-refiner-parity/score.py`):

| Set | Rows | Raw input | Phonon refiner | Pro Qwen v14 |
|---|---|---|---|---|
| All | 48 | 14.78% | 4.93% | 3.58% |
| casual | 12 | 21.17% | 7.30% | 6.57% |
| formal | 12 | 9.00% | 5.69% | 0.00% |
| prompt | 12 | 18.86% | 6.29% | 6.86% |
| minimal | 12 | 12.24% | 0.00% | 2.04% |
| Model output only, no dictionary pass | 48 | 14.78% | 5.22% | 4.03% |

Exact match after normalization: 36 of 48 (Phonon) and 37 of 48 (Pro Qwen) with the dictionary pass, 36 and 36 without.
No guard fallbacks for either.

Blind pairwise judge (Gemini 4 Argon High through `agy-review.sh`, each pair in both orders, a verdict counts only when
the orders agree): Phonon refiner 8, Pro Qwen 9, tie 29, order disagreement 2.

What the rows show:

- Phonon repaired terms and wrote digits where Pro Qwen did not (`ffmpeg`, `Muesli`, `10 test cases`, `12%`, `10 minutes`,
  `6:30`; Pro Qwen left four of those as words).
- Phonon resolves about half of the self-corrections, as its card says: it kept "three bullet points, no, in five" and
  "like around seven, no wait, eight" in this set. Pro Qwen resolved both.
- In formal mode Phonon expands or rephrases some wording ("I am", "It is", "has been moved", "There are no blockers"),
  which the WER scores against the references. Pro Qwen kept the speaker's wording in those rows.
- Pro Qwen added a made-up `ffmpeg` command to the dictated request "use ffmpeg to convert this mov file". Phonon kept
  the request as dictated.
- Both models turned "add type script types" into the right text, and the existing `CustomWordMatcher` then rewrote the
  last word to "TypeScript" for both. That is existing dictionary behavior, not the refiner.

## Latency

Apple M5 Max, 128 GB, macOS 27.2, release build of the test target, warm models. Key-up to cleaned text is measured from a finished
WAV: Parakeet Unified on the file, then the cleanup model, 20 dictations after two warm-ups (speech from `say`, 16 kHz
mono, 3.5 to 9.0 seconds, mean 5.4; the eval set's first 22 rows). The recorder's tail, the paste and the dictionary pass are outside it.

| Median of 20 | Phonon refiner | Pro Qwen v14 |
|---|---|---|
| Key-up to cleaned text | 0.211 s | 0.278 s |
| of which ASR | 0.087 s | 0.103 s |
| of which cleanup | 0.122 s | 0.169 s |
| Range of total | 0.129 to 1.048 s | 0.188 to 0.557 s |
| Cleanup only, eval-set text, median of the first 20 / all 48 / p90 | 0.093 / 0.097 / 0.119 s | 0.142 / 0.199 / 0.381 s |
| Load and first generation (includes SHA-256 of the files) | 4.2 s | 8.1 s |

## Not verified

- Recognizer output from real microphone speech: the latency audio is synthetic speech, and the accuracy rows are written
  text. The model card's own numbers (real dictations from one speaker, lectures) are the card's, not reproduced here.
- Machines other than the M5 Max, and the debug build's timings (parity runs used a debug build; latency used release).
- The app UI: the model card, download, pause and delete controls reuse the managed cleanup path and were not driven by
  hand. The managed install was driven by a test that downloads the pinned release into a scratch folder.
- `docs/models/cleanup-models.json` has no detached signature in this fork, so the entry takes effect for installed
  apps only if the fork publishes and signs its own catalog.
