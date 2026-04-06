// ModelRouting.swift
// Studio.92 — Command Center
// Model provider enums, descriptors, strategy routing, and ship.toml configuration.

import Foundation

// MARK: - PipelineStage

/// Lifecycle state of the pipeline. Display labels come from statusMessage, not here.
enum PipelineStage: String {
    case idle
    case running
    case succeeded
    case failed

    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Working"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        }
    }

    var displaySymbol: String {
        switch self {
        case .idle: return "circle"
        case .running: return "hammer"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}

enum ModelProvider: String, CaseIterable, Codable {
    case anthropic
    case openAI

    var title: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        }
    }

    var environmentVariableName: String {
        switch self {
        case .anthropic:
            return "ANTHROPIC_API_KEY"
        case .openAI:
            return "OPENAI_API_KEY"
        }
    }

    var symbolName: String {
        switch self {
        case .anthropic:
            return "paintbrush.pointed.fill"
        case .openAI:
            return "bolt.badge.clock"
        }
    }
}

enum StudioModelRole: String, CaseIterable, Codable, Identifiable {
    case review
    case fullSend
    case subagent
    case escalation
    case explorer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review:
            return "Review"
        case .fullSend:
            return "Full Send"
        case .subagent:
            return "Subagent"
        case .escalation:
            return "Escalation"
        case .explorer:
            return "Explorer"
        }
    }

    var shortTitle: String {
        switch self {
        case .review:
            return "Review"
        case .fullSend:
            return "Operator"
        case .subagent:
            return "Workers"
        case .escalation:
            return "Escalate"
        case .explorer:
            return "Scout"
        }
    }

    var symbolName: String {
        switch self {
        case .review:
            return "eye.fill"
        case .fullSend:
            return "bolt.fill"
        case .subagent:
            return "square.stack.3d.up.fill"
        case .escalation:
            return "arrow.up.right.circle.fill"
        case .explorer:
            return "binoculars.fill"
        }
    }
}

struct StudioModelDescriptor: Codable, Equatable, Hashable, Identifiable {
    let role: StudioModelRole
    let provider: ModelProvider
    let identifier: String
    let displayName: String
    let shortName: String
    let summary: String
    let defaultReasoningEffort: String?
    let defaultVerbosity: String?
    let supportsComputerUse: Bool
    let supportsLiveWebResearch: Bool

    var id: String { role.rawValue }

    var providerLine: String {
        "\(provider.title) · \(identifier)"
    }

