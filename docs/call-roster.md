# Call roster

The calendar says who was invited. The call says who showed up. While a browser call is being recorded, Muesli reads the names on the call page, adds the ones it does not already know to the meeting's participants, and uses them to name speakers.

```
recording a Meet call ─▶ every 30 s ─▶ is the front tab this call's room? ─▶ read its tile names
                                          no: read nothing                       │
                                                                                  ▼
speaker names  ◀── 1 unnamed speaker + 1 unmatched name ◀── new names ◀── drop self, UI words, repeats
Speakers popover: pick from the roster                       └──▶ meeting participants
```

## What it reads

Only the front tab's page, and only when that page's URL is the room Muesli is following. Chromium exposes page text to other apps once the app is told a screen reader is present (`AXManualAccessibility`), and Arc and Chrome then expose only the tab in front. When the call tab is in the background, a pass reads nothing and the next pass tries again.

Meet's class names change between releases, so the parser does not look for any. Each text node carries the chain of its ancestors' class lists. Names in the tile grid share one chain, because the tiles repeat. The parser keeps a text that is the only one of its kind within a repeated chain.

## Failure matrix

Each row is a test in `CallRosterParserTests`, `CallRosterNamingTests` or `CallRosterTrackerTests`.

| ID | State or input | What happens | How it can fail | What the user sees |
|----|----------------|--------------|-----------------|--------------------|
| R1 | Front tab is not the followed room | Nothing is read | Text from an unrelated page (a profile, a bank) lands in the roster | No new participants |
| R2 | Accessibility is not granted, or the browser is not running | Nothing is read | An error stops the monitor | No new participants |
| R3 | The user's own tile ("You", or their own name) | Excluded | The user appears as a remote participant | Not listed |
| R4 | Clock, "PM", meeting code, button labels | Excluded: not a name | UI words become people | Not listed |
| R5 | The same text on several tiles ("Muted", "Presenting") | Excluded: names are unique within a tile group | A status label becomes a person | Not listed |
| R6 | A single word that is not a known contact ("Gemini") | Excluded unless it matches a calendar attendee | The assistant bot becomes a person | Not listed |
| R7 | More tiles than fit on screen | Names accumulate across passes | A late joiner is missed | Listed once seen |
| R8 | A name already on the meeting (calendar or manual) | Skipped, compared without case, accents or order | Duplicate rows | One row |
| R9 | The user removes a participant the roster added | Not added again in this meeting | The row comes back every 30 s | Stays removed |
| R10 | Private meeting | Roster is not stored | Names reach a meeting that is meant to stay anonymous | Nothing added |
| R11 | Recording is manual, or the call is not in a browser | Nothing is read | Reads a page the user never tied to a call | Nothing added |
| R12 | Two unnamed speakers, or two unmatched names | No automatic naming | A guess names the wrong person | "Speaker N" stays, roster offered in the Speakers popover |
| R13 | Exactly one unnamed speaker and one unmatched roster name | The speaker is named | The unmatched name belongs to a silent attendee | Named, and the user can change it |
| R14 | A speaker already matched by voiceprint | Never overwritten | A recognized voice is renamed | Unchanged |
| R15 | The read takes longer than its budget | The pass is dropped | Evaluation of the call stalls | Nothing |

Calls in native apps (Zoom, Teams) are not read yet. Their window trees differ, and the parser takes plain text nodes, so a reader for them needs no change here.
