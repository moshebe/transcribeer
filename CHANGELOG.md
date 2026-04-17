# Changelog

All notable changes are documented here.



## chore/add-swiftlint-configuration

Added comprehensive SwiftUI code quality enforcement, expanded LLM backend support, and significantly enhanced the GUI application with streaming summaries and live progress tracking (#2). Introduced a new SwiftUI design principles agent skill to guide polished UI development, integrated Gemini and Vertex AI as summarization backends alongside existing providers, and rebuilt core services (PipelineRunner, TranscriptionService, SummarizationService) to support real-time streaming output and improved state management. The GUI now features live session summaries with markdown rendering, enhanced settings UI for prompt management, detailed transcription progress visualization, and improved diarization service integration, while a new linting workflow enforces SwiftUI conventions across the codebase via SwiftLint configuration.

## docs/add-swiftui-expert-skill

Added comprehensive agent skills for Swift development expertise with two new specialized skill frameworks (#1). The **SwiftUI Expert Skill** provides extensive guidance across 17 reference documents covering layouts, animations, state management, accessibility, performance optimization, and platform-specific patterns for macOS and iOS. The **Swift Testing Pro** skill delivers detailed best practices for writing modern Swift Testing code, including async test patterns, migration guidance from XCTest, and core testing conventions aligned with Swift 6.2+. Both skills include OpenAI agent configuration and visual assets, enabling AI assistants to provide expert-level code reviews and testing recommendations within the agent ecosystem.
