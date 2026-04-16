{
  "id": "tr-aafc",
  "title": "Create DiarizationService with SpeakerKit",
  "status": "closed",
  "type": "feature",
  "priority": 2,
  "tests_passed": true,
  "created_at": "2026-04-16T14:46:38.987Z",
  "parent": "tr-ab5f",
  "deps": [
    "tr-1eff"
  ]
}

Create DiarizationService.swift using SpeakerKit (bundled with WhisperKit) for speaker diarization.

Responsibilities:
- `diarize(audioURL:numSpeakers:) async throws -> [DiarSegment]`
- Returns (start, end, speakerLabel) segments
- Uses SpeakerKit() with default PyAnnote backend
- Graceful fallback: returns [] if diarization fails or is disabled

## Design

```swift
struct DiarSegment {
    let start: Double
    let end: Double
    let speaker: String
}

enum DiarizationService {
    static func diarize(audioURL: URL, numSpeakers: Int?) async throws -> [DiarSegment]
}
```

## Acceptance Criteria

- Produces speaker segments from a multi-speaker WAV file
- Returns empty array when diarization="none"
- Does not crash on short audio or single-speaker recordings

## Tests

- Test with synthetic segments: verify speaker labels assigned
- Test empty input returns empty output
- Test numSpeakers=nil uses automatic detection
