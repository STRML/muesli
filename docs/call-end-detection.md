# Call-end detection

With **Stop recording when the call ends** turned on (Settings, Meetings, Recording; off by default), a recording that follows a call (started from a prompt, a calendar auto-record, a scheduled-meeting prompt, or Join & Transcribe) stops by itself when the call ends, and says so. With the setting off, the same decision raises the call-ended alert instead and the recording keeps going. A manual recording never stops by itself.

```
signals ─▶ resolver ─▶ session tracker ─▶ call tracker ─▶ decision ─▶ controller
 mic, camera,  candidate    keeps a session    seen / lost     none | stop +    stops, shows
 audio procs,  or nil       alive 30 s         per recording   notice           the notice
 browser tabs
```

## Timing

```
call ends                10 s grace            20 s remote silence
   │──── signal lost ────────▶│─────────────────────▶│
                                                    stop + "Zoom call ended"
```

- The call counts as lost when the tracker saw it during this recording and the latest observation no longer finds it.
- The recording stops once the call has been lost for 10 s and no remote speech has been transcribed for 20 s. The user's own voice does not count as remote speech.
- The scheduled-end popup ("Scheduled time ended") yields to the call tracker. It is skipped when the call is already lost, because the stop notice owns that moment.

## Failure matrix

Each row is one scenario in `MeetingCallEndScenarioTests`. The IDs match the test names.

| ID | State or input | What happens | How it can fail | What the user is told |
|----|----------------|--------------|-----------------|-----------------------|
| E1 | Zoom, Teams, Webex, FaceTime or Slack call ends, app stays open | Lost at the first frame without media, stops once 20 s of remote silence have passed | The running app keeps the candidate alive (a calendar guess from a running app) | "<Platform> call ended. Transcription stopped." |
| E2 | Browser call (Meet, Zoom web) ends, tab closed or navigated away | Room URL gone, same as E1 | A stale tab for the same room hides the loss | Same notice |
| E3 | Browser call ends, tab left open on the post-call page | Media stops, the room URL stays, and a recording that follows a call needs media as well as the tab | The focused tab alone counts as the call forever | Same notice |
| E4 | Signal drops for less than 10 s (mute, device switch, network blip) | Nothing | Stops a live call | Nothing |
| E5 | Signal drops longer than 10 s while remote speech keeps arriving | Defers the stop | Stops a live call | Nothing |
| E6 | After the call ends, only the user's own voice is transcribed | Does not defer the stop | The mic keeps hearing the user, so the call is never judged over | Notice as E1 |
| E7 | In a call, muted and listening, mic still attributed to the call app | Call stays seen, recording continues through remote silence | Attribution lapses and a quiet meeting is cut | Nothing |
| E8 | Signal returns after the loss began (rejoin) | Loss clears, a second loss starts a new 10 s | A stale loss stops the rejoined call | Nothing |
| E9 | Source never seen (armed from a link, the call was never joined) | Never stops | Stops a recording that is waiting for a call | Nothing |
| E10 | Manual recording | Never stops | Stops a recording the user started by hand | Nothing |
| E11 | A second room starts in the same browser after the first call ends | The first call counts as lost, the second room does not extend it | The second call keeps the first recording alive | Notice for the first |
| E12 | The call app is on the muted-detection list | The controller skips the observation before the policy runs | Stops or alerts for an app the user muted | Nothing |
| E13 | User stops manually during the grace period | Nothing fires afterward | A stale timer shows a second notice | Nothing |
| E14 | Scheduled end passes while the call is live | The scheduled-end popup shows | Popup missing | "Scheduled time ended" |
| E15 | Scheduled end passes after the call was lost | No scheduled-end popup | Two alerts for one event, or the popup hides the stop notice | Only the stop notice |
| E16 | Stop is already running when the decision fires | No second stop, no second notice | Two notices | One notice |
| E17 | User dismissed the call-ended alert for this recording | Never stops | Overrides the user's choice | Nothing |

Known limitation: a native app (Zoom, Teams) has no room identity, so a second call in the same app right after the first looks like the same call and keeps the recording going.

E12 lives in the controller and has no scenario. All other rows run through the real resolver, media filter, session tracker and call tracker.

## Testing a real call yourself

1. Run the dev app with `./scripts/dev-test.sh`.
2. Start a recording from a calendar link or a prompt, join the call from a second device, and talk for a minute.
3. End the call on the second device. Leave the Zoom or Teams app open on the Mac.
4. Expect the recording to stop with the "call ended" notice within about 20 s of hanging up.
5. Read the timeline with `grep "meeting-monitor\] call_" ~/Library/Logs/MuesliDev/stderr.log`. The lines carry a timestamp and read `call_seen`, `call_lost`, `call_recovered` and `call_auto_end`.
6. If the call ended and nothing stopped, the `call_lost` line is missing. Add the platform and the signals from the log as a new scenario in `MeetingCallEndScenarioTests`.
