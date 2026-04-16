{
  "id": "tr-fc67",
  "title": "Port transcript formatting logic to Swift",
  "status": "closed",
  "type": "task",
  "priority": 2,
  "tests_passed": true,
  "created_at": "2026-04-16T14:46:49.624Z",
  "parent": "tr-ab5f",
  "deps": [
    "tr-8e37",
    "tr-aafc"
  ]
}

Port assign_speakers() and format_output() from Python transcribe.py to Swift.

TranscriptFormatter enum with two static functions:
1. `assignSpeakers(whisperSegments:diarSegments:)` — for each whisper segment, find diar segment with max overlap, fall back to midpoint containment
2. `format(labeledSegments:)` — rename speakers (SPEAKER_00 → Speaker 1), merge consecutive same-speaker lines, format as `[MM:SS -> MM:SS] Speaker N: text`

Output must match existing Python format exactly for backward compat.

## Acceptance Criteria

- Output format identical to Python: `[MM:SS -> MM:SS] Speaker N: text`
- Consecutive same-speaker segments merged
- UNKNOWN speaker maps to ???
- Empty segments produce empty string

## Tests

- Port test_transcribe.py assertions to Swift tests
- Test with synthetic whisper + diar segments
- Test single-speaker (no diarization) formatting
- Test empty input
