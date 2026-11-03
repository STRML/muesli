# Keeping notes in your vault

Auto-export can keep one Markdown note per meeting up to date in a folder such as an Obsidian vault.
It is off by default; the original export, which adds a new file for each export, is unchanged.

Turn it on in Settings, Auto Export: enable auto-export, choose the destination folder, then switch on
"Keep notes up to date".

## Behaviour

- One note per meeting, named `YYYY-MM-DD - Title (id).md`. The id keeps two meetings with the same
  title apart and makes the name stable.
- The note is rewritten in place when you change the title, the notes, the transcript or the template
  summary. A note whose content has not changed is left alone.
- With "File by meeting folder" on, the note goes under the meeting's folder path, for example
  `Rush/2026-03-22 - Weekly Sync (42).md`.
- Renaming or refiling a meeting moves its note.
- Deleting a meeting, or marking it private (directly or through its folder), removes its note.
  Removal is a permanent delete, because a trashed note would still hold the content.

## Note format

```
---
muesli_id: 42
title: "Weekly Sync"
date: 2026-03-22
folder: "Rush"
attendees: ["Alex", "Jordan"]
tags: [meeting]
---
```

Every value is written as a quoted string, so a meeting title or attendee name cannot add keys or end
the block. The body is the notes, the transcript, or both, following the "Content" setting.

## Safety

- File and folder names are limited to letters, digits and a few punctuation marks. Folder names such
  as `..` become harmless names, and a destination that would land outside the export folder, for
  example through a symlink, is refused.
- Muesli records which file it wrote for each meeting. It removes or replaces a file only when the
  file's `muesli_id` still matches the meeting, so a note you wrote or replaced yourself is left alone.
- If a file cannot be removed (for example the vault is offline), the removal is retried the next time
  Muesli starts.
