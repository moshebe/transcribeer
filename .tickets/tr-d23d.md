{
  "id": "tr-d23d",
  "title": "Clean up 14 remaining SwiftLint warnings",
  "status": "closed",
  "type": "chore",
  "priority": 3,
  "tests_passed": false,
  "created_at": "2026-04-16T20:31:30.965Z"
}

SwiftLint is set up with pragmatic defaults in `.swiftlint.yml`. `make lint` now exits 0, but 14 warnings remain. Fix them so we can flip CI to `make lint-strict` (warnings fail).

Violations (run `make lint` for exact locations):
- `anonymous_argument_in_multiline_closure` x2 — SettingsView.swift (summarization backend Picker set closure)
- `for_where` x1 — ZoomWatcher.swift:93
- `function_body_length` x1 — PipelineRunner.swift:45 (88 lines, limit 80) — probably worth splitting
- `non_optional_string_data_conversion` x1 — PipelineRunner.swift:55
- `discouraged_optional_boolean` x2 — Config.swift TOML sections (`zoom_auto_record`, `prompt_on_stop` are `Bool?` by design for TOML merge; may justify `disabled_rules` scoped to that file)
- `pattern_matching_keywords` x2 — SummarizationService.swift:98
- `empty_string` x2 — AppStateTests.swift, TranscriptFormatterTests.swift
- `large_tuple` x1 — TranscriptFormatter.swift:59
- `multiline_arguments` x2 — TranscriptFormatter.swift:36-37

Acceptance: `make lint-strict` exits 0, CI workflow updated to use `--strict`.
