# Recordings storage budget

Meeting audio is the biggest thing Muesli keeps. A budget removes the oldest audio when saved
recordings pass a size you choose. Transcripts and notes are never touched.

It is off by default.

## Settings

Settings, "Recordings storage":

- Budget: Off, or 10, 25, 50, 100, 250 or 500 GB.
- Minimum age: 3, 7, 14 or 30 days. Audio newer than this is never removed.

Both are manual-only for voice commands because they delete files.

## What gets removed

When recordings are over the budget, Muesli removes the audio of the oldest meetings first, one whole
meeting at a time, until it is under budget. It skips a meeting that:

- is pinned ("Keep Recording" in the meeting menu),
- is recording, processing or can be resumed,
- has no transcript yet,
- is newer than the minimum age.

A file is removed only if it is inside the recordings folder. A file shared with a protected meeting
stays. Files are deleted, not moved to the Trash, because a trashed file keeps using the space.

The meeting keeps its transcript and notes. Each removal is logged
in the `recording_prune_log` table with the meeting id, path and size.

Pruning runs at launch, after a meeting finishes, and when you change either setting. If Muesli
stops between deleting a file and updating the database, the next run repairs the record.
