# Calendar enricher and meeting context

Status: PR 1 done and tested. Branch: `feat/calendar-enricher`.

## Goal

When a recording starts and stops, find the calendar event that matches the recording time. Store the event
title, time and attendees in the session's `meta.json`, use the title as the session name, write the event to the
meeting-notes export, and use the attendees to improve speaker labels and summaries.

Today most sessions have no name (`2026-11-11-1638`), the export has no meeting context, and transcripts label
every remote voice as "Them". Tools that read the export (a notes repo, an Obsidian vault) must guess what the
meeting was from its content.

## What exists

- Zoom enricher: `ZoomTitleReader` (topic) and `SessionParticipantsRecorder` (participant names in `meta.json`),
  both behind `zoomEnricherEnabled`. `prefillMeetingTitle()` sets the name only when it is empty.
- `startedAt` / `endedAt` in `meta.json` (`SessionManager.setRecordingTimes`).
- `MeetingNotesExporter`, run from `IntegrationDispatcher` after the pipeline.
- `DualSourceTranscriber`: mic segments are labeled `selfLabel` (or diarized when `diarizeMicMultiuser`), system
  audio segments are all labeled `otherLabel`. System audio is never diarized.
- The summarizer gets no title or participant names. WhisperKit `DecodingOptions` uses no prompt tokens.
- No EventKit code, no calendar usage string, no calendar entitlement.

Constraint: `PipelineRunner.swift`, `Session.swift` and `TranscribeerApp.swift` are at or near the 600-line
SwiftLint warning. New logic goes in new files or extensions.

## Design

### 1. Matching (pure logic)

`Services/Meeting/CalendarEventMatcher.swift`, a caseless enum.

- Input: `[CalendarCandidate]` (plain values), recording start, optional end.
- Candidates: events that overlap the recording window. With no end (recording in progress), the window is
  10 minutes from the start, so a meeting that is about to end loses to one that is about to begin.
  (2026-11-17: a 30-minute window picked the next meeting, a forum that began 13 minutes after recording start.)
- Filters: drop all-day events, events the user declined, and (by default) events with no other attendees.
- Score: overlap in seconds. On a tie (double booking), prefer the event the user accepted, then the event with
  fewer attendees (a 1:1 over a forum). If still tied, return `nil`. Never guess.

### 2. EventKit reader

`Services/Meeting/CalendarEventReader.swift`, a thin wrapper around `EKEventStore`.

- `requestFullAccessToEvents()` (macOS 14+). Authorization status for the permissions UI.
- Fetch events for a window and map each to `CalendarCandidate` (title, start, end, all-day, user status,
  attendees with name / email / status, organizer email, calendar title, external ID).
- Attendee email comes from `EKParticipant.url` (`mailto:`).
- Optional filter by calendar title (`calendarNames`, empty = all).

### 3. When to match

`Services/PipelineRunner+Calendar.swift` (extension).

- Record start: match on events in progress. Set the session name if it is empty.
- Record stop, before transcription: match again with the full window. Replace the name only if the calendar set it.
- `meta.json` gets `name_source` (`user` / `calendar` / `zoom`). Precedence: user, then calendar, then Zoom
  (a Zoom personal meeting room topic says less than the event title). A user rename sets `user`. A name with no
  `name_source` predates this change and counts as the user's.
- Upstream applies the Zoom topic only to auto-started recordings (`applyMeetingTitle`). The calendar match runs
  for every recording.
- The stop match is authoritative. If it finds no event, it removes the start match and any name the calendar set.
- Imported sessions have no time: no automatic match. The history action in PR 2 covers them.

### 4. Data

`Models/SessionManager+CalendarEvent.swift`.

```json
"calendar_event": {
  "title": "Itay / Or - 1:1",
  "start": "2026-11-11T14:30:00Z",
  "end": "2026-11-11T14:55:00Z",
  "calendar": "or@example.com",
  "external_id": "...",
  "organizer": "or@example.com",
  "attendees": [{"name": "Itay", "email": "itay@example.com", "status": "accepted"}],
  "matched_at": "stop"
}
```

Kept separate from the Zoom `participants` list (names vs. emails). The user's own attendee entry is not stored.

### 5. Settings and permission

- Config `[pipeline]`: `calendar_enricher_enabled` (default **false**, personal data) and `calendar_names`
  (list, empty = all calendars).
- Settings: a toggle next to the Zoom enricher, in its own view (`CalendarEnricherSettingsSection.swift`).
  Turning it on requests calendar access.
- `Info.plist`: `NSCalendarsFullAccessUsageDescription`.
- Entitlements: `com.apple.security.personal-information.calendars` (hardened runtime denies without a prompt
  if it is missing).
- `PermissionsProbe` and the onboarding permissions view: deferred. The settings section requests access and
  shows its state, which is enough for an opt-in feature.

## PRs

### PR 1 - `feat: calendar enricher`

Matcher, reader, meta data, `name_source`, config, settings toggle, permission, match at start and stop.

Tests: matcher table (best overlap, declined, all-day, no attendees, tie gives `nil`, back-to-back meetings,
in-progress at start), `calendar_event` meta round trip, `name_source` precedence, config TOML decode/encode.

### PR 2 - `feat: calendar event in meeting-notes export`

- Export frontmatter, when the session has a matched event:
  ```yaml
  calendar_event: "Itay / Or - 1:1"
  calendar_event_id: <external id>
  attendees:
    - itay@example.com
  ```
- History context action "Match calendar event" for any session with `startedAt` (backfill).
- Session detail: one row with the event title and attendee count.

Tests: exporter frontmatter with and without an event.

### PR 3 - `feat: use meeting context in the pipeline`

A `MeetingContext` value (title, attendee names, count, source), built from the calendar event and the Zoom
participants. Zoom participants (people who joined) win over the invite list when both exist.

1. 1:1 speaker label: when there is exactly one other person, use their first name in place of `otherLabel`
   for that session only. The global setting does not change. Highest value, highest reliability.
2. Summarizer: add the title and attendee names to the prompt.
3. Whisper prompt (option, default off): a short names-only prompt through WhisperKit `promptTokens`, and the
   `prompt` field for cloud backends. Long prompts can cause repetition or invented text, and the Hebrew model is
   more sensitive. A/B test on real recordings before it can be on by default.
4. Not done: diarization speaker count from attendees (invites are not attendance), and names for speakers in
   remote group calls (system audio is one channel; needs voice enrollment).

Tests: label choice by attendee count, prompt building, context from each source.

## Out of scope

- On-export hook command.
- Merging calendar attendees into the Zoom participants list.
- Voice enrollment / per-speaker names in group calls.

## Verification

Run with Xcode selected (`xcode-select -p` shows `/Applications/Xcode.app/...`). With only the Command Line
Tools, `swift test` cannot find the `Testing` module and SwiftLint cannot load `sourcekitdInProc`.

PR 1 results: `swift build` OK, `swift test` 359 tests passed (15 new tests), `make lint-strict` 0 violations.
Manual test 2026-11-17: recorded a 1:1, the stop match named the session and saved the event. Found and fixed the
start-window bug above.

Each PR: `swift build`, `swift test`, `make lint-strict`, results in the PR description.

Manual (PR 1): `make build-dev`, grant calendar access, record during a test event with one attendee, check
`meta.json`. Rename the session during recording, stop, check the calendar did not overwrite the name.

## Delivery

- Branch from `origin/main`. Conventional commits. One concern per PR.
- Open an upstream issue first to agree on the design and on "default off".
- Consumers that key on event IDs: EventKit gives the iCal UID (`calendarItemExternalIdentifier`), not the
  Google Calendar event ID.
