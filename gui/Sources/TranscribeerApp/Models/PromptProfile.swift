import Foundation

/// Manages prompt profiles from ~/.transcribeer/prompts/.
///
/// A "profile" is a markdown file whose contents become the system prompt for
/// the summarizer. `default` is a synthetic profile — it maps to the built-in
/// prompt in `SummarizationService.defaultPrompt` and cannot be edited or
/// deleted from disk.
enum PromptProfileManager {
    static let defaultName = "default"

    // MARK: - Paths

    static var promptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/prompts")
    }

    static func fileURL(for name: String) -> URL {
        promptsDir.appendingPathComponent("\(name).md")
    }

    // MARK: - Listing

    /// Return available profile names. `default` is always first.
    static func listProfiles() -> [String] {
        var profiles = [defaultName]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: promptsDir, includingPropertiesForKeys: nil
        ) else { return profiles }

        let extras = contents
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != defaultName }
            .sorted()
        profiles.append(contentsOf: extras)
        return profiles
    }

    // MARK: - Read / Write / Delete

    /// Read the prompt text for a profile. Returns nil for `default` (caller
    /// should fall back to `SummarizationService.defaultPrompt`).
    static func readContent(name: String) -> String? {
        guard name != defaultName else { return nil }
        return try? String(contentsOf: fileURL(for: name), encoding: .utf8)
    }

    /// Create or update a profile. Throws on invalid name / IO errors.
    static func save(name: String, content: String) throws {
        let trimmed = try validateName(name)
        try FileManager.default.createDirectory(
            at: promptsDir, withIntermediateDirectories: true
        )
        try content.write(to: fileURL(for: trimmed), atomically: true, encoding: .utf8)
    }

    /// Rename a profile on disk. Default cannot be renamed.
    static func rename(from oldName: String, to newName: String) throws {
        guard oldName != defaultName else { throw ProfileError.invalidName("reserved") }
        let trimmed = try validateName(newName)
        if oldName == trimmed { return }
        let dst = fileURL(for: trimmed)
        if FileManager.default.fileExists(atPath: dst.path) {
            throw ProfileError.alreadyExists(trimmed)
        }
        try FileManager.default.moveItem(at: fileURL(for: oldName), to: dst)
    }

    /// Delete a profile on disk. Default is a no-op (not a file).
    static func delete(name: String) throws {
        guard name != defaultName else { return }
        try FileManager.default.removeItem(at: fileURL(for: name))
    }

    // MARK: - Validation

    /// Return a user-facing error for an invalid name, or nil if it's usable.
    /// `existing` lets callers surface collision warnings without hitting disk.
    static func validationError(for name: String, existing: [String] = []) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed == defaultName { return "\"default\" is reserved." }
        if existing.contains(trimmed) {
            return "A profile with this name already exists."
        }
        if trimmed.rangeOfCharacter(from: invalidNameChars) != nil {
            return #"Name can't contain / \ : ? * " < > |"#
        }
        return nil
    }

    /// Trim and validate a profile name, throwing `ProfileError` on failure.
    private static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.invalidName("empty") }
        guard trimmed != defaultName else { throw ProfileError.invalidName("reserved") }
        guard trimmed.rangeOfCharacter(from: invalidNameChars) == nil else {
            throw ProfileError.invalidName("disallowed characters")
        }
        return trimmed
    }

    // MARK: - Presets

    struct Preset: Identifiable, Hashable {
        let id: String          // slug / filename
        let title: String       // display title
        let description: String // short subtitle
        let content: String     // markdown body
    }

    /// Curated starter profiles. Inspired by common meeting types (1:1,
    /// standup, customer discovery, user interview, sales, retro, etc.) —
    /// each one is a self-contained markdown prompt that replaces the default
    /// summarizer instructions.
    static let presets: [Preset] = [
        Preset(
            id: "1on1",
            title: "1:1",
            description: "Manager / direct-report check-in",
            content: Self.builtin1on1
        ),
        Preset(
            id: "standup",
            title: "Standup",
            description: "Daily team sync — yesterday / today / blockers",
            content: Self.builtinStandup
        ),
        Preset(
            id: "customer-discovery",
            title: "Customer discovery",
            description: "Early customer research call",
            content: Self.builtinCustomerDiscovery
        ),
        Preset(
            id: "user-interview",
            title: "User interview",
            description: "Qualitative research session",
            content: Self.builtinUserInterview
        ),
        Preset(
            id: "sales-call",
            title: "Sales call",
            description: "Discovery / pitch with a prospect",
            content: Self.builtinSalesCall
        ),
        Preset(
            id: "job-interview",
            title: "Job interview",
            description: "Candidate evaluation",
            content: Self.builtinJobInterview
        ),
        Preset(
            id: "product-review",
            title: "Product review",
            description: "Feature / roadmap review",
            content: Self.builtinProductReview
        ),
        Preset(
            id: "retro",
            title: "Sprint retro",
            description: "What went well / didn't / next",
            content: Self.builtinRetro
        ),
        Preset(
            id: "investor-update",
            title: "Investor update",
            description: "Metrics, progress, asks",
            content: Self.builtinInvestorUpdate
        ),
        Preset(
            id: "brainstorm",
            title: "Brainstorm",
            description: "Ideation session — ideas + themes",
            content: Self.builtinBrainstorm
        ),
    ]

    // MARK: - Errors

    enum ProfileError: LocalizedError {
        case invalidName(String)
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case let .invalidName(reason): "Invalid profile name (\(reason))."
            case let .alreadyExists(name): "A profile named \"\(name)\" already exists."
            }
        }
    }

    private static let invalidNameChars: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\:?*\"<>|")
        set.formUnion(.controlCharacters)
        set.formUnion(.newlines)
        return set
    }()
}