    func isConfigured(
        anthropicKey: String?,
        openAIKey: String?
    ) -> Bool {
        switch provider {
        case .anthropic:
            return !(anthropicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .openAI:
            return !(openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}

enum StudioModelStrategy {

    // MARK: - Known Model Display Names

    /// Maps raw API identifiers to human-friendly display names.
    /// Unknown identifiers fall through to the raw string (e.g. local Ollama models).
    private static let knownModels: [String: (displayName: String, shortName: String)] = [
        // OpenAI
        "gpt-5.4":              ("GPT-5.4",              "GPT-5.4"),
        "gpt-5.4-mini":         ("GPT-5.4 mini",         "GPT-5.4 mini"),
        "gpt-5.4-nano":         ("GPT-5.4 nano",         "GPT-5.4 nano"),
        "gpt-5.4-pro":          ("GPT-5.4 Pro",          "GPT-5.4 Pro"),
        "gpt-5":                ("GPT-5",                "GPT-5"),
        "gpt-5-mini":           ("GPT-5 mini",           "GPT-5 mini"),
        "gpt-5-nano":           ("GPT-5 nano",           "GPT-5 nano"),
        "gpt-4.5":              ("GPT-4.5",              "GPT-4.5"),
        "o4-mini":              ("o4-mini",              "o4-mini"),
        "o3":                   ("o3",                   "o3"),
        "o3-mini":              ("o3-mini",              "o3-mini"),
        // Anthropic
        "claude-sonnet-4-6":    ("Claude Sonnet 4.6",    "Sonnet 4.6"),
        "claude-opus-4-6":      ("Claude Opus 4.6",      "Opus 4.6"),
        "claude-haiku-4-5":     ("Claude Haiku 4.5",     "Haiku 4.5"),
        "claude-sonnet-4-5":    ("Claude Sonnet 4.5",    "Sonnet 4.5"),
        "claude-opus-4-5":      ("Claude Opus 4.5",      "Opus 4.5"),
        "claude-3-5-sonnet":    ("Claude 3.5 Sonnet",    "Sonnet 3.5"),
    ]

    /// Look up a friendly display name for a model identifier, falling back to the raw string.
    static func displayName(for identifier: String) -> String {
        knownModels[identifier.lowercased()]?.displayName ?? identifier
    }

    /// Look up a friendly short name for a model identifier, falling back to the raw string.
    static func shortName(for identifier: String) -> String {
        knownModels[identifier.lowercased()]?.shortName ?? identifier
    }

    // MARK: - Unified TOML Parser

    /// Parse a minimal ship.toml into [sectionName: [key: value]].
    /// Handles comments, quoted values, and section headers. Nothing else.
    private static func parseShipTOML(at url: URL) -> [String: [String: String]] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var sections: [String: [String: String]] = [:]
        var currentSection = ""

        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let commentIndex = line.firstIndex(of: "#") {
                line = String(line[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }

            guard let sep = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            sections[currentSection, default: [:]][key] = value
        }
        return sections
    }

    // MARK: - ship.toml Cache

    private struct ShipTOMLEntry {
        let modificationDate: Date
        let sections: [String: [String: String]]
    }

    /// Cache keyed by file path, invalidated by modification date.
    private static let shipTOMLCacheLock = NSLock()
    private static var shipTOMLCache: [String: ShipTOMLEntry] = [:]

    /// Returns cached TOML sections, re-parsing only if the file changed.
    private static func cachedShipTOML(at url: URL) -> [String: [String: String]] {
        let path = url.path
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return parseShipTOML(at: url)
        }
        shipTOMLCacheLock.lock()
        if let cached = shipTOMLCache[path], cached.modificationDate == modDate {
            shipTOMLCacheLock.unlock()
            return cached.sections
        }
        shipTOMLCacheLock.unlock()
        let sections = parseShipTOML(at: url)
        shipTOMLCacheLock.lock()
        shipTOMLCache[path] = ShipTOMLEntry(modificationDate: modDate, sections: sections)
        shipTOMLCacheLock.unlock()
        return sections
    }

    private static func shipTOMLURL(packageRoot: String?) -> URL? {
        let trimmed = packageRoot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir.appendingPathComponent(".studio92/ship.toml")
    }

    // MARK: - Base Model Descriptors

    private static let reviewBase = StudioModelDescriptor(
        role: .review,
        provider: .anthropic,
        identifier: "claude-sonnet-4-6",
        displayName: "Claude Sonnet 4.6",
        shortName: "Sonnet 4.6",
        summary: "Default planner, reviewer, and UI/design specialist for plan and review work.",
        defaultReasoningEffort: "high",
        defaultVerbosity: nil,
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    private static let fullSendBase = StudioModelDescriptor(
        role: .fullSend,
        provider: .anthropic,
        identifier: "claude-sonnet-4-6",
        displayName: "Claude Sonnet 4.6",
        shortName: "Sonnet 4.6",
        summary: "Primary full-send builder for creative coding, multi-step implementation, tool-driven workflows, and end-to-end app development.",
        defaultReasoningEffort: "high",
        defaultVerbosity: nil,
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    private static let subagentBase = StudioModelDescriptor(
        role: .subagent,
        provider: .openAI,
        identifier: "gpt-5.4-mini",
        displayName: "GPT-5.4 mini",
        shortName: "GPT-5.4 mini",
        summary: "Fast worker model for repo scouting, test triage, terminal-heavy tasks, and cheap parallelism.",
        defaultReasoningEffort: "high",
        defaultVerbosity: "low",
        supportsComputerUse: true,
        supportsLiveWebResearch: true
    )

    private static let escalationBase = StudioModelDescriptor(
        role: .escalation,
        provider: .anthropic,
        identifier: "claude-opus-4-6",
        displayName: "Claude Opus 4.6",
        shortName: "Opus 4.6",
        summary: "Manual escalation model for the hardest architecture and deep-research cases only.",
        defaultReasoningEffort: "high",
        defaultVerbosity: nil,
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    private static let explorerBase = StudioModelDescriptor(
        role: .explorer,
        provider: .anthropic,
        identifier: "claude-haiku-4-5",
        displayName: "Claude Haiku 4.5",
        shortName: "Haiku 4.5",
        summary: "Fast, cheap model for read-only codebase scouting and broad exploration.",
        defaultReasoningEffort: "high",
        defaultVerbosity: "low",
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    private static let shipModelKeys: [StudioModelRole: String] = [
        .review: "review",
        .fullSend: "full_send",
        .subagent: "subagent",
        .escalation: "escalation",
        .explorer: "explorer"
    ]

    private static let baseByRole: [StudioModelRole: StudioModelDescriptor] = [
        .review: reviewBase,
        .fullSend: fullSendBase,
        .subagent: subagentBase,
        .escalation: escalationBase,
        .explorer: explorerBase
    ]

    static var review: StudioModelDescriptor { descriptor(for: .review) }
    static var fullSend: StudioModelDescriptor { descriptor(for: .fullSend) }
    static var subagent: StudioModelDescriptor { descriptor(for: .subagent) }
    static var escalation: StudioModelDescriptor { descriptor(for: .escalation) }
    static var explorer: StudioModelDescriptor { descriptor(for: .explorer) }
    static var all: [StudioModelDescriptor] { descriptors() }

    static func descriptors(packageRoot: String? = nil) -> [StudioModelDescriptor] {
        StudioModelRole.allCases.map { descriptor(for: $0, packageRoot: packageRoot) }
    }

    static func descriptor(
        for role: StudioModelRole,
        packageRoot: String? = nil
    ) -> StudioModelDescriptor {
        guard let base = baseByRole[role] else {
            return reviewBase
        }
        guard let configuredIdentifier = configuredIdentifier(for: role, packageRoot: packageRoot),
              configuredIdentifier != base.identifier else {
            return base
        }

        let provider = inferredProvider(for: configuredIdentifier, fallback: base.provider)
        return StudioModelDescriptor(
            role: role,
            provider: provider,
            identifier: configuredIdentifier,
            displayName: displayName(for: configuredIdentifier),
            shortName: shortName(for: configuredIdentifier),
            summary: base.summary,
            defaultReasoningEffort: base.defaultReasoningEffort,
            defaultVerbosity: base.defaultVerbosity,
            supportsComputerUse: base.supportsComputerUse,
            supportsLiveWebResearch: base.supportsLiveWebResearch
        )
    }

    /// Returns the primary model — always the fullSend operator.
    static func primaryModel(packageRoot: String? = nil) -> StudioModelDescriptor {
        descriptor(for: .fullSend, packageRoot: packageRoot)
    }

    /// Build a descriptor from a raw model identifier (for manual pin overrides).
    /// Tries to match an existing role descriptor first; falls back to a fullSend-shaped descriptor.
    static func descriptorForIdentifier(_ identifier: String, packageRoot: String? = nil) -> StudioModelDescriptor {
        // Check if any configured role already uses this identifier.
        for role in StudioModelRole.allCases {
            let desc = descriptor(for: role, packageRoot: packageRoot)
            if desc.identifier == identifier {
                return desc
            }
        }
        // Unknown model — construct a descriptor with registry-looked-up display names.
        let provider = inferredProvider(for: identifier, fallback: .openAI)
        let base = baseByRole[.fullSend] ?? reviewBase
        return StudioModelDescriptor(
            role: .fullSend,
            provider: provider,
            identifier: identifier,
            displayName: displayName(for: identifier),
            shortName: shortName(for: identifier),
            summary: base.summary,
            defaultReasoningEffort: base.defaultReasoningEffort,
            defaultVerbosity: base.defaultVerbosity,
            supportsComputerUse: false,
            supportsLiveWebResearch: true
        )
    }

    /// Returns all distinct model identifiers available for the picker (from configured roles).
    static func availableModels(packageRoot: String? = nil) -> [StudioModelDescriptor] {
        var seen = Set<String>()
        var result: [StudioModelDescriptor] = []
        // fullSend first, then review, escalation — skip subagent/explorer (worker models)
        for role in [StudioModelRole.fullSend, .review, .escalation] {
            let desc = descriptor(for: role, packageRoot: packageRoot)
            if seen.insert(desc.identifier).inserted {
                result.append(desc)
            }
        }
        return result
    }

    // MARK: - Intent-Based Model Routing

    private static let reviewIntentSignals = [
        "review",
        "audit",
        "assess",
        "analyze",
        "analyse",
        "inspect",
        "evaluate",
        "critique",
        "check for",
        "look for issues",
        "look for problems",
        "code quality",
        "what do you think",
        "give me feedback",
        "how does this look",
        "any issues",
        "any problems",
        "security scan",
        "hig compliance",
        "hig check",
    ]

    private static let buildIntentOverrides = [
        "fix",
        "change",
        "update",
        "modify",
        "refactor",
        "rewrite",
        "implement",
        "add",
        "create",
        "build",
        "scaffold",
        "delete",
        "remove",
        "replace",
        "migrate",
        "ship",
        "deploy",
        "then fix",
        "and fix",
    ]

    private static let escalationIntentSignals = [
        "use opus",
        "go deep",
        "think harder",
        "escalate",
        "use escalation",
        "bring in opus",
        "hard problem",
    ]

    /// Signals that combine review intent with depth — routes to Opus as deep reviewer.
    private static let reviewEscalationSignals = [
        "deep audit",
        "deep review",
        "production review",
        "is this safe",
        "be critical",
        "thorough review",
        "full audit",
        "security audit",
    ]

    /// Complexity signals that indicate the task is too large or ambiguous for the default builder.
    private static let complexityEscalationSignals = [
        "re-architect",
        "rearchitect",
        "system-wide",
        "cross-cutting",
        "across the app",
        "across the project",
        "overhaul",
        "untangle",
    ]

    // MARK: - Routing Decision

    struct RoutingDecision {
        let model: StudioModelDescriptor
        let reason: String          // "default", "review_intent", "review_escalation", "explicit_escalation", "complexity_escalation"
        let matchedSignals: [String]

        var isReviewRoute: Bool {
            reason == "review_intent" || reason == "review_escalation"
        }
    }

    /// Picks the right model based on the user's goal text.
    /// Explicit escalation triggers → Claude Opus (.escalation).
    /// Review/audit intent → Claude Sonnet (.review).
    /// Complex signals (architecture, system-wide refactors) → Claude Opus (.escalation).
    /// Everything else → Claude Sonnet (.fullSend).
    static func resolvedModel(for goal: String, packageRoot: String? = nil) -> StudioModelDescriptor {
        return routingDecision(for: goal, packageRoot: packageRoot).model
    }

    static func routingDecision(for goal: String, packageRoot: String? = nil) -> RoutingDecision {
        let normalized = goal.lowercased()

        // Explicit Opus triggers — highest priority.
        let matchedEscalation = escalationIntentSignals.filter { normalized.contains($0) }
        if !matchedEscalation.isEmpty {
            return RoutingDecision(
                model: descriptor(for: .escalation, packageRoot: packageRoot),
                reason: "explicit_escalation",
                matchedSignals: matchedEscalation
            )
        }

        // Review + depth signals → Opus as deep reviewer.
        let matchedReviewEscalation = reviewEscalationSignals.filter { normalized.contains($0) }
        if !matchedReviewEscalation.isEmpty {
            return RoutingDecision(
                model: descriptor(for: .escalation, packageRoot: packageRoot),
                reason: "review_escalation",
                matchedSignals: matchedReviewEscalation
            )
        }

        let matchedReview = reviewIntentSignals.filter { normalized.contains($0) }
        let hasBuildOverride = buildIntentOverrides.contains { normalized.contains($0) }

        if !matchedReview.isEmpty && !hasBuildOverride {
            return RoutingDecision(
                model: descriptor(for: .review, packageRoot: packageRoot),
                reason: "review_intent",
                matchedSignals: matchedReview
            )
        }

        // Auto-escalation: complex signals route to Opus when no simple build override is present.
        let matchedComplexity = complexityEscalationSignals.filter { normalized.contains($0) }
        let hasSimpleBuildOverride = ["fix", "change", "update", "add", "delete", "remove"].contains(where: { normalized.contains($0) })
        if !matchedComplexity.isEmpty && !hasSimpleBuildOverride {
            return RoutingDecision(
                model: descriptor(for: .escalation, packageRoot: packageRoot),
                reason: "complexity_escalation",
                matchedSignals: matchedComplexity
            )
        }

        return RoutingDecision(
            model: descriptor(for: .fullSend, packageRoot: packageRoot),
            reason: "default",
            matchedSignals: []
        )
    }

    private static func inferredProvider(
        for identifier: String,
        fallback: ModelProvider
    ) -> ModelProvider {
        let normalized = identifier.lowercased()
        if normalized.contains("claude") {
            return .anthropic
        }
        if normalized.contains("gpt") || normalized.contains("o1") || normalized.contains("o3") || normalized.contains("o4") {
            return .openAI
        }
        return fallback
    }

    private static func configuredIdentifier(
        for role: StudioModelRole,
        packageRoot: String?
    ) -> String? {
        guard let key = shipModelKeys[role] else { return nil }
        guard let identifier = shipModelOverrides(packageRoot: packageRoot)[key] else {
            return nil
        }
        return normalizedConfiguredIdentifier(identifier)
    }

    private static func normalizedConfiguredIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        // Anthropic API model IDs use hyphenated version segments.
        // Accept dotted aliases from config so older ship.toml files keep working.
        if lowercased.hasPrefix("claude-") {
            return trimmed.replacingOccurrences(of: ".", with: "-")
        }

        return trimmed
    }

    private static func shipModelOverrides(packageRoot: String?) -> [String: String] {
        guard let url = shipTOMLURL(packageRoot: packageRoot) else { return [:] }
        return cachedShipTOML(at: url)["models"] ?? [:]
    }

    // MARK: - Execution Config

    static func shipMaxParallelTools(packageRoot: String?) -> Int {
        guard let url = shipTOMLURL(packageRoot: packageRoot),
              let value = cachedShipTOML(at: url)["execution"]?["max_parallel_tools"],
              let n = Int(value), n > 0 else {
            return 6
        }
        return n
    }

    static func credential(
        provider: ModelProvider,
        storedValue: String?
    ) -> String? {
        let trimmedStored = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedStored, !trimmedStored.isEmpty {
            return trimmedStored
        }

        let environmentValue = ProcessInfo.processInfo.environment[provider.environmentVariableName]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return environmentValue
        }

        return nil
    }
}
