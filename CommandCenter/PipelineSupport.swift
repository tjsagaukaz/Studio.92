// PipelineSupport.swift
// CommandCenter
//
// Pipeline data models and thread-safe helpers.

import Foundation
import AgentCouncil

struct PacketSummary: Codable {

    struct Payload: Codable {
        struct ASTDelta: Codable {
            var delta: String
            var targetFile: String
            var isNewFile: Bool
            var affectedTypes: [String]?
        }

        var rationale: String
        var targetFile: String
        var isNewFile: Bool
        var archetypeClassification: ArchetypeInfo?
        var diffText: String?
        var affectedTypes: [String]

        struct ArchetypeInfo: Codable {
            var dominant: String
            var confidence: Double
        }

        enum CodingKeys: String, CodingKey {
            case rationale
            case targetFile
            case isNewFile
            case archetypeClassification
            case diffText
            case affectedTypes
            case astDelta
        }

        init(
            rationale: String,
            targetFile: String,
            isNewFile: Bool,
            archetypeClassification: ArchetypeInfo?,
            diffText: String?,
            affectedTypes: [String]
        ) {
            self.rationale = rationale
            self.targetFile = targetFile
            self.isNewFile = isNewFile
            self.archetypeClassification = archetypeClassification
            self.diffText = diffText
            self.affectedTypes = affectedTypes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
            archetypeClassification = try container.decodeIfPresent(ArchetypeInfo.self, forKey: .archetypeClassification)

            let delta = try container.decodeIfPresent(ASTDelta.self, forKey: .astDelta)
            targetFile = try container.decodeIfPresent(String.self, forKey: .targetFile)
                ?? delta?.targetFile
                ?? ""
            isNewFile = try container.decodeIfPresent(Bool.self, forKey: .isNewFile)
                ?? delta?.isNewFile
                ?? false
            diffText = try container.decodeIfPresent(String.self, forKey: .diffText)
                ?? delta?.delta
            affectedTypes = try container.decodeIfPresent([String].self, forKey: .affectedTypes)
                ?? delta?.affectedTypes
                ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rationale, forKey: .rationale)
            try container.encode(targetFile, forKey: .targetFile)
            try container.encode(isNewFile, forKey: .isNewFile)
            try container.encodeIfPresent(archetypeClassification, forKey: .archetypeClassification)
            try container.encodeIfPresent(diffText, forKey: .diffText)
            if !affectedTypes.isEmpty {
                try container.encode(affectedTypes, forKey: .affectedTypes)
            }
        }
    }

    struct Metrics: Codable {
        var higComplianceScore: Double
        var deviationBudgetCost: Double
    }

    var packetID: UUID
    var sender: String
    var intent: String
    var scope: String
    var payload: Payload
    var metrics: Metrics

    /// Validate required fields and metric ranges before persistence.
    func validate() -> String? {
        if payload.targetFile.isEmpty { return "Missing targetFile" }
        guard (0...1).contains(metrics.higComplianceScore) else { return "higComplianceScore out of range" }
        guard (0...1).contains(metrics.deviationBudgetCost) else { return "deviationBudgetCost out of range" }
        return nil
    }
}

// MARK: - PipelineError

/// Simple error wrapper for pipeline operations.
struct PipelineError: Error, Sendable {
    let message: String
}

// MARK: - PipelineRunner

/// Drives the Dark Factory pipeline via Process.
/// Surfaces status + blockers only — no log storage.
final class LockedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) -> [String] {
        lock.lock()
        buffer += chunk

        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newlineIndex]))
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
        }
        lock.unlock()
        return lines
    }

    func flushTrailing() -> String {
        lock.lock()
        let trailing = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        return trailing
    }
}

final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let data = buffer
        lock.unlock()
        return data
    }
}

final class ProcessContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func finish(_ body: () -> Void) {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        lock.unlock()
        body()
    }
}

struct PipelineLightweightReplier {

    struct PlannedReply {
        let text: String
        let delay: Duration
    }

    static func planReply(
        for goal: String,
        attachments: [ChatAttachment]
    ) -> PlannedReply? {
        guard attachments.isEmpty else { return nil }

        let normalized = normalizedCue(from: goal)
        guard !normalized.isEmpty else { return nil }

        let greetings: Set<String> = [
            "hi",
            "hi there",
            "hello",
            "hello there",
            "hey",
            "hey there",
            "hiya",
            "yo",
            "sup",
            "whats up",
            "good morning",
            "good afternoon",
            "good evening"
        ]

        let tokens = normalized.split(whereSeparator: \.isWhitespace)
        let shortGreetingPrefixes: Set<String> = [
            "hi",
            "hello",
            "hey",
            "hiya",
            "yo",
            "sup"
        ]
        let extendedGreetingPhrases: Set<String> = [
            "good morning",
            "good afternoon",
            "good evening",
            "whats up"
        ]

        let isShortGreeting = tokens.count <= 3
            && tokens.first.map { shortGreetingPrefixes.contains(String($0)) } == true
        let isExtendedGreeting = tokens.count <= 4
            && extendedGreetingPhrases.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }

        if greetings.contains(normalized) || isShortGreeting || isExtendedGreeting {
            return PlannedReply(
                text: "Hey. Ready when you are. Tell me what you want to build, fix, or review.",
                delay: delay(for: normalized)
            )
        }

        let gratitude: Set<String> = [
            "thanks",
            "thank you",
            "thx",
            "ty",
            "awesome thanks",
            "perfect thanks"
        ]

        let gratitudePrefixes: Set<String> = [
            "thanks",
            "thank",
            "thx",
            "ty"
        ]
        let isShortGratitude = tokens.count <= 4
            && tokens.first.map { gratitudePrefixes.contains(String($0)) } == true

        if gratitude.contains(normalized) || isShortGratitude {
            return PlannedReply(
                text: "Anytime. Tell me what you want to tackle next.",
                delay: delay(for: normalized)
            )
        }

        let readinessChecks: Set<String> = [
            "are you there",
            "you there",
            "ready",
            "ready now",
            "ping"
        ]