// MARK: - Built-in preset bodies

extension PromptProfileManager {
    fileprivate static let builtin1on1 = """
        You are summarizing a 1:1 meeting between a manager and a direct report.
        Produce a concise markdown summary in the transcript's language:

        - **Overview** — 2–3 sentences on the tone and themes of the conversation.
        - **Updates** — what the report has been working on; wins and blockers.
        - **Feedback** — feedback given or received (both directions).
        - **Career / growth** — any mention of goals, development, or next steps.
        - **Action items** — who owns each one, with a due date if mentioned.
        - **Follow-ups for next 1:1** — open threads to revisit.

        Keep it direct and specific — quote numbers, names, and commitments verbatim.
        """

    fileprivate static let builtinStandup = """
        You are summarizing a team standup. Produce a compact markdown summary:

        - **Per-person updates** — one bullet per speaker with:
          - Yesterday: what shipped / progressed.
          - Today: focus for the day.
          - Blockers: anything stuck, including who can unblock.
        - **Cross-team dependencies** — explicit hand-offs or waits.
        - **Decisions made** — include who decided.
        - **Action items** — owner + what + when.

        Be terse. Skip pleasantries. Preserve speaker names exactly.
        """

    fileprivate static let builtinCustomerDiscovery = """
        You are summarizing a customer discovery call. The goal is to surface \
        evidence about the customer's problem, context, and buying behaviour — \
        not to pitch. Produce markdown with:

        - **About them** — company, role, team size, relevant context.
        - **Problem** — what they are trying to do today and where it breaks. \
          Quote the customer verbatim where possible.
        - **Current solution** — tools / processes they use now and what's painful.
        - **Jobs to be done** — underlying goals behind the workflow.
        - **Willingness to pay / buying process** — budget, decision-makers, timeline.
        - **Quotes** — 3–5 memorable customer quotes, attributed.
        - **Open questions / follow-ups** — things to learn on the next call.

        Favour the customer's words over paraphrase.
        """

    fileprivate static let builtinUserInterview = """
        You are summarizing a qualitative user interview. Stay close to the \
        user's own language and avoid editorialising. Produce markdown:

        - **Participant** — role, context, any screening criteria hit.
        - **Goals** — what they were trying to achieve.
        - **Workflow** — step-by-step how they get it done today.
        - **Pain points** — friction, workarounds, emotional reactions.
        - **Desires** — what "better" looks like in their words.
        - **Notable quotes** — 3–5 quotes with attribution and timestamp if present.
        - **Hypotheses to test** — what this interview suggests to validate next.

        Focus more on what the user said than what the interviewer said.
        """

    fileprivate static let builtinSalesCall = """
        You are summarizing a sales call with a prospect. Produce markdown:

        - **Account** — company, industry, headcount, key stakeholders on call.
        - **Pain / trigger** — why they are evaluating now.
        - **Current stack** — tools in place and what isn't working.
        - **Requirements** — must-haves, nice-to-haves, dealbreakers.
        - **Budget & timeline** — $ range, decision date, procurement steps.
        - **Decision process** — champions, blockers, other vendors considered.
        - **Objections** — concerns raised and how they were addressed.
        - **Next steps** — owner, action, date.

        Be specific with numbers and names. Call out risks explicitly.
        """

    fileprivate static let builtinJobInterview = """
        You are summarizing a job interview. Neutral, evidence-based. Produce \
        markdown:

        - **Candidate** — name, role applied for, round.
        - **Background** — relevant experience highlighted.
        - **Technical signals** — concrete examples of skill (or gaps).
        - **Behavioural signals** — communication, collaboration, ownership.
        - **Questions candidate asked** — what they wanted to understand.
        - **Strengths**
        - **Concerns**
        - **Recommendation** — hire / no hire / follow up, with rationale.

        Stick to observed evidence — avoid speculation about the person.
        """

    fileprivate static let builtinProductReview = """
        You are summarizing a product review meeting. Produce markdown:

        - **What was reviewed** — feature / release / prototype.
        - **Demo highlights** — what was shown, in order.
        - **Feedback** — grouped by theme (UX, performance, scope, etc.).
        - **Open questions** — unresolved design or product decisions.
        - **Decisions** — what was decided and by whom.
        - **Action items** — owner, task, due date.
        - **Risks** — anything flagged as potentially blocking launch.
        """

    fileprivate static let builtinRetro = """
        You are summarizing a sprint retrospective. Produce markdown:

        - **What went well** — wins the team wants to keep doing.
        - **What didn't** — frustrations, misses, and their root causes.
        - **What to try** — concrete experiments for next sprint.
        - **Action items** — owner, task, when to check in.
        - **Themes** — recurring patterns across bullets.

        Capture the team's own wording. Don't soften criticism.
        """

    fileprivate static let builtinInvestorUpdate = """
        You are summarizing an investor update meeting. Produce markdown:

        - **Headline** — 1–2 sentence summary of where the company is.
        - **Metrics** — revenue, growth, burn, runway, hiring — quote numbers.
        - **Progress since last update** — shipped / learned / hired.
        - **Challenges** — honest account of what's hard right now.
        - **Asks** — intros, hires, feedback requested.
        - **Next milestones** — what to watch for next quarter.

        Keep the tone factual and numerical.
        """

    fileprivate static let builtinBrainstorm = """
        You are summarizing a brainstorm session. Produce markdown:

        - **Prompt / question** — what the group was exploring.
        - **Ideas** — every idea raised, grouped by theme. Preserve the \
          originator's phrasing where possible.
        - **Themes** — recurring patterns across ideas.
        - **Top picks** — ideas the group rallied around.
        - **Next steps** — who will do what to validate or prototype.

        Be generous — include partial ideas. Don't prematurely filter.
        """
}
