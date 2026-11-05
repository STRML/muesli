# Clean up while the dictation key is held

Setting: Settings, Dictations, "Clean up while the dictation key is held" (`enable_incremental_hold_to_talk`). Off by default.
Design issue: https://github.com/STRML/muesli/issues/46

Hold-to-talk records the whole clip, transcribes it, then cleans it up, so the wait after key-up grows with the length of the dictation. With this setting on, Muesli cleans up most of the text while you are still talking, and at key-up it cleans only the last few seconds.

```
today
 key down ───── record ───── key up ─▶ ASR(all) ─▶ cleanup(all) ─▶ paste
                                       └──────── grows with length ───┘

with the setting
 key down ── record ──────────────────── key up ─▶ ASR(all) ─▶ cleanup(tail) ─▶ paste
             │ every 0.4 s or slower: ASR(audio so far)         └─ roughly constant ─┘
             │ sentences that stopped changing ─▶ cleanup once, keep
```

The final recognition at key-up is still a full pass over the recording, as today. What the setting saves is the cleanup of everything except the tail, so it helps most on dictations of about 30 seconds and longer.

## When it runs

All of these must hold at key-down. Otherwise the dictation uses today's path and nothing else changes.

| Condition | Why |
|---|---|
| Setting on | Opt-in |
| 16 GB of memory or more | Recognition and cleanup run at the same time |
| Hold-to-talk with a local model | Hands-free, hosted and streaming dictation are untouched |
| Recognizer: Parakeet Unified | The only recognizer measured; its snapshot decode is the same call as its file decode |
| Cleanup: on, on-device, S1-mini | The only cleanup model measured |
| Paste output, screen context off, not a test dictation | Screen context arrives after recording starts, so a background chunk could see a different prompt |

`IncrementalDictationPolicy` in `IncrementalDictation.swift` is the single place that decides this. Widening it to another model means measuring that model first.

## What happens

1. While the key is held, `IncrementalDictationSession` re-transcribes the audio so far, starting once 12 seconds exist and about every 0.4 s, stretched so recognition is busy at most a third of the time. A sentence is stable once it stays unchanged for 3 passes and more than 12 words follow it. Stable sentences wait until at least 40 words are ready, then are cleaned once, as a chunk.
2. At key-up the controller runs today's final recognition on the recorded WAV, unchanged. `session.resolve` then compares the committed chunks with the start of that final transcript.
3. A chunk matches when its words equal the words at the same place in the final transcript, ignoring case and punctuation. Whole-recording passes often punctuate a sentence end differently from one pass to the next while recognizing the same words, and cleanup rewrites punctuation anyway.
4. If every chunk matches, only the tail is cleaned and joined to the cleaned prefix. Custom words and the layout-preserving artifact filter run once, on the joined text.
5. Otherwise the dictation runs today's `finalizeDictationTranscript` on the final transcript.

Background results are never pasted. They only reach the output through `resolve`.

## Falls back to today's path when

| Situation | Reason code |
|---|---|
| Clip under 2 s | `short_clip` |
| No chunk reached the stable bar (dictations under about 15 s) | `nothing_committed` |
| A finished chunk's words differ from the final transcript | `prefix_mismatch` |
| A chunk still being cleaned no longer matches | the chunk is dropped; earlier chunks stand |
| A background recognition pass failed, or the model was unloaded | `pass_failed` |
| A committed word changed between passes | `diverged` |
| "Scratch that" or similar said as a command, a spoken list or layout command, or a correction opener at the start of the tail | `refer_back_cue` |
| Recognizer or cleanup configuration differs between key-down and key-up | `configuration_changed` |
| The live audio does not match the recorded WAV sample for sample | `coverage_mismatch` |
| Escape, a meeting taking over, or a recorder failure | `cancelled` (nothing is pasted, as today) |

A chunk whose cleanup fails or is rejected keeps its recognized text with filler words removed, exactly as today's path does for a whole dictation.

## Known differences from today's text

The cleanup model reads each chunk on its own, so what it writes for a chunk can differ from what it would write for the same words inside the whole dictation. In the measurements in the pull request the recognized words were identical on every dictation and the differences were:

- Paragraph breaks: where S1-mini starts a new paragraph depends on how much text it sees.
- A comma or a period at a sentence join.
- Number and date styling, such as "March 14" and "March 14th", or "stand-up" and "standup".

Today's path is deterministic, so the same recording always gives the same text there. The setting trades that for a shorter wait after key-up.

## Debugging

Each dictation adds `incremental_reuse` or `incremental_fallback:<reason>` to the dictation latency trace, with the number of chunks reused and how many were punctuated differently in the final recognition. A run of `coverage_mismatch` entries means the live audio and the recording disagree about sample counts, and the setting is doing nothing.
