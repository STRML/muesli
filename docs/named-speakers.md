# Named speakers

Muesli labels remote voices "Speaker 1", "Speaker 2" and so on. Name a speaker once and Muesli
recognizes the same voice in later meetings.

## Using it

1. **During a live meeting:** Click any `Speaker N` chip in the Live transcript (or the header strip) to assign an existing person or create a new one mid-call. Known voices with saved voiceprints are also matched automatically mid-call once enough audio accumulates.
2. **After a meeting:** Open a meeting. The header strip shows `"N speakers"` next to People. Type a name for a speaker, or pick an existing person, and Save. The transcript lines change to `"Alex:"`.
3. **Next meeting:** Record another meeting with the same person. If the voice matches, the transcript says `"Alex"`.
4. **Backfill existing meetings:** Open **Manage Speakers** (from **Settings → Meetings → Saved speakers → Manage Speakers…**, or the People popover footer) and click **Learn voices from saved recordings** to extract voiceprints non-destructively from already-saved recordings.

Manage Speakers lists everyone with their voiceprint and meeting counts, with **Forget Voiceprints** (keeps the person, drops their voice data) and **Delete**.

## How matching works

After a meeting is diarized, each remote speaker gets a voice summary (a 256-number vector from
FluidAudio's embedding, averaged over the segments weighted by duration). A speaker needs at least
10 seconds of speech to get one.

A voice matches a person only when:

- cosine similarity to their stored voiceprints is at least 0.65 (the mean of their two best),
- and it beats the next-best person by at least 0.10,
- and no other speaker in the same meeting claims that person with a better score.

Anything else stays "Speaker N". "You" (the microphone) is never matched. These thresholds are
starting values and have not been tuned on real meetings, so check the first few matches.

## What is stored

Voiceprint vectors, per-meeting speaker centroids, and speaker profile/voiceprint records live in
your local muesli database only. They are not included in iCloud sync, the CLI, exports, or logs,
and voiceprint vectors are never sent to a model. Deleting a meeting removes its `meeting_speakers`
rows; voiceprints already saved from a meeting stay with the person until you forget them or delete
the person.

In a normal (non-private) meeting, naming or recognizing a speaker writes that name into the
meeting's `raw_transcript`. Once written into `raw_transcript`, those speaker names are part of the
transcript and follow the transcript's normal paths—including iCloud sync, exports, CLI output, Ask
Meetings, and title/summary model requests.

In a private meeting, a recognized or manually assigned speaker name is stored in the local speaker
rows but is not written into `raw_transcript`, and private-meeting rules keep the transcript and
names from leaving for untrusted models, sync, exports, or CLI output.

## Limits

Retranscribing or importing an audio file extracts speaker centroids from the saved audio when diarization runs; meetings without saved audio have no voice data so their speakers stay `"Speaker N"`. Retranscribing replaces the meeting's prior speaker rows with the fresh diarization pass.
