# Folder suggestions

Muesli can suggest a folder for a meeting and learn from the folders you pick. It suggests; it does
not move a meeting unless you turn on auto-file, and even then only for a learned rule.

## What it looks at

Rules run first and the first decisive one wins:

| Rule | Decisive when |
|---|---|
| Calendar series | The same recurring series was filed to one folder before, with no contradiction |
| Attendees | Every known attendee points at the same folder, no attendee contradicts it, and the least-confirmed one has at least 2 confirmations. Attendees with no history do not block it. |
| Title | The same title (times, dates and digits removed) was filed to one folder at least twice |

If no rule decides, the selected summary backend is asked once, with the folder names, the title, the
attendee names and the first 1,500 characters of notes. It must answer with one folder name that
exists, or nothing. An LLM suggestion is never applied automatically.

Your own address is not counted as an attendee. Muesli treats an address as yours when it appears in
at least 80% of meetings that have attendees, once there are 5 such meetings.

## The Inbox

Suggestions collect in the Inbox row in the Meetings sidebar, with a count. For each one you can
Accept (moves the meeting), Choose Another Folder, or Dismiss (it is not suggested again).

## Learning

Filing a meeting yourself, or accepting a suggestion, records the meeting's series, attendee
addresses and title against that folder. Moving it again takes the earlier count back, so refiling a
meeting never counts twice. A suggestion you reject adds a contradiction to the rule that made it.
Auto-filed meetings never count as confirmations, so rules cannot reinforce themselves.

## Settings

Settings, "Folder Suggestions":

- Suggest folders for meetings (on): generate suggestions after a meeting finishes.
- Auto-file confident matches (off): move a meeting that has no folder when a learned rule is
  decisive. If you move it back to Unfiled, the rule gets a contradiction.
- Classify Unfiled Meetings: run it over existing meetings, newest first.

Nothing runs while a meeting is recording.

## Private meetings

A private meeting is sent to the model only if the selected backend is allowed for private meetings
(see private-meetings.md). Private folders, and their subfolders, are left out of the folder list
sent to a backend that is not allowed. The prompt treats notes as quoted data, and a reply that names
a folder that does not exist is dropped.
