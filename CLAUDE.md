> **Post-compaction recovery:** PreCompact hooks auto-generate context handover files at `Context/handoff-summary-YYYY-MM-DD-<slug>.md`. After compaction, read the latest handoff file in `Context/` to restore session memory and resume work.

# Muesli

Local-first macOS app for **dictation** and **meeting transcription** on Apple Silicon. Speech-to-text runs on-device via CoreML/Neural Engine by default; users can explicitly opt into BYOK OpenAI Realtime dictation. Native Swift/AppKit — no Electron or Python runtime.

**Status:** Live and public. Available at [GitHub Releases](https://github.com/Muesli-HQ/muesli/releases). Signed, notarized, stapled.

## What It Does

- **Dictation:** Hold hotkey → speak → release → text pasted at cursor (~0.13s with Parakeet)
- **Meeting transcription:** Captures mic (You) + system audio (Others) → VAD-driven chunking → speaker diarization → AI-powered meeting notes
- **Meeting export:** Export notes or transcript as PDF (paginated US Letter) or Markdown via `MeetingExporter.swift`
- **Screen context:** Accessibility API captures app name + text around cursor for dictation context-awareness (opt-in, off by default)
- **ASR models:** Parakeet v3/v2, Whisper Tiny/Small/Medium/Large Turbo, Cohere Transcribe, Nemotron 3.5 Multilingual, SenseVoice Small, Qwen3 ASR, Bodhan Core and Flex (each with FP16/INT8 weights)
- **8 summarization backends** (`MeetingSummaryBackendOption.all`): ChatGPT OAuth (default), OpenAI API key, Anthropic API key, Claude Code (local `claude` CLI, listed only when installed), OpenRouter, Ollama, LM Studio, Custom LLM (OpenAI or Anthropic format)
- **Camera-based meeting detection:** Requires mic + camera + recognized meeting app (camera alone won't trigger)
- **Join & Transcribe:** Extract meeting URLs from calendar events (Zoom, Meet, Teams, Webex, Chime, FaceTime), split button with "Join & Transcribe" / "Join Only" / "Transcribe Only", platform icons in notifications
- **Calendar integration (EventKit only):** Coming Up section, status bar, pre-meeting countdowns, event-driven notifications via `EKEventStoreChangedNotification`. Google and other accounts reach Muesli through macOS Calendar; the direct Google OAuth/API code (`GoogleCalendarAuthManager`, `GoogleCalendarClient`) is not called from anywhere
- **Meeting templates:** Built-in and custom templates for structured meeting notes

## Building

Bodhan uses a CoreML encoder and native MLX decoder in both precisions. Its `mlx-swift` dependency requires Swift 6.3; use Xcode 26.6 on macOS 26 to build. See `AGENTS.md` for current build and cache instructions.

### Production build (signed, installed to /Applications)
```bash
./scripts/build_native_app.sh
```

### Dev/test build (isolated from production)
```bash
./scripts/dev-test.sh                         # Build MuesliDev.app (separate bundle ID, separate data)
./scripts/dev-test.sh --lane A                # Build MuesliDevA.app for a parallel worktree
./scripts/dev-test.sh --lane B                # Build MuesliDevB.app for another parallel worktree
./scripts/dev-test.sh --lane A --local-only   # Explicitly omit iCloud/APNs entitlements
./scripts/dev-test.sh --lane A --reset        # Re-run onboarding for lane A, keep lane data
./scripts/dev-test.sh --reset                 # Re-run onboarding for default MuesliDev, keep data
./scripts/dev-seed-from-prod.sh               # Copy production DB/config into MuesliDev safely
```

MuesliDev uses bundle ID `com.muesli.dev` and stores data at `~/Library/Application Support/MuesliDev/`. Named lanes use fixed identities: `MuesliDevA` / `com.muesli.dev.a` / `~/Library/Application Support/MuesliDevA`, then B and C with matching suffixes. Named lane executable/process names also match the lane app name. Production data is never touched.

Named lanes default to local-only signing through `scripts/MuesliLocalOnly.entitlements`, which omits iCloud and APNs entitlements for non-sync feature work. Use `--cloud-entitlements` only when the lane has a matching Apple Developer provisioning profile and the test actually needs iCloud/APNs behavior.

### SwiftPM build artifacts in worktrees
SwiftPM can write build artifacts to `native/MuesliNative/.build` inside the active worktree. That can consume several GB per worktree. Local scripts now resolve a shared SwiftPM scratch path through `scripts/muesli_spm_cache.sh`:

- Explicit `MUESLI_SWIFTPM_SCRATCH_PATH` wins.
- `MUESLI_SWIFTPM_SCRATCH_CHANNEL` overrides the channel segment under the resolved cache root.
- `MUESLI_EXTERNAL_SPM_CACHE_ROOT` opts into another cache root, used only when that directory exists.
- Otherwise scripts use `~/Library/Caches/muesli-spm`, the canonical maintainer cache. The eSSD sparse bundle and `/Volumes/MuesliBuildCache` are retired (see `AGENTS.md`); do not attach or create external volumes.
- `MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1` intentionally opts out and uses SwiftPM's package-local `.build`; this takes precedence over all scratch path settings.

Default script channels:

```bash
./scripts/dev-test.sh                 # ~/Library/Caches/muesli-spm/worktrees/<worktree>/dev
./scripts/build_native_app.sh release # ~/Library/Caches/muesli-spm/release
./scripts/release-preprod.sh          # ~/Library/Caches/muesli-spm/preprod
./scripts/release-alpha.sh            # ~/Library/Caches/muesli-spm/alpha
```

For parallel PR/worktree work, use isolated paths:

```bash
MUESLI_SWIFTPM_SCRATCH_PATH="$HOME/Library/Caches/muesli-spm/worktrees/pr182/dev" ./scripts/dev-test.sh
swift test --package-path native/MuesliNative --scratch-path "$HOME/Library/Caches/muesli-spm/worktrees/pr182/test"
```

The build script passes the resolved path to SwiftPM as `--scratch-path`, so multiple worktrees do not each grow their own `.build`. Caveat: do not run concurrent builds from different worktrees into the same scratch path; use separate paths per channel, agent, or simultaneous build. Deleting a scratch path only removes rebuildable SwiftPM artifacts, not installed apps or app data. Set `MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1` only when you intentionally want package-local `.build`.

### Parallel dev lanes
Use fixed lanes for concurrent local testing instead of creating branch-named app identities:

```bash
./scripts/dev-test.sh --lane A
./scripts/dev-test.sh --lane B
./scripts/dev-test.sh --lane C
```

Each lane installs a separate app bundle under `/Applications/`, keeps a separate support directory under `~/Library/Application Support/`, and has a separate macOS permission identity. Grant permissions once per lane. Do not copy or reset TCC permissions unless explicitly testing permission prompts.

### Tests
```bash
swift test --package-path native/MuesliNative    # 3,148 @Test declarations, 261 @Suite-annotated types (2026-10-16)
```

### Onboarding testing
```bash
# Reset onboarding without losing data:
./scripts/dev-test.sh --reset
./scripts/dev-test.sh --lane A --reset

# Reset macOS permissions only when intentionally re-granting TCC:
./scripts/dev-reset-permissions.sh
./scripts/dev-reset-permissions.sh --bundle-id com.muesli.dev.a --process-name MuesliDevA --app-path /Applications/MuesliDevA.app

# Then:
./scripts/dev-test.sh
./scripts/dev-test.sh --lane A
```
Note: config JSON uses snake_case keys (`has_completed_onboarding`, not `hasCompletedOnboarding`).

## CI/CD Pipeline

### Pull Requests
- **CI workflow** (`.github/workflows/ci.yml`): macOS 26 runners for Swift jobs, Ubuntu for script checks
  - `changes` → `build` → `cli-smoke` → `ci-gate` (required check)
- **Claude Code Review** — reviews every PR automatically
- **Greptile** — reviews every PR automatically
- **Vercel** — `vercel.json` deploys `main` with no build command (there is no `site/` directory)
- **Concurrency** — stale CI runs auto-cancelled on new pushes

### Releases
```bash
./scripts/release.sh                   # Auto-increments version
./scripts/release.sh 1.0.0             # Explicit version
```
**Critical:** Staple the app bundle BEFORE creating the DMG, otherwise Gatekeeper rejects.

### Signing & Notarization
- Developer ID: `Pranav Hari Guruvayurappan (58W55QJ567)`
- Bundle ID: `com.muesli.app`
- Notary profile: `MuesliNotary` (Keychain)

## Key Architecture

```
native/MuesliNative/Sources/
├── MuesliNativeApp/              # Main app (265 Swift files)
│   ├── MuesliController.swift    # Central orchestrator — dictation, meetings, onboarding, state
│   ├── TranscriptionRuntime.swift # Routes to ASR backends, post-processing, VAD + diarization
│   ├── FluidAudioBackend.swift   # Parakeet TDT on ANE
│   ├── Qwen3AsrBackend.swift     # Qwen3 ASR on ANE (macOS 15+)
│   ├── Qwen3PostProcessor.swift  # On-device GGUF LLM for dictation cleanup (opt-in)
│   ├── WhisperKitBackend.swift   # Whisper on CoreML/ANE via WhisperKit
│   ├── ScreenContextCapture.swift # AX-based app context for dictation + meetings
│   ├── MeetingExporter.swift     # PDF/Markdown export with NSPrintOperation
│   ├── OnboardingView.swift      # 7-step onboarding with real permission polling + dictation test
│   ├── OnboardingProgress.swift  # Crash-safe onboarding state persistence
│   ├── MeetingSession.swift      # Meeting lifecycle + diarization + screen context
│   ├── MeetingSummaryClient.swift # Summaries for all 8 backends (ChatGPT, OpenAI, Anthropic, Claude Code, OpenRouter, Ollama, LM Studio, Custom LLM)
│   ├── SystemAudioRecorder.swift # ScreenCaptureKit fallback for system audio (CoreAudioSystemRecorder is the default)
│   ├── ChatGPTAuthManager.swift  # OAuth PKCE + WHAM API
│   ├── HotkeyMonitor.swift       # Global hotkey detection (modifier keys)
│   ├── MeetingDetector.swift     # Camera + mic + app detection for meetings
│   ├── MeetingNotificationController.swift # Join & Transcribe notification panel with platform icons
│   └── PasteController.swift     # Clipboard-preserving Cmd+V paste
├── MuesliCore/                   # Shared library (SQLite, paths, models)
│   ├── DictationStore.swift      # SQLite3 C API — dictations + meetings CRUD
│   └── MuesliPaths.swift         # App-identity-aware path resolution
└── MuesliCLI/                    # Agent-friendly CLI (JSON over stdout)
```

## Data Storage

- **Config:** `~/Library/Application Support/{AppName}/config.json` (snake_case keys)
- **Database:** `~/Library/Application Support/{AppName}/muesli.db` (SQLite WAL)
- **Models:** `~/Library/Application Support/FluidAudio/Models/` (shared across app identities)
- **Onboarding progress:** `~/Library/Application Support/{AppName}/onboarding-progress.json` (deleted on completion)
- **ChatGPT tokens:** `~/Library/Application Support/{AppName}/chatgpt-auth.json`
- **Whisper models:** `~/.cache/muesli/models/`

`{AppName}` is `Muesli` for production, `MuesliDev` for dev, `MuesliCanary` for alpha — controlled by `MuesliSupportDirectoryName` in Info.plist.

## Network Activity

Keep `docs/privacy.html` in step with this list.

**On by default, no user content:**
- Model downloads from `assets.muesli.works` (checksum-pinned mirror for some Parakeet and WhisperKit variants, `MuesliCore/ManagedASRModelDownloads.swift`) and `huggingface.co` plus its CDN (everything else). The chosen model downloads during onboarding; FluidAudio diarizer/VAD models download at launch for meeting users when missing. Opening the Models tab with Nemotron installed queries the Hugging Face API for updates.
- Sparkle update checks against `SUFeedURL` (`SUEnableAutomaticChecks=true` in the plist suppresses Sparkle's permission prompt; dev and alpha builds have an empty feed).
- `NSApplication.registerForRemoteNotifications()` on every launch (`AppDelegate.swift`), even with iCloud sync off; it only registers in builds with an `aps-environment` entitlement.
- `claude auth status` when the Claude Code option is shown and a `claude` binary exists (`MuesliCore/ClaudeCodeSummarizer.swift`).

**On by default, sends content to the configured summary backend:**
- Meeting summaries and titles (backend defaults to ChatGPT; nothing is sent until sign-in).
- Folder suggestions (`auto_classify_meetings=true`): title, participant names, a notes prefix, and the folder tree after a meeting no rule matches.
- Browser call participant names (`read_call_participants=true`): read locally through Accessibility, then included in summary and folder-suggestion prompts.

**Off by default:** TelemetryDeck analytics (the build needs `MUESLI_ENABLE_TELEMETRY=1` to compile an app ID in, and the user must turn on "Share anonymous usage analytics"), iCloud sync, hosted dictation, hosted cleanup and Quill, Ask Meetings (per message), computer use.

## macOS Permissions

| Permission | What Uses It | API |
|---|---|---|
| Microphone | Dictation + meeting mic | AVAudioRecorder, AVAudioEngine |
| Accessibility | Paste text + screen context capture | CGEvent Cmd+V, AXUIElement |
| Input Monitoring | Hotkey detection | NSEvent global monitors |
| System Audio | System audio capture (default, `use_core_audio_tap=true`) | Core Audio process tap |
| Screen Recording | ScreenCaptureKit system-audio fallback, meeting screen context and OCR, computer-use screenshots | ScreenCaptureKit, `CGPreflightScreenCaptureAccess` |
| Camera (implicit) | Meeting detection | CoreMediaIO property listeners |
| Calendar (optional) | Upcoming meetings | EKEventStore |
| Contacts (optional) | Picking meeting participants from Contacts, saving a new contact | CNContactStore |

**Critical:** Accessibility permission requires an app restart to take effect. The onboarding flow handles this with an automatic restart after the hotkey configuration step.

**Important:** `CGWindowListCreateImage` (screenshots) conflicts with active `SCStream` sessions — causes `RPDaemonProxy: connection INTERRUPTED` and breaks system audio capture. This only applies to the ScreenCaptureKit fallback (`use_core_audio_tap=false`); with the default Core Audio tap, meetings take OCR screenshots (`MeetingSession.swift` passes `useOCR: config.useCoreAudioTap`).

## Onboarding Flow

7 steps: Welcome → Model → Permissions → Hotkey → **[app restart]** → Dictation Test → Meeting Summaries → Calendar (macOS Calendar access)

Key implementation details:
- Real OS permission polling every 1s (not fake timers) via `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`, etc.
- Uses proper request APIs: `AXIsProcessTrustedWithOptions`, `CGRequestScreenCaptureAccess`, `CGRequestListenEventAccess`
- Hotkey, calendar, and mic monitors are **deferred until after onboarding completes** to prevent premature permission prompts
- App restart via detached shell: `/bin/sh -c "sleep 1; open -- \"$1\"" -- <bundlePath>` then `NSApp.terminate(nil)`
- Progress saved on every step transition to `onboarding-progress.json` (schema-versioned, atomic writes)
- Dictation test step uses the real hold-to-talk hotkey flow with `dictationTestCallback` routing. It never pastes, but intentionally keeps the floating waveform visible so onboarding exercises the same recording feedback as normal dictation; releasing the hotkey leaves the active state immediately.
- `OnboardingView.dictationTestStep` (static Int = 4) — hotkey monitor only starts when resuming at this step or later

## Screen Context (opt-in, `enableScreenContext` in config)

**Dictation:** `DictationContextCapture.capture()` — synchronous Accessibility API call:
- App name + bundle ID via `NSWorkspace.shared.frontmostApplication`
- Text before cursor via `kAXSelectedTextRangeAttribute` + `kAXStringForRangeParameterizedAttribute` (falls back to `kAXValueAttribute` suffix for apps that don't support parameterized attributes)
- Selected text via `kAXSelectedTextAttribute`
- Browser URL via `kAXDocumentAttribute`
- Only runs when BOTH `enableScreenContext` AND `enablePostProcessor` are true
- Context injected into Qwen3 post-processor prompt as `<APP-CONTEXT>` tags
- Stored in existing `app_context` column in `dictations` table

**Meetings:** `MeetingScreenContextCollector` (actor) — periodic AX capture every 60s:
- Uses same `DictationContextCapture.capture()`, plus OCR screenshots (`ScreenContextCapture.captureOnce()`) when the Core Audio tap is in use
- Deduplicated, aggregated, injected into meeting summary prompt as "Visual context" section
- Starts only when `enableScreenContext` is on and Screen Recording access is already granted

## Meeting Export

`MeetingExporter.swift` — export menu in `MeetingDetailView` content toolbar:
- Two menu items: "Export Notes"/"Export Transcript" (contextual to active tab) + "Export Full Meeting"
- Format (PDF/Markdown) chosen via `ExportFormatAccessory` popup in NSSavePanel
- PDF: `NSPrintOperation` with paginated US Letter pages (612x792pt, 1" margins)
- Markdown: atomic write with metadata header (title, date, duration, word count, template)
- NSSavePanel presented via `beginSheetModal(for:)` — never `runModal()` (deadlocks in SwiftUI)
- File auto-opens in default app after save via `NSWorkspace.shared.open(url)`

## Development Workflow

1. **Feature work:** Create branch → implement → `./scripts/dev-test.sh` → push → PR
2. **PR review:** Claude Code + Greptile review automatically. Fix P1s before merge.
3. **Merge to main** via squash merge
4. **Release:** `./scripts/release.sh` → notarize → GitHub Releases

## Calendar Notification Pipeline

Event-driven architecture for meeting notifications:

- **Primary trigger:** `EKEventStoreChangedNotification` — macOS pushes calendar changes (add/move/delete) instantly via `NotificationCenter`. Immune to App Nap timer suspension in LSUIElement apps.
- **Fallback:** 60s `Timer` re-reads EventKit and checks the 5-minute notification window for time-based triggers.
- **Dedup:** Composite key `id|startDate` — rescheduled events generate fresh notifications. Stale entries pruned hourly.
- **Per-event timers:** `meetingStartingNowTimers: [String: Timer]` — concurrent events get independent "starting now" timers.
- **Suppression:** After user acts on a calendar notification (Join Only, Dismiss), mic/camera detection is suppressed for the remaining event duration.
- **Meeting URL extraction:** EventKit (`event.url`, `location`, `notes` via regex).

**macOS 26 App Nap behavior (LSUIElement apps):** All timer mechanisms (`Timer.scheduledTimer`, `DispatchSourceTimer`, `Task.sleep`, `Thread.sleep`, `DispatchQueue.asyncAfter`, POSIX `nanosleep`) get suspended by aggressive power management. Only `NotificationCenter` observers (system IPC) are immune. The 60s fallback timer may not fire reliably — `EKEventStoreChangedNotification` is the critical path. Google and other accounts must be added to macOS Calendar (System Settings > Internet Accounts) to appear at all.

## Known Limitations

- **Nemotron 3.5 Multilingual (`nemotron35`):** Supported local Nemotron ASR backend. Ships the FluidInference `multilingual/2240ms` variant (~665 MB, vocab 13087, blank 13087). Multilingual incl. Hindi/Chinese/Japanese + 100+ locales via `prompt_id`. In-app **language picker** (`Nemotron35Language` enum → `prompt_id`; config key `nemotron35_language`, default `auto`=101): the controller pushes the selected prompt id to the coordinator (`setNemotron35PromptId`), which applies it to the actor on load/select. Picker UI lives in the Models tab card (mirrors the Cohere language card). A **model-update check** records the HF repo commit sha at download (`<cache>/.revision`) and surfaces an "Update" affordance in the Models tab when the repo's `main` advances (never auto-downloads). Native punctuation (in-vocab). Append-only/no corrections, weak on very short dictations. 2240ms chunk latency (35840 samples). Cache shape `[1,24,42,1024]`. Uses shared `RNNTStreamState` helpers through the `NemotronStreamingTranscribing` protocol; `StreamingDictationController` takes a `chunkSamples` override. Model cached at `~/.cache/muesli/models/nemotron35-multilingual-2240ms/`. Offered in onboarding under "Other models". **Dictation modes:** hold-to-talk uses the normal record→transcribe-file path (`transcribeWithNemotron35`); double-tap uses live streaming (`StreamingDictationController`). `handleStart` allows hold-to-talk; prepare/arm pre-warm stays skipped for streaming backends (`isStreamingDictationBackend`) so the double-tap detection window stays clean.
- **Qwen3 ASR:** 2-3s latency (autoregressive decoder). First run after launch has ~30s CoreML compilation warmup.
- **ChatGPT OAuth:** Uses reverse-engineered WHAM API. Could break if OpenAI changes the API.
- **Speaker diarization:** The transcript labels come from a post-processing pass that runs after the meeting stops. The optional `enable_live_speaker_labels` setting (off by default) also shows provisional "Speaker N" labels for system audio in the Live tab while recording, using FluidAudio LS-EEND (`LiveSpeakerLabelSession`). They are Live-tab only: crash-recovery checkpoints keep "Others" and the Stop-time pass overwrites everything. The model downloads when the setting is turned on; meetings load it from the local cache and never touch the network.
- **Screen context OCR on the ScreenCaptureKit fallback:** `CGWindowListCreateImage` conflicts with `SCStream`, so meetings recorded with `use_core_audio_tap=false` use AX-only context.
- **NSSavePanel:** Must use `beginSheetModal(for:)` in SwiftUI, never `runModal()`. `NSAttributedString(html:)` deadlocks on main thread — build attributed strings manually.
- **App restart during onboarding:** Uses `exit(0)` via detached shell. `NSApp.terminate(nil)` inside SwiftUI animation context can crash.
- **macOS 26 App Nap:** LSUIElement apps have all timers suspended by aggressive power management. Calendar notifications rely on `EKEventStoreChangedNotification` (immune). The 60s calendar refresh timer may not fire. See Calendar Notification Pipeline section.
- **"Meeting starting now" after Join Only/Dismiss:** The scheduled timer is not cancelled when the user clicks Join Only or Dismiss on the "Upcoming meeting" notification. A redundant "Meeting starting now" fires at event start time. Fix: pass notification key into `handleUpcomingMeeting` so callbacks can cancel it.

## Upcoming Work

1. **Cancel "starting now" timer on Join Only/Dismiss** — Pass notification key into `handleUpcomingMeeting` so `onJoinOnly`/`onDismiss` callbacks can cancel `meetingStartingNowTimers[key]`.
2. **Google Calendar direct integration** — The OAuth/API code exists but nothing calls it; calendar data comes only from EventKit. Either wire it up (it needs verified Google credentials) or delete it.
3. **Post-processor fine-tune** — Collect `postproc-pairs.jsonl` from canary testers, train v3 model for better implicit list formatting.