        let readinessPrefixes: Set<String> = [
            "are you there",
            "you there",
            "ready"
        ]
        let isShortReadinessCheck = tokens.count <= 4
            && readinessPrefixes.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }

        if readinessChecks.contains(normalized) || isShortReadinessCheck {
            return PlannedReply(
                text: "I'm here. Tell me what you want to build, fix, or review.",
                delay: delay(for: normalized)
            )
        }

        return nil
    }

    private static func normalizedCue(from goal: String) -> String {
        let lowered = goal.lowercased()
        let cleanedScalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return String(cleanedScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func delay(for normalizedGoal: String) -> Duration {
        let checksum = normalizedGoal.unicodeScalars.reduce(0) { partialResult, scalar in
            (partialResult + Int(scalar.value)) % 180
        }
        return .milliseconds(620 + checksum)
    }
}

enum PipelineMemoryPackStager {

    static let orchestrationEscalationSignals = [
        "refactor",
        "rewrite",
        "re-architect",
        "rearchitect",
        "architecture",
        "migrate",
        "migration",
        "audit",
        "deep review",
        "system-wide",
        "cross-cutting",
        "across the app",
        "across the project",
        "multi-file",
        "large",
        "major",
        "overhaul",
        "stabilize",
        "untangle"
    ]

    struct PreparedAgenticUserInput {
        let userMessage: String
        let userContentBlocks: [[String: Any]]?
        let hasVisualReference: Bool
        let multimodalPreset: MultimodalPreset?
        let extractorSchema: ExtractorSchema?
    }

    struct AgenticRequestProfile {
        let effort: String
        let verbosity: String?
        let thinking: [String: Any]?
        let tools: [[String: Any]]
        let allowedToolNames: [String]?
        let responseFormat: [String: Any]?
    }

    private static let fallbackOperatingRules: [String] = [
        "Treat Git as the source of truth. Use isolated worktrees for long-running, risky, or parallel tasks.",
        "Prefer SwiftUI and native Apple frameworks unless the task clearly requires something else.",
        "Always use live research when the request depends on current Apple SDK changes, App Store Review Guidelines, privacy manifests, entitlements, signing, TestFlight behavior, or App Store Connect rules.",
        "Build and verify real code. Do not stop at a plan when code changes are clearly requested.",
        "Surface concrete ship blockers first: signing, entitlements, privacy manifests, bundle identifiers, icons, screenshots, metadata, failing builds, and policy issues.",
        "Keep outputs concise, grounded, and diff-oriented."
    ]

    private static let agentsRoleMapping: [String: StudioModelRole] = [
        "plan": .review,
        "review": .review,
        "full send": .fullSend,
        "subagents": .subagent,
        "background worktrees": .subagent,
        "standards research": .subagent,
        "escalation": .escalation,
        "escalation only": .escalation,
        "explorer": .explorer,
    ]

    static func missingModelCredentialMessage(
        for model: StudioModelDescriptor
    ) -> String {
        let modeLine = "\(model.displayName) is the active model."
        let providerLine = "Add \(model.provider.environmentVariableName) in Settings, or export it in the app environment."
        return "\(modeLine) \(providerLine)"
    }

    static func latestAppleAPIContext(from directory: URL?) -> String {
        guard let directory else { return "" }
        let url = directory.appendingPathComponent("context_pack.txt")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func agenticSystemPrompt(
        projectRoot: String,
        model: StudioModelDescriptor? = nil,
        hasVisualReference: Bool = false,
        researcherOutputDir: URL? = nil,
        routingReason: String = "default",
        memoryPack: MemoryPack? = nil,
        runtimePolicy: CommandRuntimePolicy? = nil
    ) -> String {
        let latestContext = latestAppleAPIContext(from: researcherOutputDir)
        let temporalContext = currentTemporalContext()
        let operatingRulesSection = resolveOperatingRules(projectRoot: projectRoot)
        let executionPolicySection = runtimePolicy?.promptSection ?? ""
        let latestContextSection = latestContext.isEmpty
            ? ""
            : """

            ### LATEST APPLE API CONTEXT (USE THIS STRICTLY) ###
            \(latestContext)
            """

        let autonomySection: String = {
            let isReviewRoute = model?.role == .review || routingReason == "review_escalation"
            let isDeepReview = routingReason == "review_escalation"

            guard !isReviewRoute else {
                if isDeepReview {
                    return """

            ### ROLE: DEEP AUDITOR ###
            You are a principal-level Apple-platform engineer performing a high-stakes code audit.
            Your job is not to review everything — your job is to find what actually matters.

            DEEP AUDIT MODE
            - Go deeper than a surface review. Check assumptions. Verify cross-file interactions.
            - Reason about runtime behavior, not just syntax. Trace state through lifecycle events.
            - When reviewing concurrency, verify actor isolation boundaries, Sendable correctness, and potential data races across the call graph — not just within a single file.
            - When reviewing SwiftUI, check view identity stability, state ownership correctness (@State vs @StateObject vs @ObservedObject), and lifecycle ordering.
            - When reviewing persistence (SwiftData/CoreData), verify thread safety, relationship consistency, and migration paths.

            REVIEW STANDARDS
            - Ground findings in what the code actually does, not what you assume it should do.
            - Every point must either identify a real issue or provide a meaningful improvement.
            - Distinguish clearly between:
              - 🔴 Broken (incorrect behavior)
              - 🟠 Risky (can fail under conditions)
              - 🟡 Improvement (optional but valuable)
            - If unsure, mark as "⚠️ Needs Verification". Do not present uncertain claims as facts.
            - Describe fixes in plain language (e.g. "move the state to the parent view", "add actor isolation to this property"). Do NOT include code blocks or patches in your response.
            - If more than 5 findings exist, show only the highest-impact ones.
            - If the code is solid, say so and stop. Do not invent issues.

            OUTPUT FORMAT
            Write your audit as clean, readable prose. Use emojis for severity and section headers.
            1. 📋 Verdict (1–2 sentences)
            2. 🔴 Critical Issues (if any)
            3. 🟠 High-Risk Issues
            4. 🟡 Medium Issues (optional)
            5. 💡 Improvements (optional)

            Each finding: a short title, severity emoji, why it matters, where it is (file + function name), and what to do about it — all in natural language. No code fences.

            VOICE
            Direct, technical, precise. No filler. No code blocks.

            IMPORTANT: Your full analysis and all findings MUST appear in your response text.
            Do not put your analysis only in extended thinking / reasoning. The user sees your
            response text as the primary output — thinking is collapsed by default. Surface
            every finding, verdict, and recommendation in the response body.
            """
                }
                return """

            ### ROLE: REVIEWER ###
            You are a senior Apple-platform engineer conducting a focused audit.

            Read the provided files through the requested focus area. Surface real findings — bugs, correctness issues, concurrency hazards, API misuse, performance risks, and architectural concerns. Describe what you find and how to fix it in plain language. Do NOT include code blocks, patches, or code fences in your response. Skip nitpicks and style preferences unless they cause real problems.

            REVIEW STANDARDS
            - Ground findings in what the code actually does, not what you assume it should do.
            - Do not restate what the code is doing unless it directly supports a finding.
            - Describe fixes in natural language (e.g. "wrap the mutation in a MainActor.run block", "replace the forced unwrap with a guard-let"). No code blocks.
            - Distinguish between 🔴 "this is broken" and 🟠 "this is risky" — be clear about severity.
            - If you are not confident in a finding, mark it as "⚠️ Needs Verification". Do not present uncertain claims as facts.
            - Check nearby files for context before concluding something is missing or misused.
            - When reviewing SwiftUI, pay attention to identity, state ownership, animation correctness, and view lifecycle.
            - When reviewing concurrency, check actor isolation, Sendable conformance, and data races.
            - When you see a clear improvement — a simpler approach, a removed footgun, a better pattern — propose it.
            - If there are more than 5 findings, prioritize the highest impact ones.
            - If the code is solid, say so and stop. Do not invent issues to fill space.

            ESCALATION RULE
            If this review involves system-wide architecture, deep concurrency concerns, or cross-cutting state management that requires tracing behavior across many files — say so clearly in your verdict. State: "This review would benefit from a deep audit" and explain why.

            OUTPUT FORMAT
            Write your audit as clean, readable prose. Use emojis for severity and section headers.
            1. 📋 Verdict (1–2 sentences)
            2. 🔴 Critical Issues (if any)
            3. 🟠 High-Risk Issues
            4. 🟡 Medium Issues (optional)
            5. 💡 Improvements (optional)

            Each finding: a short title, severity emoji, why it matters, where it is (file + function name), and what to do about it — all in natural language. No code fences.

            VOICE
            Talk like yourself. Be direct, be technical, be honest. If something is wrong, say it's wrong. If something is fine, don't manufacture concerns to fill space. No code in the response.

            IMPORTANT: Your full analysis and all findings MUST appear in your response text.
            Do not put your analysis only in extended thinking / reasoning. The user sees your
            response text as the primary output — thinking is collapsed by default. Surface
            every finding, verdict, and recommendation in the response body.
            """
            }
            return """

            ### AUTONOMY ###
            You have full autonomy. Inspect, edit, build, verify, and deploy as needed.
            Persist until the task is fully handled end-to-end within the current turn whenever feasible.
            Unless the user explicitly asks for a plan or is brainstorming, assume they want you to make code changes or run tools to solve the problem.
            If you encounter challenges, attempt to resolve them yourself.
            \(model?.role == .escalation ? """

            ### ESCALATION CONTEXT ###
            You are the strongest model in the system, called for hard problems: system-wide refactors, deep architecture decisions, ambiguous multi-step chains, and tasks that lighter models couldn't resolve. Take your time, reason deeply, and be thorough. Don't rush.
            """ : "")
            """
        }()

        let visionDirective = hasVisualReference
            ? """

            ### VISION DIRECTIVE ###
            You have been provided with a visual reference. You are a master Apple HIG UI/UX engineer. Analyze the attached interface. Recreate this exact visual hierarchy, layout, and aesthetic using native SwiftUI. Infer paddings, corner radii, and semantic colors (using Apple standard gray/system colors where appropriate). Do not use placeholder geometry; write the production-ready view structure.
            """
            : ""

        let gpt54GuidanceSection: String = {
            guard let model, model.provider == .openAI,
                  model.identifier.hasPrefix("gpt-5") else { return "" }
            return """

            <execution_discipline>
            - Use tools when they materially improve correctness. Stop once the task is complete.
            - Resolve prerequisite lookups before acting. Do not skip discovery steps.
            - Track all requested deliverables. Mark any blocked item with what is missing.
            - Before finalizing: verify correctness, grounding, formatting, and safety.
            - If a lookup returns empty, try one fallback strategy before reporting no results.
            - Prefer parallel tool calls for independent retrievals. Synthesize before continuing.
            - Use edit tools directly — not shell workarounds. Run builds or tests after changes.
            </execution_discipline>
            """
        }()

        let isReviewModel = model?.role == .review || routingReason == "review_escalation"

        let toolStrategySection: String = {
            if isReviewModel {
                let deepAuditAddendum = routingReason == "review_escalation"
                    ? "\n    - You have full tool access. When you find issues, verify them by reading related files and tracing the call graph."
                    : ""
                return """
        Tool Strategy:
        - Use `file_read` and `list_files` to inspect the codebase. Start narrow, broaden as needed.
        - Use `terminal` to run builds or tests when verification would strengthen your analysis.
        - Use `web_search` for current Apple docs, HIG, or API references when correctness depends on it.
        - Use `file_patch` for focused fixes and `file_write` when creating or replacing files. When you find something worth fixing and the fix is clear, apply it.
        - Never claim you inspected something unless a tool result proves it.\(deepAuditAddendum)
        """
            }
            return """
        Tool Strategy:
        - Use tools when they reduce guesswork. Prefer grounded action over speculation.
        - Start narrow. Do not scan or read the whole repository by default.

        File Tools:
        - Use `list_files` to orient, then `file_read` on specific targets. Broaden only when the first read proves insufficient.
        - Use `file_patch` for surgical edits to existing files. Use `file_write` only when creating new files or replacing entire file contents.
        - Do not inspect unrelated shared libraries, design systems, or framework folders unless the request clearly depends on them.

        Terminal:
        - Use `terminal` for builds, tests, git operations, and any task that requires shell state or process output.
        - Prefer `terminal` over file tools when you need to check build status, run tests, or verify changes end-to-end.

        Delegation:
        - Use `delegate_to_explorer` when you need broad read-only context across multiple files before writing. Best for architecture discovery or usage searches.
        - Use `delegate_to_reviewer` for audits or code quality passes. Read the relevant files yourself first, then hand them to the reviewer with a clear focus area.
        - Delegated workers are internal specialists. Use them to reduce main-context noise, then absorb their findings and continue.

        Research:
        - Use `web_search` only when correctness depends on current external information — Apple SDK changes, API docs, HIG updates, App Store policies.
        - Do not web-search for information already in context or well-established.

        Grounding:
        - Never claim you changed, verified, or inspected something unless a tool result proves it.
        """
        }()

        let memorySection: String = {
            guard let memoryPack else { return "" }
            return "\n\n" + memoryPack.renderForPrompt()
        }()

        return """
        You are Studio.92, a senior Apple platforms engineer working directly inside a real local workspace at \(projectRoot).
        \(temporalContext)

        <execution_layer>

        \(toolStrategySection)

        <response_priority>
        - Answer the user's question directly FIRST before using tools.
        - If the answer is obvious from context, state it immediately — do not call tools just to confirm what you already know.
        - Only reach for tools when they add information you genuinely lack.
        </response_priority>

        <planning>
        - When asked to build or change a feature, begin with a concise markdown checklist using `- [ ] Task`.
        - Prefer executing over planning. If the task is clear, skip the plan and start building.
        </planning>

        <loop_discipline>
        - Stop calling tools once the task is complete.
        - Prefer targeted reads, but re-read files when new context changes your understanding.
        - If you need to explore broadly to do thorough work, explore broadly.
        </loop_discipline>

        <output_integrity>
        - The UI already shows file operations and terminal activity. Do not announce routine reads, scans, or commands in prose.
        - After tool work, summarize what changed, what you verified, and any meaningful caveats.
        - Do not dump raw file inventories, path lists, or verification transcripts unless the user explicitly asks.
        - Do not mention hidden orchestration, councils, or internal agent roles.
        </output_integrity>

        </execution_layer>
        \(operatingRulesSection)
        \(executionPolicySection)
        \(autonomySection)
        \(visionDirective)
        \(gpt54GuidanceSection)
        \(latestContextSection)
        \(memorySection)
        """
    }

    private static func resolveOperatingRules(projectRoot: String) -> String {
        let manifest = AGENTSParser.parse(projectRoot: URL(fileURLWithPath: projectRoot))
        let rules = manifest.operatingRules.isEmpty ? fallbackOperatingRules : manifest.operatingRules
        let formatted = rules.map { "- \($0)" }.joined(separator: "\n")
        return """

        ### OPERATING RULES (from AGENTS.md) ###
        \(formatted)
        """
    }

    static func validateModelRoles(
        packageRoot: String,
        tracer: TraceCollector,
        parentSpanID: UUID
    ) async {
        let manifest = AGENTSParser.parse(projectRoot: URL(fileURLWithPath: packageRoot))
        guard !manifest.modelRoles.isEmpty else { return }

        let spanID = await tracer.begin(
            kind: .permissionCheck,
            name: "agents_md_model_validation",
            parentID: parentSpanID,
            attributes: ["source": "AGENTS.md"]
        )

        var warnings: [String] = []

        for (roleName, declaredModel) in manifest.modelRoles {
            let key = roleName.lowercased().trimmingCharacters(in: .whitespaces)
            guard let role = agentsRoleMapping[key] else { continue }

            let resolved = StudioModelStrategy.descriptor(for: role, packageRoot: packageRoot)
            let resolvedTokens = normalizedModelIdentifierTokens(from: resolved.identifier)
            let declaredTokens = normalizedModelIdentifierTokens(from: declaredModel)

            if !modelIdentifierTokensAlign(resolvedTokens, declaredTokens) {
                warnings.append("\(roleName): AGENTS.md declares '\(declaredModel)' but ship.toml resolves '\(resolved.identifier)'")
            }
        }

        if warnings.isEmpty {
            await tracer.setAttribute("result", value: "aligned", on: spanID)
            await tracer.end(spanID)
        } else {
            await tracer.setAttribute("result", value: "drift_detected", on: spanID)
            await tracer.setAttribute("warnings", value: warnings.joined(separator: "; "), on: spanID)
            await tracer.end(spanID, error: "Model role drift: \(warnings.count) mismatch(es)")
        }
    }

    private static func normalizedModelIdentifierTokens(from identifier: String) -> [String] {
        identifier
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func modelIdentifierTokensAlign(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return numericSuffixOnlyPrefixMatch(lhs, rhs) || numericSuffixOnlyPrefixMatch(rhs, lhs)
    }

    private static func numericSuffixOnlyPrefixMatch(_ longer: [String], _ shorter: [String]) -> Bool {
        guard longer.count > shorter.count else { return false }
        guard Array(longer.prefix(shorter.count)) == shorter else { return false }
        return longer.dropFirst(shorter.count).allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func currentTemporalContext() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = .long
        formatter.timeStyle = .none

        let currentDate = formatter.string(from: Date())
        let currentTimeZone = TimeZone.autoupdatingCurrent.identifier

        return """
        ### REAL-TIME CONTEXT ###
        Current date: \(currentDate)
        Timezone: \(currentTimeZone)
        Always use this when reasoning about dates, recency, schedules, releases, deadlines, trends, or relative references such as today, tomorrow, and yesterday.
        Do not assume stale timelines.
        """
    }

    static func agenticRequestProfile(
        for goal: String,
        attachments: [ChatAttachment],
        conversationHistory: [ConversationHistoryTurn],
        model: StudioModelDescriptor,
        runtimePolicy: CommandRuntimePolicy,
        hasVisualReference: Bool,
        multimodalPreset: MultimodalPreset? = nil,
        extractorSchema: ExtractorSchema? = nil
    ) -> AgenticRequestProfile {
        let normalizedGoal = goal.lowercased()
        let referencesFileCount = attachments.filter { !$0.isImage }.count
        let imageReferenceCount = attachments.filter(\.isImage).count
        let hasEscalationSignal = Self.orchestrationEscalationSignals.contains { normalizedGoal.contains($0) }
        let hasWideContext = referencesFileCount >= 3 || imageReferenceCount >= 2 || conversationHistory.count >= 8

        let shouldUseAdaptiveThinking = model.provider == .anthropic
            && (
                model.role == .escalation
                || hasEscalationSignal
                || hasWideContext
                || hasVisualReference
                || referencesFileCount > 0
                || imageReferenceCount > 0
            )

        let presetShape = multimodalPreset.map { MultimodalRequestShape.shape(for: $0) }

        let effort: String = {
            if model.provider == .openAI, let shape = presetShape, let re = shape.reasoningEffort {
                return re
            }
            switch model.provider {
            case .anthropic:
                if model.role == .escalation {
                    return "high"
                }
                return "medium"
            case .openAI:
                return model.defaultReasoningEffort ?? "high"
            }
        }()

        let verbosity: String? = {
            guard model.provider == .openAI else { return nil }
            if let shape = presetShape, let v = shape.textVerbosity {
                return v
            }
            return model.defaultVerbosity ?? "medium"
        }()

        let isReviewRoute = model.role == .review
        var requestTools = isReviewRoute
            ? DefaultToolSchemas.reviewerTools
            : DefaultToolSchemas.all
        let allowedToolNames: [String]? = nil

        let responseFormat: [String: Any]? = {
            guard model.provider == .openAI else { return nil }
            if let extractorSchema {
                return [
                    "type": "json_schema",
                    "name": extractorSchema.rawValue,
                    "strict": true,
                    "schema": extractorSchema.jsonSchema
                ]
            }
            if multimodalPreset == .locateRegion {
                return [
                    "type": "json_schema",
                    "name": "bbox_locate",
                    "strict": true,
                    "schema": MultimodalEngine.bboxResponseSchema
                ]
            }
            return nil
        }()

        if responseFormat != nil {
            requestTools = requestTools.filter { ($0["type"] as? String) == "web_search" || ($0["type"] as? String) == "web_search_preview" }
        }

        requestTools = runtimePolicy.filteredTools(requestTools)

        return AgenticRequestProfile(
            effort: effort,
            verbosity: verbosity,
            thinking: shouldUseAdaptiveThinking ? ["type": "adaptive"] : nil,
            tools: requestTools,
            allowedToolNames: allowedToolNames,
            responseFormat: responseFormat
        )
    }

    static func prepareAgenticUserInput(
        goal: String,
        attachments: [ChatAttachment]
    ) async -> PreparedAgenticUserInput {
        guard let imageAttachment = attachments.first(where: { $0.isImage }) else {
            return PreparedAgenticUserInput(
                userMessage: goal,
                userContentBlocks: nil,
                hasVisualReference: false,
                multimodalPreset: nil,
                extractorSchema: nil
            )
        }

        let preset = imageAttachment.multimodalPreset
        let extractor = imageAttachment.extractorSchema

        if let preset {
            let shape = MultimodalRequestShape.shape(for: preset)
            if let imageBlock = await MultimodalEngine.imageContentBlock(
                from: imageAttachment.url,
                detail: shape.imageDetail,
                maxDimension: shape.maxImageDimension,
                compressionQuality: shape.compressionQuality
            ) {
                var textContent = goal
                if let extractor {
                    textContent += "\n\n" + extractor.extractionPrompt
                }
                if preset == .locateRegion || preset == .deepInspect {
                    textContent += "\n\nReturn bounding boxes as normalized 0..999 coordinates in JSON."
                }

                return PreparedAgenticUserInput(
                    userMessage: goal,
                    userContentBlocks: [
                        ["type": "input_text", "text": textContent],
                        imageBlock
                    ],
                    hasVisualReference: true,
                    multimodalPreset: preset,
                    extractorSchema: extractor
                )
            }
        }

        guard let imageBlock = await VisionPayloadBuilder.imageContentBlock(from: imageAttachment.url) else {
            return PreparedAgenticUserInput(
                userMessage: goal,
                userContentBlocks: nil,
                hasVisualReference: false,
                multimodalPreset: preset,
                extractorSchema: extractor
            )
        }

        return PreparedAgenticUserInput(
            userMessage: goal,
            userContentBlocks: [
                ["type": "text", "text": goal],
                imageBlock
            ],
            hasVisualReference: true,
            multimodalPreset: preset,
            extractorSchema: extractor
        )
    }

    static func statusMessage(forToolNamed name: String) -> String {
        switch name {
        case "file_read":
            return "Reading files..."
        case "file_write":
            return "Writing changes..."
        case "file_patch":
            return "Applying changes..."
        case "list_files":
            return "Inspecting the workspace..."
        case "delegate_to_explorer":
            return "Exploring the workspace..."
        case "delegate_to_reviewer":
            return "Auditing recent changes..."
        case "delegate_to_worktree":
            return "Spawning an isolated background job..."
        case "terminal":
            return "Running verification..."
        case "deploy_to_testflight":
            return "Deploying to TestFlight..."
        case "web_search":
            return "Searching for current guidance..."
        default:
            return "Working..."
        }
    }

    static func agenticHistoryPayload(from turns: [ConversationHistoryTurn]) -> [[String: Any]] {
        turns.map { turn in
            let role = turn.role == .user ? "user" : "assistant"

            if let contentBlocks = turn.contentBlocks, !contentBlocks.isEmpty {
                let encodedBlocks: [[String: Any]] = contentBlocks.compactMap { block in
                    switch block {
                    case .text(let text):
                        return ["type": "text", "text": text]
                    case .thinking(let text, let signature):
                        var payload: [String: Any] = [
                            "type": "thinking",
                            "thinking": text
                        ]
                        if let signature {
                            payload["signature"] = signature
                        }
                        return payload
                    }
                }

                return [
                    "role": role,
                    "content": encodedBlocks
                ]
            }

            return [
                "role": role,
                "content": turn.text
            ]
        }
    }

    static func compactionSafePayload(from turns: [ConversationHistoryTurn]) -> [[String: Any]] {
        turns.compactMap { turn in
            let role = turn.role == .user ? "user" : "assistant"
            let contentType = turn.role == .user ? "input_text" : "output_text"

            if let contentBlocks = turn.contentBlocks, !contentBlocks.isEmpty {
                let textBlocks: [[String: Any]] = contentBlocks.compactMap { block in
                    switch block {
                    case .text(let text):
                        return [
                            "type": contentType,
                            "text": text
                        ]
                    case .thinking:
                        return nil
                    }
                }
                guard !textBlocks.isEmpty else { return nil }

                return [
                    "role": role,
                    "content": textBlocks
                ]
            }

            return [
                "role": role,
                "content": [
                    [
                        "type": contentType,
                        "text": turn.text
                    ]
                ]
            ]
        }
    }
}

@MainActor
final class PipelineRunOrchestrator {

    private unowned let runner: PipelineRunner

    init(runner: PipelineRunner) {
        self.runner = runner
    }

    func run(
        goal: String,
        attachments: [ChatAttachment],
        anthropicAPIKey: String?,
        openAIKey: String?,
        selectedModel: StudioModelDescriptor,
        routingDecision: StudioModelStrategy.RoutingDecision,
        conversationHistory: [ConversationHistoryTurn],
        latencyRunID: String?,
        planContext: String? = nil,
        dagAssessment: TaskComplexityAnalyzer.ComplexityAssessment? = nil
    ) async {
        let tracer = TraceCollector()
        let runtimePolicy = CommandAccessPreferenceStore.shared.snapshot
        runner.activeTraceCollector = tracer
        runner.compactionCoordinator.configureForModel(selectedModel)
        runner.compactionCoordinator.setPipelineActive(true)
        runner.sessionInspector.observeLive(tracer)
        let sessionSpanID = await tracer.begin(
            kind: .session,
            name: "agentic_loop",
            attributes: [
                "model": selectedModel.identifier,
                "provider": selectedModel.provider.rawValue,
                "goal": String(goal.prefix(200)),
                "model.role": selectedModel.role.rawValue,
                "routing.reason": routingDecision.reason,
                "routing.signals": routingDecision.matchedSignals.joined(separator: ","),
                "task.attachment_count": String(attachments.count),
                "task.history_turns": String(conversationHistory.count),
                "policy.scope": runtimePolicy.accessScope.rawValue,
                "policy.approval": runtimePolicy.approvalMode.rawValue
            ]
        )
        runner.activeSessionSpanID = sessionSpanID

        if let dagAssessment {
            await tracer.setAttribute("dag.used", value: dagAssessment.shouldUseDAG ? "true" : "false", on: sessionSpanID)
            if dagAssessment.shouldUseDAG {
                await tracer.setAttribute("dag.reason", value: dagAssessment.reason, on: sessionSpanID)
                await tracer.setAttribute("dag.signals", value: dagAssessment.matchedSignals.joined(separator: ","), on: sessionSpanID)
                await tracer.setAttribute("dag.phases", value: dagAssessment.suggestedPhases.map(\.rawValue).joined(separator: ","), on: sessionSpanID)
            }
        }

        var activeToolSpans: [String: UUID] = [:]
        var activeToolStartTimes: [String: Date] = [:]
        var activeToolFirstOutputTimes: [String: Date] = [:]
        /// Tool call IDs that are sub-agent delegates — used to restore model label on completion.
        var activeDelegateToolIDs: Set<String> = []
        var toolCallCount = 0
        var llmIterationCount = 0

        let clientSetupStartedAt = CFAbsoluteTimeGetCurrent()
        runner.pendingBBoxOverlays = []
        runner.pendingBBoxSourceImageURL = nil

        let client = AgenticClient(
            apiKey: anthropicAPIKey,
            projectRoot: URL(fileURLWithPath: runner.packageRoot, isDirectory: true),
            openAIKey: openAIKey,
            runtimePolicy: runtimePolicy,
            permissionPolicy: runtimePolicy.permissionPolicy,
            allowMachineWideAccess: runtimePolicy.allowsMachineWideAccess
        )
        await client.recovery.setTracer(tracer)
        await client.recovery.resetCircuitBreaker()
        if let pack = runner.activeMemoryPack {
            await client.injectSubagentMemory(pack.renderForSubagent())
        }
        let clientSetupEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Agentic Client Setup",
            startedAt: clientSetupStartedAt,
            endedAt: clientSetupEndedAt,
            notes: "provider=\(selectedModel.provider.rawValue) model=\(selectedModel.identifier) policy=\(runtimePolicy.statusLine)"
        )

        await PipelineMemoryPackStager.validateModelRoles(
            packageRoot: runner.packageRoot,
            tracer: tracer,
            parentSpanID: sessionSpanID
        )

        let placeholderStartedAt = CFAbsoluteTimeGetCurrent()
        let messageID = {
            let message = ChatMessage(
                kind: .streaming,
                goal: goal,
                text: "",
                timestamp: Date(),
                screenshotPath: nil,
                metrics: nil,
                executionTree: nil,
                attachments: [],
                epochID: nil,
                packetID: nil,
                streamingText: "",
                isStreaming: true
            )
            runner.currentStreamingMessageID = message.id
            runner.currentRunMessageIDs.append(message.id)
            runner.chatThread.post(message)
            return message.id
        }()

        // When the coordinator detects a plan, swap the streaming chat message for a
        // viewport indicator card so the plan renders only in the Viewport pane.
        runner.streamCoordinator.onPlanDetected = { [weak self] in
            guard let self else { return }
            self.runner.chatThread.updateMessageContent(id: messageID) { msg in
                msg.kind = .planViewportCard
                msg.streamingText = ""
                msg.text = ""
                msg.isStreaming = false
            }
        }
        let placeholderEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Streaming Placeholder Bootstrap",
            startedAt: placeholderStartedAt,
            endedAt: placeholderEndedAt,
            notes: "message_id=\(messageID.uuidString)"
        )

        if let architectureAbortMessage = await runner.ingestArchitectureEvent(
            .beginRun(runID: tracer.traceID),
            tracer: tracer,
            sessionSpanID: sessionSpanID
        ) {
            runner.presentAgenticFailure(
                messageID: messageID,
                goal: goal,
                message: "Architecture violation detected. \(architectureAbortMessage)"
            )
            let residualOpenSpans = max(0, await tracer.activeSpanCount() - 1)
            _ = await runner.ingestArchitectureEvent(
                .traceSnapshot(openSpanCount: residualOpenSpans),
                tracer: tracer,
                sessionSpanID: sessionSpanID
            )
            await tracer.end(sessionSpanID, error: String(architectureAbortMessage.prefix(500)))
            await finalizeTraceSummary(from: tracer)
            return
        }

        let promptAssemblyStartedAt = CFAbsoluteTimeGetCurrent()
        let preparedInput = await PipelineMemoryPackStager.prepareAgenticUserInput(
            goal: goal,
            attachments: attachments
        )
        let requestProfile = PipelineMemoryPackStager.agenticRequestProfile(
            for: goal,
            attachments: attachments,
            conversationHistory: conversationHistory,
            model: selectedModel,
            runtimePolicy: runtimePolicy,
            hasVisualReference: preparedInput.hasVisualReference,
            multimodalPreset: preparedInput.multimodalPreset,
            extractorSchema: preparedInput.extractorSchema
        )
        let promptAssemblyEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Prompt Assembly",
            startedAt: promptAssemblyStartedAt,
            endedAt: promptAssemblyEndedAt,
            notes: "history_turns=\(conversationHistory.count) tools=\(requestProfile.tools.count) effort=\(requestProfile.effort) visual_reference=\(preparedInput.hasVisualReference)"
        )

        let streamSetupStartedAt = CFAbsoluteTimeGetCurrent()
        var systemPrompt = PipelineMemoryPackStager.agenticSystemPrompt(
            projectRoot: runner.packageRoot,
            model: selectedModel,
            hasVisualReference: preparedInput.hasVisualReference,
            researcherOutputDir: runner.researcherOutputDir,
            routingReason: routingDecision.reason,
            memoryPack: runner.activeMemoryPack,
            runtimePolicy: runtimePolicy
        )
        if let planContext {
            systemPrompt += "\n\n" + planContext
        }
        let stream = await client.run(
            system: systemPrompt,
            userMessage: preparedInput.userMessage,
            userContentBlocks: preparedInput.userContentBlocks,
            initialMessages: PipelineMemoryPackStager.agenticHistoryPayload(from: conversationHistory),
            model: selectedModel,
            outputEffort: requestProfile.effort,
            verbosity: requestProfile.verbosity,
            tools: requestProfile.tools,
            allowedToolNames: requestProfile.allowedToolNames,
            thinking: requestProfile.thinking,
            cacheControl: [
                "type": "ephemeral"
            ],
            responseFormat: requestProfile.responseFormat,
            latencyRunID: latencyRunID
        )
        let streamSetupEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Agent Stream Setup",
            startedAt: streamSetupStartedAt,
            endedAt: streamSetupEndedAt,
            notes: "provider=\(selectedModel.provider.rawValue)"
        )

        var completed = false
        var architectureAbortMessage: String?
        let streamBuffer = StreamingTextBuffer()
        var didLogFirstVisibleText = false
        let eventLoopStartedAt = CFAbsoluteTimeGetCurrent()

        func flushBufferedText() async {
            let chunk = await streamBuffer.flush()
            guard !chunk.isEmpty else { return }
            // Once a plan is detected, stop piping raw text to the chat thread—
            // the plan lives in the Viewport and the card was already injected.
            guard !runner.streamCoordinator.didDetectPlan else { return }

            let flushStartedAt = CFAbsoluteTimeGetCurrent()
            runner.stage = .running
            runner.statusMessage = "Responding..."
            runner.chatThread.setThinking(false)
            runner.chatThread.appendTextDelta(toMessageID: messageID, text: chunk)
            let flushEndedAt = CFAbsoluteTimeGetCurrent()
            if !didLogFirstVisibleText {
                didLogFirstVisibleText = true
                await LatencyDiagnostics.shared.markPoint(
                    runID: latencyRunID,
                    name: "First Visible Text Flushed To UI",
                    at: flushEndedAt,
                    notes: "message_id=\(messageID.uuidString)"
                )
            }
            await LatencyDiagnostics.shared.recordStage(
                runID: latencyRunID,
                name: "Buffered Text Flush To UI",
                startedAt: flushStartedAt,
                endedAt: flushEndedAt,
                notes: "chunk_chars=\(chunk.count)"
            )
        }

        let textFlushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: StreamingTextBuffer.flushInterval)
                await flushBufferedText()
            }
        }
        defer { textFlushTask.cancel() }

        for await event in stream {
            if Task.isCancelled { return }

            if let violationMessage = await runner.ingestArchitectureEvent(
                PipelineRunner.architectureRuntimeEvent(for: event),
                tracer: tracer,
                sessionSpanID: sessionSpanID
            ) {
                architectureAbortMessage = violationMessage
                break
            }

            if case .textDelta(let text) = event {
                let shouldFlushImmediately = await streamBuffer.append(text)
                runner.streamCoordinator.handleTextDelta(text)
                if shouldFlushImmediately {
                    await flushBufferedText()
                }
                continue
            }

            await flushBufferedText()

            if case .toolCallStart(let id, let name) = event {
                toolCallCount += 1
                let toolSpanID = await tracer.begin(
                    kind: .toolExecution,
                    name: name,
                    parentID: sessionSpanID,
                    attributes: ["toolCallID": id]
                )
                activeToolSpans[id] = toolSpanID
                activeToolStartTimes[id] = Date()
            }

            if case .usage(let inputTokens, let outputTokens) = event {
                llmIterationCount += 1
                await tracer.setAttribute("inputTokens", value: "\(inputTokens)", on: sessionSpanID)
                await tracer.setAttribute("outputTokens", value: "\(outputTokens)", on: sessionSpanID)
            }

            let didCompleteEvent: Bool = {
                switch event {
                case .textDelta:
                    return false

                case .thinkingDelta(let text):
                    runner.stage = .running
                    runner.statusMessage = "Thinking..."
                    runner.chatThread.setThinking(false)
                    runner.chatThread.appendThinkingDelta(toMessageID: messageID, text: text)
                    runner.streamCoordinator.handleThinkingDelta(text)
                    return false

                case .thinkingSignature(let signature):
                    runner.chatThread.setThinkingSignature(toMessageID: messageID, signature: signature)
                    return false

                case .toolCallStart(let id, let name):
                    runner.stage = .running
                    runner.statusMessage = PipelineMemoryPackStager.statusMessage(forToolNamed: name)
                    runner.chatThread.setThinking(false)
                    runner.compactionCoordinator.setToolLoopActive(true)
                    if name == "deploy_to_testflight" {
                        runner.deployment.begin(toolCallID: id, packageRoot: runner.packageRoot)
                    }
                    // Live model label — show which sub-agent is executing.
                    if let delegateLabel = Self.delegateModelLabel(for: name, packageRoot: runner.packageRoot) {
                        activeDelegateToolIDs.insert(id)
                        runner.activeModelName = delegateLabel
                    }
                    if let toolSpanID = activeToolSpans[id] {
                        runner.streamCoordinator.associateToolSpan(id: id, spanID: toolSpanID)
                    }
                    runner.chatThread.startStreamingToolCall(
                        messageID: messageID,
                        call: StreamingToolCall(id: id, name: name)
                    )
                    runner.streamCoordinator.handleToolCallStart(id: id, name: name)
                    return false

                case .toolCallInputDelta(let id, let partialJSON):
                    runner.chatThread.appendToolCallInput(messageID: messageID, callID: id, json: partialJSON)
                    runner.streamCoordinator.handleToolCallInputDelta(id: id, partialJSON: partialJSON)
                    return false

                case .toolCallCommand(let id, let command):
                    runner.deployment.updateCommand(toolCallID: id, command: command)
                    runner.chatThread.updateToolCallDisplayCommand(
                        messageID: messageID,
                        callID: id,
                        command: command
                    )
                    runner.streamCoordinator.handleToolCallCommand(id: id, command: command)
                    return false

                case .toolCallOutput(let id, let line):
                    if activeToolFirstOutputTimes[id] == nil {
                        activeToolFirstOutputTimes[id] = Date()
                    }
                    runner.deployment.appendLine(toolCallID: id, line: line)
                    runner.chatThread.appendToolCallOutput(
                        messageID: messageID,
                        callID: id,
                        line: line
                    )
                    runner.streamCoordinator.handleToolCallOutput(id: id, line: line)
                    return false

                case .toolCallResult(let id, let output, let isError):
                    if isError {
                        runner.stage = .failed
                        runner.errorMessage = PipelineRunner.concise(output)
                    } else {
                        runner.stage = .running
                        runner.statusMessage = "Continuing..."
                    }
                    // Restore primary model label after sub-agent completes.
                    if activeDelegateToolIDs.remove(id) != nil {
                        runner.activeModelName = runner.primaryModelName
                    }
                    runner.chatThread.completeToolCall(
                        messageID: messageID,
                        callID: id,
                        result: output,
                        isError: isError
                    )
                    runner.deployment.complete(toolCallID: id, result: output, isError: isError)
                    runner.streamCoordinator.handleToolCallResult(id: id, result: output, isError: isError)
                    runner.compactionCoordinator.setToolLoopActive(false)
                    return false

                case .usage(let inputTokens, let outputTokens):
                    runner.chatThread.updateTokenUsage(
                        messageID: messageID,
                        input: inputTokens,
                        output: outputTokens
                    )
                    runner.compactionCoordinator.accumulateUsage(input: inputTokens, output: outputTokens)
                    return false

                case .completed:
                    runner.stage = .succeeded
                    runner.statusMessage = "Complete"
                    runner.errorMessage = nil
                    runner.chatThread.setThinking(false)
                    runner.chatThread.finalizeStreaming(
                        messageID: messageID,
                        finalKind: .assistant,
                        fallbackText: "Done."
                    )
                    runner.streamCoordinator.completeRun()
                    runner.compactionCoordinator.setPipelineActive(false)
                    if let finalizedMessage = runner.chatThread.messages.first(where: { $0.id == messageID }) {
                        runner.chatThread.recordAssistantTurn(
                            text: finalizedMessage.text.isEmpty ? "Done." : finalizedMessage.text,
                            thinking: finalizedMessage.thinkingText,
                            thinkingSignature: finalizedMessage.thinkingSignature
                        )
                    } else {
                        runner.chatThread.recordAssistantTurn(text: "Done.", thinking: nil, thinkingSignature: nil)
                    }
                    return true

                case .error(let message):
                    runner.presentAgenticFailure(messageID: messageID, goal: goal, message: message)
                    return false
                }
            }()

            if didCompleteEvent && runner.compactionCoordinator.shouldCompact() {
                await runner.performCompaction(
                    model: selectedModel,
                    anthropicKey: anthropicAPIKey,
                    openAIKey: openAIKey
                )
            }

            if didCompleteEvent, let preset = preparedInput.multimodalPreset,
               preset == .locateRegion || preset == .deepInspect {
                let responseText = runner.chatThread.messages.first(where: { $0.id == messageID })?.text ?? ""
                if let bboxResponse = MultimodalEngine.parseBBoxResponse(from: responseText) {
                    let sourceURL = attachments.first(where: { $0.isImage })?.url
                    runner.pendingBBoxOverlays = bboxResponse.regions
                    runner.pendingBBoxSourceImageURL = sourceURL
                }
            }

            if case .toolCallResult(let id, _, let isError) = event {
                if let toolSpanID = activeToolSpans.removeValue(forKey: id) {
                    let now = Date()
                    if let start = activeToolStartTimes.removeValue(forKey: id) {
                        let totalMs = Int(now.timeIntervalSince(start) * 1000)
                        await tracer.setAttribute("latency.total_ms", value: "\(totalMs)", on: toolSpanID)
                        let firstOutput = activeToolFirstOutputTimes.removeValue(forKey: id) ?? now
                        let ttfmoMs = Int(firstOutput.timeIntervalSince(start) * 1000)
                        await tracer.setAttribute("latency.ttfmo_ms", value: "\(ttfmoMs)", on: toolSpanID)
                    }
                    if isError {
                        await tracer.end(toolSpanID, error: "tool_error")
                    } else {
                        await tracer.end(toolSpanID)
                    }
                }
            }
            if case .completed = event {
                let residualOpenSpans = max(0, await tracer.activeSpanCount() - 1)
                _ = await runner.ingestArchitectureEvent(
                    .traceSnapshot(openSpanCount: residualOpenSpans),
                    tracer: tracer,
                    sessionSpanID: sessionSpanID
                )
                await tracer.setAttribute("execution.success", value: "true", on: sessionSpanID)
                await tracer.setAttribute("execution.tool_call_count", value: "\(toolCallCount)", on: sessionSpanID)
                await tracer.setAttribute("execution.llm_iterations", value: "\(llmIterationCount)", on: sessionSpanID)
                await tracer.setAttribute("execution.escalated", value: "false", on: sessionSpanID)
                await tracer.end(sessionSpanID)
                await finalizeTraceSummary(from: tracer)
            }
            if case .error(let message) = event {
                let residualOpenSpans = max(0, await tracer.activeSpanCount() - 1)
                _ = await runner.ingestArchitectureEvent(
                    .traceSnapshot(openSpanCount: residualOpenSpans),
                    tracer: tracer,
                    sessionSpanID: sessionSpanID
                )
                await tracer.setAttribute("execution.success", value: "false", on: sessionSpanID)
                await tracer.setAttribute("execution.tool_call_count", value: "\(toolCallCount)", on: sessionSpanID)
                await tracer.setAttribute("execution.llm_iterations", value: "\(llmIterationCount)", on: sessionSpanID)
                await tracer.setAttribute("execution.escalated", value: "false", on: sessionSpanID)
                await tracer.end(sessionSpanID, error: String(message.prefix(500)))
                await finalizeTraceSummary(from: tracer)
            }

            if didCompleteEvent {
                completed = true
            }
        }

        if Task.isCancelled { return }

        if let architectureAbortMessage {
            runner.presentAgenticFailure(
                messageID: messageID,
                goal: goal,
                message: "Architecture violation detected. Run cancelled. \(architectureAbortMessage)"
            )
            let residualOpenSpans = max(0, await tracer.activeSpanCount() - 1)
            _ = await runner.ingestArchitectureEvent(
                .traceSnapshot(openSpanCount: residualOpenSpans),
                tracer: tracer,
                sessionSpanID: sessionSpanID
            )
            await tracer.end(sessionSpanID, error: String(architectureAbortMessage.prefix(500)))
            await finalizeTraceSummary(from: tracer)
        }

        if architectureAbortMessage == nil {
            await flushBufferedText()
        }
        let eventLoopEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Agent Stream Event Loop",
            startedAt: eventLoopStartedAt,
            endedAt: eventLoopEndedAt,
            notes: "completed=\(completed)"
        )

        let finalizationStartedAt = CFAbsoluteTimeGetCurrent()
        if !completed && runner.stage != .failed {
            runner.stage = .succeeded
            runner.statusMessage = "Complete"
            runner.chatThread.setThinking(false)
            runner.chatThread.finalizeStreaming(
                messageID: messageID,
                finalKind: .assistant,
                fallbackText: "Done."
            )
        }
        let finalizationEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Run Finalization",
            startedAt: finalizationStartedAt,
            endedAt: finalizationEndedAt,
            notes: "did_complete=\(completed) stage=\(runner.stage.rawValue)"
        )
    }

    private func finalizeTraceSummary(from tracer: TraceCollector) async {
        let summary = await tracer.summary()
        runner.traceHistory.append(summary)
        runner.sessionInspector.stopLive()
        runner.sessionInspector.finalizeLive(summary: summary)
        runner.activeSessionSpanID = nil
    }

    /// Returns a semantic "Role · Model" label for sub-agent delegate tools,
    /// or nil for non-delegate tools.
    static func delegateModelLabel(for toolName: String, packageRoot: String) -> String? {
        switch toolName {
        case "delegate_to_explorer":
            let desc = StudioModelStrategy.descriptor(for: .subagent, packageRoot: packageRoot)
            return "Explorer · \(desc.shortName)"
        case "delegate_to_reviewer":
            let desc = StudioModelStrategy.descriptor(for: .review, packageRoot: packageRoot)
            return "Reviewer · \(desc.shortName)"
        case "delegate_to_worktree":
            let desc = StudioModelStrategy.descriptor(for: .subagent, packageRoot: packageRoot)
            return "Builder · \(desc.shortName)"
        default:
            return nil
        }
    }
}

