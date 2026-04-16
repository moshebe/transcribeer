{
  "id": "tr-1eff",
  "title": "Add WhisperKit SPM dependency",
  "status": "closed",
  "type": "task",
  "priority": 1,
  "tests_passed": false,
  "created_at": "2026-04-16T14:46:14.138Z",
  "parent": "tr-ab5f"
}

Add WhisperKit v0.18.0+ as SPM dependency in gui/Package.swift. Add "WhisperKit" product to TranscribeerApp target dependencies. Verify it resolves and builds cleanly.

## Acceptance Criteria

- `cd gui && swift build` succeeds with WhisperKit dependency
- `import WhisperKit` compiles in a Swift file
