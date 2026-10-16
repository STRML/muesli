# On-device MLX ASR backends: shared layer

This page covers the model-agnostic layer that every MLX speech-recognition
backend (Qwen3-ASR 1.7B, Granite Speech 4.1 2B) sits on. The model ports
themselves, the RAM gate and the Models-tab wiring are separate changes.

## Layers

```
 model port (Qwen3, Granite)        implements MLXAsrRuntime
        |
 MLXAsrTranscriber (actor)          load, warmup, one window at a time,
        |                           cancel, memory pressure, cache clear
        +-- MLXAsrModelStore        pinned manifest, download, verify, delete
        +-- MLXAsrDecodeGuard       token cap, repetition guard, decode loop
        |
 MLXAsrChunkRunner                  dictation windows, meeting chunks,
                                    silence and empty handling, health counters
```

## Failure matrix

Row numbers follow the planning document for the MLX ASR backends so that
reviewers can cross-reference it. Only the rows that belong to the shared layer
are listed. Rows 3 and 13 are marked partial: the shared layer supplies the
mechanism, the policy or UI half arrives with the RAM gate and the wiring.

| # | State or input | What the operation does | How it can fail | What the user is told |
|---|---|---|---|---|
| 1 | Model not downloaded | `isDownloaded` is false and `status` is `notDownloaded`. The store never reports a half-written directory as ready. Fallback to another model is the existing `normalizeMeetingTranscriptionSelectionForAvailability` path. | Fallback silently changes transcription style mid-session. | Existing banner when no model exists. A one-line notice naming the model used when a switch happens (wiring change). |
| 2 | Partial download | The coordinator resumes with ETag, then validates size and SHA-256 per file. The store reports `ready` only when the completion marker matches the pinned revision and every file sits at its manifest size. | Truncated or corrupt cached file, a `.part` file left behind, ETag changed, disk full. | Progress with paused or failed state, the coordinator's disk-space message, and a re-fetch of only the bad file. |
| 3 | Low RAM, memory pressure while loaded (partial) | A memory-pressure dispatch source asks the transcriber to unload. An idle transcriber unloads at once. A busy one finishes the current chunk, then unloads. The next window reloads. | Unload during a decode would corrupt the chunk. A timer would be suspended by App Nap. | A one-line notice through the `onMemoryPressureUnload` callback. The RAM gate (8 and 16 GB) is a separate change. |
| 4 | Load failure | The loader throws. The transcriber clears `loadingModel` and the load task, keeps no runtime, and the next `prepare` runs the loader again. | Missing weight key, unsupported OS, Metal unavailable, corrupt asset. | The loader's error text. The state is clean, so a retry works. |
| 5 | Decode loop | A duration-scaled token cap plus a repetition guard end the loop. The guard never throws: it returns the truncated text and `guardTripped`. | Cap too low truncates fast speech. A legitimate repeat trips the guard. | Meeting: text kept, chunk counted in the guard-trip counter. Dictation: truncated text is used. |
| 6 | Empty or silent chunk | The injected speech gate skips silent chunks before the model runs. A chunk that decodes to nothing, or only to engine artifacts, comes back empty. | Hallucinated text on near-silence. A chunk under one second. | Nothing for skipped silence. Empty chunks are counted. Artifacts are removed by `TranscriptionEngineArtifactsFilter`. |
| 7 | Very long meeting (hours) | Every call gets at most one window of samples. The MLX buffer cache is cleared after every chunk. The runner keeps counters only. | Cache creep, a runner that holds the whole recording. | Nothing. The CI test is a proxy: it checks per-chunk cleanup and window bounds, not resident memory. |
| 8 | Cancellation mid-window | The window runs in a Task the transcriber owns. Cancelling the caller cancels that Task. The decode loop checks `Task.isCancelled` every token and throws `CancellationError`. A result that arrives after cancel is dropped. | An MLX evaluation cannot stop mid-kernel, so cancel latency is one token step. | Existing cancelled state. No partial text from a cancelled window is committed. |
| 9 | Dictation while a meeting transcribes | One window runs at a time. A second caller waits in FIFO order behind the running window. `inFlightWindowCount` shows the queue depth without entering the actor. | Latency grows by up to one chunk decode. | Nothing normally. The UI can read `inFlightWindowCount` to show a waiting notice (wiring change). |
| 10 | App quit during load | `shutdown()` bumps the generation counter and cancels the load, warmup and in-flight tasks. A load that finishes after the bump cannot restore state. | A late finish restores a stale runtime. A half-written file stays. | Nothing. The next launch resumes the partial download through the coordinator state file. |
| 11 | Model update (pinned revision changes) | The completion marker carries the installed revision. A different revision makes `isDownloaded` false. The coordinator re-fetches only files whose size or hash differ. Files that left the manifest are removed after the new revision installs. | The new revision fails halfway. Stale files remain. | "Updating" progress. If the update fails, the old files stay until the new revision is complete. |
| 13 | Diarization alignment (partial) | A chunk returns one `SpeechSegment` whose bounds are the chunk bounds, `0` to the chunk length in seconds. Replay windows go through the existing `MeetingRecordingTranscriber.removingOverlap`. | Overlap words are repeated in the transcript. | Existing speaker labels. Coarser than token-level backends (wiring change documents it). |
| 17 | Model deletion while loaded | `shutdown(ifLoadedModelID:)` cancels the in-flight window and unloads only when that model is loaded or loading. `delete()` on the store cancels an active download first, then removes files. | A delete races a running window. Deleting model A unloads model B. | The window is cancelled and the card returns to "Download". |
| 18 | Hosting repository unreachable, removed or tampered | Every file URL names the pinned revision. A manifest without a 40-character revision is rejected before any request. A 404, size mismatch or hash mismatch surfaces as `modelUnavailable`. | The repo is deleted or renamed. A file changes under the same revision. | "Model unavailable". There is no fallback to `main` or any unpinned revision. |

## Row to test map

| Row | Suite | Test |
|---|---|---|
| 1 | MLXAsrModelStoreTests | `modelNotDownloaded` |
| 2 | MLXAsrModelStoreTests | `partialDownloadIsNotReady`, `truncatedFileFailsValidation` |
| 3 | MLXAsrLifecycleTests | `memoryPressureUnloadsBetweenChunks` |
| 4 | MLXAsrLifecycleTests | `loadFailureClearsState` |
| 5 | MLXAsrDecodeGuardTests | `capScalesWithDuration`, `repeatedNgramStopsAndTruncates`, `windowRuleStopsAndTruncates`, `legitimateRepeatNotTripped`, `guardNeverThrows` |
| 6 | MLXAsrChunkRunnerTests | `silentChunkReturnsEmpty`, `hallucinatedNearSilenceFiltered` |
| 7 | MLXAsrChunkRunnerTests | `longAudioBoundedMemory` |
| 8 | MLXAsrLifecycleTests | `cancelMidWindowCommitsNothing` |
| 9 | MLXAsrLifecycleTests | `concurrentDictationWaitsBehindChunk` |
| 10 | MLXAsrLifecycleTests | `shutdownDuringLoad` |
| 11 | MLXAsrModelStoreTests | `staleRevisionRefetchesChangedFilesOnly`, `staleFilesRemoved` |
| 13 | MLXAsrChunkRunnerTests | `chunkResultCarriesChunkBounds`, `replayDedupesOverlap` |
| 17 | MLXAsrLifecycleTests | `deleteWhileLoaded` |
| 18 | MLXAsrModelStoreTests | `hostingMismatchFails`, `unpinnedRevisionRejected` |

## Decode guard rules

- Token cap: `max(48, ceil(10 * chunkSeconds))`. A non-finite or negative length
  uses the floor of 48. The benchmark ran 300 tokens per 30 s, which is the same
  10 tokens per second.
- Consecutive rule: for n from 3 to 8, if the last `4n` tokens are four copies of
  one n-gram, stop. The shortest period wins. Keep the first copy and cut at the
  start of the second.
- Window rule: if any 3-gram occurs 8 or more times among the last 64 tokens,
  stop. Keep everything up to the end of the first occurrence of that 3-gram
  inside the window.
- Hitting the token cap keeps all tokens and reports `tokenCap`.
- The guard never throws. Cancellation is the only error the decode loop raises.

## Runtime contract for a model port

A port implements `MLXAsrRuntime`: `warmup()`, `transcribe(samples:language:maxTokens:)`
and `unload()`. `transcribe` is synchronous and is called from one Task at a time.
It should drive its token loop with `MLXAsrDecodeGuard.decode(maxTokens:nextToken:)`
so the cap, repetition guard and per-token cancellation check come for free.
`MLXAsrTranscriber.loader(store:makeRuntime:)` covers download plus construction.

## Not done here

- Model ports (Qwen3-ASR, Granite), the RAM gate, and `BackendOption` / Models-tab wiring.
- Health-counter plumbing into `MeetingTranscriptChunkHealthTracker` (the runner keeps its
  own counters so the shared monitor file stays untouched).
- MLX cache settings are process-wide, so they also apply to Bodhan's decoder. The
  default limit is a starting value and has not been tuned against measured memory.
