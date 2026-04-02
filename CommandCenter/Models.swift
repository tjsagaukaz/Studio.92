// Models.swift
// Studio.92 — Command Center
// Data models for the operator console.
// SwiftData @Model types for persistence + @Observable LiveStateEngine for real-time UI.

import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Notification

extension Notification.Name {
    /// Posted when a telemetry file has been ingested into SwiftData.
    /// userInfo contains "projectID" (UUID).
    static let telemetryIngested = Notification.Name("telemetryIngested")
}

// MARK: - AppProject

/// A project managed by the Dark Factory.
/// Each project represents one iOS app being autonomously built.
@Model
final class AppProject {

    @Attribute(.unique)
    var id: UUID

    /// Human-readable project name (e.g., "NRL Scoreboard", "Solar Fitness").
    var name: String

    /// The original goal string passed to `swift run council`.
    var goal: String

    /// User-facing goal text without any system-added reference context.
    var displayGoal: String?

    /// Derived confidence score (0–100). Never user-editable.
    /// Computed from HIG compliance, deviation budget remaining, and drift state.
    var confidenceScore: Int

    /// The dominant archetype classification for this project.
    /// One of: Tactical, Athletic, Financial, UtilityMinimal, SocialReactive, or nil if unclassified.
    var dominantArchetype: String?

    /// Current deviation budget remaining (0.0–1.0).
    var deviationBudgetRemaining: Double

    /// Current drift budget remaining (0.0–1.0).
    var driftBudgetRemaining: Double

    /// The primary risk label shown in the sidebar (e.g., "HIG Violation", "Drift Alert").
    var primaryRiskLabel: String?

    /// Secondary detail shown below the risk label (e.g., "Blocker: User Override").
    var secondaryRiskDetail: String?

    /// Whether this project requires human intervention before the next pipeline run.
    var requiresHumanOverride: Bool

    /// The most recent Critic verdict text. Short, authoritative.
    var latestCriticVerdict: String?

    /// Flow integrity score (0.0–1.0). Measures how cleanly packets flow through the pipeline.
    var flowIntegrityScore: Double

    /// ISO 8601 timestamp of the last pipeline activity.
    var lastActivityAt: Date

    /// Ordered epochs — each represents a distinct state in the app's evolution.
    @Relationship(deleteRule: .cascade, inverse: \Epoch.project)
    var epochs: [Epoch]

    init(
        name:                     String,
        goal:                     String,
        confidenceScore:          Int     = 0,
        dominantArchetype:        String? = nil,
        deviationBudgetRemaining: Double  = 1.0,
        driftBudgetRemaining:     Double  = 1.0,
        primaryRiskLabel:         String? = nil,
        secondaryRiskDetail:      String? = nil,
        requiresHumanOverride:    Bool    = false,
        latestCriticVerdict:      String? = nil,
        flowIntegrityScore:       Double  = 1.0
    ) {
        self.id                       = UUID()
        self.name                     = name
        self.goal                     = goal
        self.displayGoal              = nil
        self.confidenceScore          = confidenceScore
        self.dominantArchetype        = dominantArchetype
        self.deviationBudgetRemaining = deviationBudgetRemaining
        self.driftBudgetRemaining     = driftBudgetRemaining
        self.primaryRiskLabel         = primaryRiskLabel
        self.secondaryRiskDetail      = secondaryRiskDetail
        self.requiresHumanOverride    = requiresHumanOverride
        self.latestCriticVerdict      = latestCriticVerdict
        self.flowIntegrityScore       = flowIntegrityScore
        self.lastActivityAt           = Date()
        self.epochs                   = []
    }
}

// MARK: - Epoch

/// A distinct state in a project's evolution.
/// Each epoch corresponds to one approved builder change that moved the app forward.
/// that moved the app from state N to state N+1.
@Model
final class Epoch {

    @Attribute(.unique)
    var id: UUID

    /// Sequential index within the project (0, 1, 2, ...).
    var index: Int

    /// One-line summary of what changed in this epoch.
    var summary: String

    /// The archetype classification at the time of this epoch.
    var archetype: String?

    /// The HIG compliance score of the packet that created this epoch.
    var higScore: Double

    /// The deviation budget cost of the packet that created this epoch.
    var deviationCost: Double

    /// The drift score at the time this epoch was created.
    var driftScore: Double

    /// The target file that was modified or created.
    var targetFile: String

    /// Whether this epoch created a new file or patched an existing one.
    var isNewFile: Bool

    /// The packet ID that produced this epoch.
    var packetID: UUID

    /// Timestamp of when this epoch was merged.
    var mergedAt: Date

    /// File path to the Simulator screenshot captured after this epoch's build.
    var screenshotPath: String?

    /// Grounded source delta archived for this epoch when available.
    var diffText: String?

    /// Count of affected components/types archived for this epoch when available.
    var componentsBuilt: Int?

    /// Back-reference to the owning project.
    var project: AppProject?

    init(
        index:          Int,
        summary:        String,
        archetype:      String? = nil,
        higScore:       Double  = 0.0,
        deviationCost:  Double  = 0.0,
        driftScore:     Double  = 0.0,
        targetFile:     String  = "",
        isNewFile:      Bool    = false,
        packetID:       UUID    = UUID(),
        screenshotPath: String? = nil,
        diffText:       String? = nil,
        componentsBuilt: Int?   = nil
    ) {
        self.id             = UUID()
        self.index          = index
        self.summary        = summary
        self.archetype      = archetype
        self.higScore       = higScore
        self.deviationCost  = deviationCost
        self.driftScore     = driftScore
        self.targetFile     = targetFile
        self.isNewFile      = isNewFile
        self.packetID       = packetID
        self.screenshotPath = screenshotPath
        self.diffText       = diffText
        self.componentsBuilt = componentsBuilt
        self.mergedAt       = Date()
    }
}

// MARK: - PipelineStage

/// Discrete stages of the Dark Factory pipeline.
enum PipelineStage: String {
    case idle
    case researching
    case specialistProposing
    case criticAuditing
    case architectMerging
    case weaving
    case verifying
    case executorFixing
    case succeeded
    case failed
}

enum AutonomyMode: String, CaseIterable, Codable {
    case plan
    case review
    case fullSend

    var symbolName: String {
        switch self {
        case .plan:
            return "brain"
        case .review:
            return "eye.fill"
        case .fullSend:
            return "bolt.fill"
        }
    }

    var title: String {
        switch self {
        case .plan:
            return "Plan"
        case .review:
            return "Review"
        case .fullSend:
            return "Full Send"
        }
    }

    var description: String {
        switch self {
        case .plan:
            return "\(StudioModelStrategy.primaryModel(for: self).displayName) plans and reads, but cannot write or execute."
        case .review:
            return "\(StudioModelStrategy.primaryModel(for: self).displayName) proposes changes; manual diff approval stays with you."
        case .fullSend:
            return "\(StudioModelStrategy.primaryModel(for: self).displayName) can edit, verify, and use the wider machine autonomously."
        }
    }

    var allowsTerminalExecution: Bool {
        self != .plan
    }

    var allowsDirectFileWrites: Bool {
        self == .fullSend
    }

    var autoAppliesCodeBlocks: Bool {
        self == .fullSend
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
    case standardsResearch
    case releaseCompliance

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
        case .standardsResearch:
            return "Standards Research"
        case .releaseCompliance:
            return "Release / Compliance"
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
        case .standardsResearch:
            return "Research"
        case .releaseCompliance:
            return "Release"
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
        case .standardsResearch:
            return "safari.fill"
        case .releaseCompliance:
            return "checkmark.shield.fill"
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
    static let review = StudioModelDescriptor(
        role: .review,
        provider: .anthropic,
        identifier: "claude-sonnet-4-6",
        displayName: "Claude Sonnet 4.6",
        shortName: "Sonnet 4.6",
        summary: "Default planner, reviewer, and UI/design specialist for plan and review work.",
        defaultReasoningEffort: "medium",
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    static let fullSend = StudioModelDescriptor(
        role: .fullSend,
        provider: .openAI,
        identifier: "gpt-5.4",
        displayName: "GPT-5.4",
        shortName: "GPT-5.4",
        summary: "Primary full-send operator for computer use, build orchestration, release work, and App Store shipping flows.",
        defaultReasoningEffort: "high",
        supportsComputerUse: true,
        supportsLiveWebResearch: true
    )

    static let subagent = StudioModelDescriptor(
        role: .subagent,
        provider: .openAI,
        identifier: "gpt-5.4-mini",
        displayName: "GPT-5.4 mini",
        shortName: "5.4 mini",
        summary: "Fast worker model for repo scouting, test triage, terminal-heavy tasks, and cheap parallelism.",
        defaultReasoningEffort: "medium",
        supportsComputerUse: true,
        supportsLiveWebResearch: true
    )

    static let escalation = StudioModelDescriptor(
        role: .escalation,
        provider: .anthropic,
        identifier: "claude-opus-4-6",
        displayName: "Claude Opus 4.6",
        shortName: "Opus 4.6",
        summary: "Manual escalation model for the hardest architecture and deep-research cases only.",
        defaultReasoningEffort: "high",
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    static let standardsResearch = StudioModelDescriptor(
        role: .standardsResearch,
        provider: .openAI,
        identifier: "gpt-5.4-mini",
        displayName: "GPT-5.4 mini",
        shortName: "5.4 mini",
        summary: "Apple standards researcher for current docs, APIs, HIG, privacy manifests, and policy checks.",
        defaultReasoningEffort: "medium",
        supportsComputerUse: false,
        supportsLiveWebResearch: true
    )

    static let releaseCompliance = StudioModelDescriptor(
        role: .releaseCompliance,
        provider: .openAI,
        identifier: "gpt-5.4",
        displayName: "GPT-5.4",
        shortName: "GPT-5.4",
        summary: "Release and compliance lead for signing, metadata, screenshots, TestFlight, and App Store Connect readiness.",
        defaultReasoningEffort: "high",
        supportsComputerUse: true,
        supportsLiveWebResearch: true
    )

    static let all: [StudioModelDescriptor] = [
        review,
        fullSend,
        subagent,
        escalation,
        standardsResearch,
        releaseCompliance
    ]

    static func primaryModel(for autonomyMode: AutonomyMode) -> StudioModelDescriptor {
        switch autonomyMode {
        case .plan, .review:
            return review
        case .fullSend:
            return fullSend
        }
    }

    static func model(forToolNamed toolName: String) -> StudioModelDescriptor? {
        switch toolName {
        case "delegate_to_explorer":
            return subagent
        case "delegate_to_reviewer":
            return review
        case "delegate_to_worktree":
            return subagent
        case "deploy_to_testflight":
            return releaseCompliance
        case "web_search":
            return standardsResearch
        default:
            return nil
        }
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

// MARK: - Chat Presentation

enum StepStatus: String, Codable {
    case pending
    case active
    case completed
    case warning
    case failed
}

enum ToolType: String, Codable {
    case webSearch
    case webFetch
    case terminal
    case fileRead
    case fileWrite
    case filePatch
    case listFiles
}

struct ToolCall: Identifiable, Equatable {
    var id = UUID()
    var toolType: ToolType
    var command: String
    var status: StepStatus
    var liveOutput: [String] = []
}

struct ExecutionStep: Identifiable, Equatable {
    let id: String
    var title: String
    var role: String
    var status: StepStatus
    var toolCall: ToolCall? = nil
    var children: [ExecutionStep] = []
}

struct MessageMetrics: Equatable {
    var higScore: Int
    var archetype: String
    var targetFile: String
    var deviationCost: Double
    var elapsedSeconds: Int?
}

struct ChatAttachment: Identifiable, Equatable, Hashable {
    var id = UUID()
    var url: URL
    var displayName: String

    var isImage: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

struct ChatMessage: Identifiable, Equatable {

    enum Kind: String {
        case userGoal
        case acknowledgment
        case assistant
        case stageUpdate
        case criticFeedback
        case completion
        case error
        case executionTree
        case thinking
        case streaming          // New: a message whose text is being streamed token-by-token.
    }

    var id = UUID()
    var kind: Kind
    var goal: String
    var text: String
    var detailText: String?
    var timestamp: Date
    var screenshotPath: String?
    var metrics: MessageMetrics?
    var executionTree: [ExecutionStep]?
    var attachments: [ChatAttachment] = []
    var epochID: UUID?
    var packetID: UUID?

    // MARK: - Streaming Fields

    /// Text accumulated from streaming deltas. Rendered with a typewriter effect.
    var streamingText: String = ""
    /// Whether this message is still receiving streaming deltas.
    var isStreaming: Bool = false
    /// Extended thinking content from the model.
    var thinkingText: String?
    /// Signature for the streamed thinking block, preserved for Anthropic continuity.
    var thinkingSignature: String? = nil
    /// Tool calls that are being assembled during streaming.
    var streamingToolCalls: [StreamingToolCall] = []
    /// Token usage for this message.
    var tokenUsage: (input: Int, output: Int)?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.text == rhs.text
            && lhs.streamingText == rhs.streamingText
            && lhs.isStreaming == rhs.isStreaming
            && lhs.thinkingText == rhs.thinkingText
            && lhs.thinkingSignature == rhs.thinkingSignature
            && lhs.streamingToolCalls == rhs.streamingToolCalls
    }
}

/// A tool call being progressively assembled during streaming.
struct StreamingToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    var inputJSON: String = ""
    var displayCommand: String?
    var liveOutput: [String] = []
    var status: StepStatus = .active
    var result: String?
    var isError: Bool = false
}

struct ConversationHistoryTurn: Equatable, Sendable {

    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var role: Role
    var text: String
    var contentBlocks: [HistoryContentBlock]? = nil
    var timestamp: Date = Date()

    enum HistoryContentBlock: Equatable, Sendable {
        case text(String)
        case thinking(text: String, signature: String?)
    }
}

struct AssistantResponse: Equatable {
    var text: String = ""
    var streamingText: String = ""
    var isStreaming: Bool = false
    var thinkingText: String = ""

    var renderedText: String {
        let stable = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (stable.isEmpty, live.isEmpty, isStreaming) {
        case (false, false, true):
            return "\(stable)\n\n\(live)"
        case (true, false, true):
            return live
        default:
            return stable
        }
    }
}

private actor StreamBuffer {

    private var buffer = ""

    func append(_ text: String) {
        buffer += text
    }

    func flush() -> String {
        let output = buffer
        buffer.removeAll(keepingCapacity: true)
        return output
    }
}

private enum ChatTextSanitizer {

    static func clean(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFD}", with: "")

        return removeStandaloneTableDividers(from: normalized)
    }

    private static func removeStandaloneTableDividers(from text: String) -> String {
        guard text.contains("|") else { return text }

        var cleanedLines: [String] = []
        var insideCodeFence = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                insideCodeFence.toggle()
                cleanedLines.append(line)
                continue
            }

            if !insideCodeFence, isStandaloneTableDivider(trimmed) {
                continue
            }

            cleanedLines.append(line)
        }

        return cleanedLines.joined(separator: "\n")
    }

    private static func isStandaloneTableDivider(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        guard line.contains("|") else { return false }
        guard line.contains("-") || line.contains(":") else { return false }

        return line.allSatisfy { character in
            switch character {
            case "|", "-", ":", " ":
                return true
            default:
                return false
            }
        }
    }
}

private enum StreamingNarrativePartitioner {

    static func splitStablePrefix(from text: String) -> (stable: String, live: String) {
        guard !text.isEmpty else { return ("", "") }

        var searchStart = text.startIndex
        var lastSafeBoundary: String.Index?

        while let range = text.range(of: "\n\n", range: searchStart..<text.endIndex) {
            let prefix = String(text[..<range.upperBound])
            if fenceCount(in: prefix).isMultiple(of: 2) {
                lastSafeBoundary = range.upperBound
            }
            searchStart = range.upperBound
        }

        guard let boundary = lastSafeBoundary else {
            return ("", text)
        }

        return (
            stable: String(text[..<boundary]),
            live: String(text[boundary...])
        )
    }

    static func join(stable: String, live: String) -> String {
        let stableTrimmed = stable.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveTrimmed = live.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (stableTrimmed.isEmpty, liveTrimmed.isEmpty) {
        case (true, true):
            return ""
        case (false, true):
            return stable
        case (true, false):
            return live
        case (false, false):
            return stable + live
        }
    }

    private static func fenceCount(in text: String) -> Int {
        text.components(separatedBy: "```").count - 1
    }
}

struct ToolTrace: Identifiable, Equatable {

    enum Kind: String, Equatable {
        case search
        case read
        case edit
        case write
        case build
        case terminal
        case screenshot
        case artifact
    }

    enum Status: String, Equatable {
        case running
        case success
        case error
    }

    let id: String
    var sourceName: String
    var kind: Kind
    var title: String
    var status: Status
    var detail: String?
    var filePath: String?
    var relatedFilePaths: [String] = []
    var linesAdded: Int?
    var linesRemoved: Int?
    var liveOutput: [String] = []
    var timestamp: Date

    var isLive: Bool {
        status == .running
    }

    var isDelegationTrace: Bool {
        switch sourceName {
        case "delegate_to_explorer", "delegate_to_reviewer", "delegate_to_worktree":
            return true
        default:
            return false
        }
    }

    var isContextTrace: Bool {
        guard !isDelegationTrace else { return false }
        switch kind {
        case .search, .read:
            return true
        case .edit, .write, .build, .terminal, .screenshot, .artifact:
            return false
        }
    }

    var isConsoleTrace: Bool {
        switch kind {
        case .build, .terminal:
            return true
        case .search, .read, .edit, .write, .screenshot, .artifact:
            return false
        }
    }

    var isFileLedgerTrace: Bool {
        switch sourceName {
        case "file_read", "file_write", "file_patch":
            return true
        default:
            return false
        }
    }

    var supportsInlinePeek: Bool {
        switch kind {
        case .build, .terminal, .screenshot:
            return true
        case .search, .read, .edit, .write, .artifact:
            return false
        }
    }
}

enum TurnState: String, Equatable {
    case streaming
    case executing
    case finalizing
    case completed
    case failed
}

struct DeploymentState: Equatable {

    enum Phase: String, Equatable {
        case idle
        case running
        case completed
        case failed
    }

    var phase: Phase = .idle
    var toolCallID: String?
    var lane: String = "beta"
    var command: String?
    var targetDirectory: String?
    var lines: [String] = []
    var startedAt: Date?
    var finishedAt: Date?
    var summary: String?

    var isVisible: Bool {
        phase != .idle
    }

    var isActive: Bool {
        phase == .running
    }

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(phase.rawValue)
        hasher.combine(toolCallID)
        hasher.combine(lane)
        hasher.combine(command)
        hasher.combine(targetDirectory)
        hasher.combine(lines.count)
        hasher.combine(summary)
        hasher.combine(startedAt)
        hasher.combine(finishedAt)
        return hasher.finalize()
    }
}

struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    var userGoal: String
    var userAttachments: [ChatAttachment] = []
    var response: AssistantResponse
    var toolTraces: [ToolTrace]
    var state: TurnState
    var timestamp: Date
    var epochID: UUID?
    var packetID: UUID?
    var screenshotPath: String?
    var metrics: MessageMetrics?
    var isHistorical = false
}

@Observable
final class ConversationStore {
    var turns: [ConversationTurn] = []
    var activeTurnID: UUID?

    func rebuild(from messages: [ChatMessage], isPipelineRunning: Bool) {
        let sortedMessages = messages.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }

        var builtTurns: [ConversationTurn] = []
        var activeTurn: ConversationTurn?

        func commitActiveTurn() {
            guard var committedTurn = activeTurn else { return }
            committedTurn = Self.finalized(committedTurn, isPipelineRunning: isPipelineRunning)
            builtTurns.append(committedTurn)
            activeTurn = nil
        }

        for message in sortedMessages {
            switch message.kind {
            case .userGoal:
                commitActiveTurn()
                activeTurn = Self.baseTurn(from: message)

            default:
                if activeTurn == nil {
                    activeTurn = Self.turn(from: message)
                } else if var current = activeTurn {
                    Self.absorb(message, into: &current)
                    activeTurn = current
                }

                if message.kind == .completion || message.kind == .error {
                    commitActiveTurn()
                }
            }
        }

        commitActiveTurn()
        turns = builtTurns
        activeTurnID = turns.last(where: {
            $0.state == .streaming || $0.state == .executing || $0.state == .finalizing
        })?.id
    }

    func turn(from message: ChatMessage) -> ConversationTurn {
        Self.turn(from: message)
    }

    private static func baseTurn(from message: ChatMessage) -> ConversationTurn {
        ConversationTurn(
            id: message.id,
            userGoal: message.text,
            userAttachments: message.attachments,
            response: AssistantResponse(),
            toolTraces: [],
            state: .executing,
            timestamp: message.timestamp,
            epochID: message.epochID,
            packetID: message.packetID,
            screenshotPath: message.screenshotPath,
            metrics: message.metrics,
            isHistorical: false
        )
    }

    private static func turn(from message: ChatMessage) -> ConversationTurn {
        var turn = ConversationTurn(
            id: message.epochID ?? message.id,
            userGoal: message.goal,
            userAttachments: message.kind == .userGoal ? message.attachments : [],
            response: AssistantResponse(),
            toolTraces: [],
            state: message.kind == .error ? .failed : .completed,
            timestamp: message.timestamp,
            epochID: message.epochID,
            packetID: message.packetID,
            screenshotPath: message.screenshotPath,
            metrics: message.metrics,
            isHistorical: true
        )
        absorb(message, into: &turn)
        return turn
    }

    private static func absorb(_ message: ChatMessage, into turn: inout ConversationTurn) {
        turn.timestamp = max(turn.timestamp, message.timestamp)
        turn.epochID = message.epochID ?? turn.epochID
        turn.packetID = message.packetID ?? turn.packetID
        turn.screenshotPath = message.screenshotPath ?? turn.screenshotPath
        turn.metrics = message.metrics ?? turn.metrics
        if message.kind == .userGoal {
            turn.userGoal = message.text
            turn.userAttachments = message.attachments
            return
        }

        if shouldAbsorbNarrative(from: message.kind) {
            appendNarrative(text: message.text, detailText: message.detailText, to: &turn.response)
        }
        mergeStreamingState(from: message, into: &turn.response)
        mergeToolTraces(from: message, into: &turn)
        mergeState(from: message, into: &turn)
    }

    private static func appendNarrative(
        text: String,
        detailText: String?,
        to response: inout AssistantResponse
    ) {
        for fragment in [text, detailText].compactMap(normalizedNarrative) {
            if !response.text.contains(fragment) {
                if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    response.text += "\n\n"
                }
                response.text += fragment
            }
        }
    }

    private static func shouldAbsorbNarrative(from kind: ChatMessage.Kind) -> Bool {
        switch kind {
        case .acknowledgment, .assistant, .completion, .error:
            return true
        case .userGoal, .stageUpdate, .criticFeedback, .executionTree, .thinking, .streaming:
            return false
        }
    }

    private static func mergeStreamingState(from message: ChatMessage, into response: inout AssistantResponse) {
        response.isStreaming = message.isStreaming
        response.thinkingText = message.thinkingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if message.kind == .streaming || message.isStreaming {
            if let committed = normalizedNarrative(message.text) {
                appendNarrative(text: committed, detailText: nil, to: &response)
            }
            response.streamingText = message.streamingText
        } else if !message.streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            response.streamingText = ""
        } else if !response.isStreaming {
            response.streamingText = ""
        }
    }

    private static func mergeToolTraces(from message: ChatMessage, into turn: inout ConversationTurn) {
        if let executionTree = message.executionTree {
            for trace in traces(from: executionTree, timestamp: message.timestamp) {
                upsert(trace, into: &turn.toolTraces)
            }
        }

        for call in message.streamingToolCalls {
            upsert(trace(from: call, timestamp: message.timestamp), into: &turn.toolTraces)
        }
    }

    private static func mergeState(from message: ChatMessage, into turn: inout ConversationTurn) {
        switch message.kind {
        case .error:
            turn.state = .failed
        case .completion:
            turn.state = .completed
        case .streaming:
            turn.state = message.isStreaming ? .streaming : .finalizing
        case .assistant, .acknowledgment:
            if turn.state != .failed && turn.state != .completed {
                turn.state = .finalizing
            }
        default:
            break
        }
    }

    private static func finalized(_ turn: ConversationTurn, isPipelineRunning: Bool) -> ConversationTurn {
        var turn = turn
        if turn.state == .failed || turn.toolTraces.contains(where: { $0.status == .error }) {
            turn.state = .failed
            return turn
        }

        if turn.response.isStreaming {
            turn.state = .streaming
            return turn
        }

        if turn.toolTraces.contains(where: { $0.status == .running }) {
            turn.state = isPipelineRunning ? .executing : .finalizing
            return turn
        }

        if turn.epochID != nil || !turn.response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turn.state = .completed
        }

        return turn
    }

    private static func upsert(_ trace: ToolTrace, into traces: inout [ToolTrace]) {
        if let index = traces.firstIndex(where: { $0.id == trace.id }) {
            traces[index] = trace
        } else {
            traces.append(trace)
        }
    }

    private static func trace(from call: StreamingToolCall, timestamp: Date) -> ToolTrace {
        let title = traceTitle(
            toolName: call.name,
            inputJSON: call.inputJSON,
            displayCommand: call.displayCommand
        )

        return ToolTrace(
            id: call.id,
            sourceName: call.name,
            kind: traceKind(
                toolName: call.name,
                inputJSON: call.inputJSON,
                displayCommand: call.displayCommand
            ),
            title: title,
            status: traceStatus(from: call.status),
            detail: traceDetail(
                name: call.name,
                liveOutput: call.liveOutput,
                result: call.result
            ),
            filePath: traceFilePath(
                toolName: call.name,
                inputJSON: call.inputJSON,
                displayCommand: call.displayCommand
            ),
            relatedFilePaths: traceRelatedFilePaths(
                toolName: call.name,
                inputJSON: call.inputJSON,
                displayCommand: call.displayCommand
            ),
            linesAdded: traceLineDelta(
                toolName: call.name,
                inputJSON: call.inputJSON
            )?.added,
            linesRemoved: traceLineDelta(
                toolName: call.name,
                inputJSON: call.inputJSON
            )?.removed,
            liveOutput: call.liveOutput,
            timestamp: timestamp
        )
    }

    private static func traces(from steps: [ExecutionStep], timestamp: Date) -> [ToolTrace] {
        flattenedSteps(from: steps).compactMap { step in
            if ["pipeline", "council", "specialist", "critic", "architect"].contains(step.id) {
                return nil
            }

            if let toolCall = step.toolCall {
                return ToolTrace(
                    id: "execution-\(step.id)",
                    sourceName: toolCall.toolType.rawValue,
                    kind: traceKind(for: toolCall, stepID: step.id, fallbackTitle: step.title),
                    title: traceTitle(for: toolCall, fallback: step.title),
                    status: traceStatus(from: toolCall.status),
                    detail: traceDetail(
                        name: toolCall.toolType.rawValue,
                        liveOutput: toolCall.liveOutput,
                        result: nil
                    ),
                    filePath: traceFilePath(for: toolCall),
                    relatedFilePaths: traceRelatedFilePaths(for: toolCall),
                    liveOutput: toolCall.liveOutput,
                    timestamp: timestamp
                )
            }

            if step.id == "verify" {
                return ToolTrace(
                    id: "execution-\(step.id)",
                    sourceName: step.id,
                    kind: step.id == "screenshots" ? .screenshot : .build,
                    title: step.title,
                    status: traceStatus(from: step.status),
                    detail: nil,
                    timestamp: timestamp
                )
            }

            return nil
        }
    }

    private static func flattenedSteps(from steps: [ExecutionStep]) -> [ExecutionStep] {
        steps.flatMap { step in
            [step] + flattenedSteps(from: step.children)
        }
    }

    private static func traceTitle(
        toolName: String,
        inputJSON: String,
        displayCommand: String?
    ) -> String {
        let input = parsedJSON(from: inputJSON)

        switch toolName {
        case "delegate_to_explorer":
            let objective = truncate((input?["objective"] as? String) ?? "broad workspace context", limit: 58)
            return "Workspace Explorer: \(objective)"
        case "delegate_to_reviewer":
            let files = stringArray(from: input?["files_to_review"])
            let focus = truncate((input?["focus_area"] as? String) ?? "code review", limit: 42)
            if let firstFile = files.first {
                let displayName = URL(fileURLWithPath: firstFile).lastPathComponent
                return files.count == 1
                    ? "Code Reviewer: \(displayName)"
                    : "Code Reviewer: \(displayName) +\(files.count - 1)"
            }
            return "Code Reviewer: \(focus)"
        case "delegate_to_worktree":
            let taskPrompt = truncate((input?["task_prompt"] as? String) ?? "isolated background job", limit: 56)
            return "Background Job: \(taskPrompt)"
        case "terminal":
            return displayCommand
                ?? (input?["objective"] as? String)
                ?? (input?["starting_command"] as? String)
                ?? (input?["command"] as? String)
                ?? "Running terminal task"
        case "deploy_to_testflight":
            return "Deploying to TestFlight"
        case "file_read":
            return "Reading \((input?["path"] as? String) ?? "file")"
        case "file_write":
            return "Writing \((input?["path"] as? String) ?? "file")"
        case "file_patch":
            return "Patching \((input?["path"] as? String) ?? "file")"
        case "list_files":
            return "Inspecting \((input?["path"] as? String) ?? ".")"
        case "web_search":
            return "Searching \(truncate((input?["query"] as? String) ?? "the web", limit: 64))"
        case "web_fetch":
            return "Fetching \(truncate((input?["url"] as? String) ?? "resource", limit: 64))"
        default:
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func traceKind(
        toolName: String,
        inputJSON: String,
        displayCommand: String?
    ) -> ToolTrace.Kind {
        let input = parsedJSON(from: inputJSON)
        let combinedContext = [
            displayCommand,
            input?["objective"] as? String,
            input?["starting_command"] as? String,
            input?["command"] as? String,
            input?["context"] as? String
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: "\n")

        switch toolName {
        case "delegate_to_explorer":
            return .search
        case "delegate_to_reviewer":
            return .read
        case "delegate_to_worktree":
            return .artifact
        case "web_search", "list_files":
            return .search
        case "web_fetch", "file_read":
            return .read
        case "file_patch":
            return .edit
        case "file_write":
            return .write
        case "deploy_to_testflight":
            return .build
        case "terminal":
            if combinedContext.contains("screenshot")
                || combinedContext.contains("simctl io")
                || combinedContext.contains("capture") {
                return .screenshot
            }

            if combinedContext.contains("xcodebuild")
                || combinedContext.contains("swift build")
                || combinedContext.contains("swift test")
                || combinedContext.contains("build")
                || combinedContext.contains("compile")
                || combinedContext.contains("verify")
                || combinedContext.contains("test") {
                return .build
            }

            return .terminal
        default:
            return .terminal
        }
    }

    private static func traceFilePath(
        toolName: String,
        inputJSON: String,
        displayCommand: String?
    ) -> String? {
        let input = parsedJSON(from: inputJSON)

        switch toolName {
        case "file_read", "file_write", "file_patch":
            return input?["path"] as? String
        case "terminal":
            let combinedContext = [
                displayCommand,
                input?["starting_command"] as? String,
                input?["command"] as? String
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            return extractPath(from: combinedContext)
        default:
            return nil
        }
    }

    private static func traceFilePath(for toolCall: ToolCall) -> String? {
        switch toolCall.toolType {
        case .fileRead, .fileWrite, .filePatch:
            return extractPath(from: toolCall.command)
        case .webSearch, .webFetch, .terminal, .listFiles:
            return nil
        }
    }

    private static func traceRelatedFilePaths(
        toolName: String,
        inputJSON: String,
        displayCommand: String?
    ) -> [String] {
        let input = parsedJSON(from: inputJSON)

        switch toolName {
        case "delegate_to_reviewer":
            return stringArray(from: input?["files_to_review"])
        case "delegate_to_worktree":
            if let targetDirectory = input?["target_directory"] as? String {
                return [".studio92/worktrees/\(targetDirectory)"]
            }
            return []
        case "file_read", "file_write", "file_patch":
            if let path = input?["path"] as? String {
                return [path]
            }
            return []
        case "terminal":
            if let filePath = traceFilePath(toolName: toolName, inputJSON: inputJSON, displayCommand: displayCommand) {
                return [filePath]
            }
            return []
        default:
            return []
        }
    }

    private static func traceRelatedFilePaths(for toolCall: ToolCall) -> [String] {
        switch toolCall.toolType {
        case .fileRead, .fileWrite, .filePatch:
            if let path = traceFilePath(for: toolCall) {
                return [path]
            }
            return []
        case .terminal, .listFiles, .webSearch, .webFetch:
            return []
        }
    }

    private static func traceLineDelta(
        toolName: String,
        inputJSON: String
    ) -> (added: Int, removed: Int)? {
        let input = parsedJSON(from: inputJSON)

        switch toolName {
        case "file_patch":
            let removed = lineHeuristic(for: input?["old_string"] as? String)
            let added = lineHeuristic(for: input?["new_string"] as? String)
            return (added: added, removed: removed)
        case "file_write":
            let added = lineHeuristic(for: input?["content"] as? String)
            guard added > 0 else { return nil }
            return (added: added, removed: 0)
        default:
            return nil
        }
    }

    private static func traceTitle(for toolCall: ToolCall, fallback: String) -> String {
        switch toolCall.toolType {
        case .webSearch:
            return toolCall.command.isEmpty ? "Searching the web" : toolCall.command
        case .webFetch:
            return toolCall.command.isEmpty ? "Fetching resource" : toolCall.command
        case .terminal:
            return toolCall.command.isEmpty ? fallback : toolCall.command
        case .fileRead:
            return toolCall.command.isEmpty ? "Reading file" : toolCall.command
        case .fileWrite:
            return toolCall.command.isEmpty ? "Writing file" : toolCall.command
        case .filePatch:
            return toolCall.command.isEmpty ? "Patching file" : toolCall.command
        case .listFiles:
            return toolCall.command.isEmpty ? "Inspecting files" : toolCall.command
        }
    }

    private static func traceKind(
        for toolCall: ToolCall,
        stepID: String,
        fallbackTitle: String
    ) -> ToolTrace.Kind {
        switch toolCall.toolType {
        case .webSearch:
            return .search
        case .webFetch:
            return .read
        case .fileRead, .listFiles:
            return .read
        case .fileWrite:
            return .write
        case .filePatch:
            return .edit
        case .terminal:
            let context = "\(toolCall.command)\n\(fallbackTitle)\n\(stepID)".lowercased()
            if context.contains("screenshot") || context.contains("simctl io") {
                return .screenshot
            }
            if context.contains("build")
                || context.contains("compile")
                || context.contains("verify")
                || context.contains("test") {
                return .build
            }
            return .terminal
        }
    }

    private static func traceDetail(
        name: String,
        liveOutput: [String],
        result: String?
    ) -> String? {
        if name == "file_read"
            || name == "list_files"
            || name == "web_search"
            || name == "web_fetch"
            || name == "delegate_to_explorer"
            || name == "delegate_to_reviewer"
            || name == "delegate_to_worktree" {
            return nil
        }

        if !liveOutput.isEmpty {
            return liveOutput.suffix(4).joined(separator: "\n")
        }

        guard let result else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(600))
    }

    private static func traceStatus(from status: StepStatus) -> ToolTrace.Status {
        switch status {
        case .completed:
            return .success
        case .failed, .warning:
            return .error
        case .pending, .active:
            return .running
        }
    }

    private static func normalizedNarrative(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func parsedJSON(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringArray(from value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func lineHeuristic(for text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    private static func extractPath(from text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            .map(String.init)

        return tokens.first(where: { token in
            token.contains("/") || token.hasSuffix(".swift") || token.hasSuffix(".xcodeproj")
        })
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        if value.count <= limit {
            return value
        }
        return String(value.prefix(limit)) + "..."
    }
}

@Observable
final class ChatThread {
    var messages: [ChatMessage] = []
    var isThinking = false
    var completedTurns: [ConversationHistoryTurn] = []

    func post(_ message: ChatMessage) {
        messages.append(message)
    }

    func updateMessage(id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var message = messages[index]
        mutate(&message)
        messages[index] = message
    }

    func setThinking(_ thinking: Bool) {
        isThinking = thinking
    }

    func clear() {
        messages.removeAll()
        isThinking = false
        completedTurns.removeAll()
    }

    // MARK: - Streaming Support

    /// Append a text delta to a streaming message.
    func appendTextDelta(toMessageID id: UUID, text: String) {
        updateMessage(id: id) { message in
            message.streamingText += ChatTextSanitizer.clean(text)
        }
    }

    /// Append a thinking delta to a streaming message.
    func appendThinkingDelta(toMessageID id: UUID, text: String) {
        let cleaned = ChatTextSanitizer.clean(text)
        guard !cleaned.isEmpty else { return }

        updateMessage(id: id) { message in
            if message.thinkingText == nil {
                message.thinkingText = cleaned
            } else {
                message.thinkingText! += cleaned
            }
        }
    }

    func setThinkingSignature(toMessageID id: UUID, signature: String) {
        updateMessage(id: id) { message in
            message.thinkingSignature = signature
        }
    }

    /// Register a new tool call on a streaming message.
    func startStreamingToolCall(messageID: UUID, call: StreamingToolCall) {
        updateMessage(id: messageID) { message in
            message.streamingToolCalls.append(call)
        }
    }

    /// Append partial JSON input to a tool call being assembled.
    func appendToolCallInput(messageID: UUID, callID: String, json: String) {
        updateMessage(id: messageID) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].inputJSON += json
        }
    }

    func updateToolCallDisplayCommand(messageID: UUID, callID: String, command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        updateMessage(id: messageID) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].displayCommand = trimmed
        }
    }

    func appendToolCallOutput(messageID: UUID, callID: String, line: String, maxLines: Int = 200) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }

        updateMessage(id: messageID) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].liveOutput.append(trimmed)
            if message.streamingToolCalls[index].liveOutput.count > maxLines {
                message.streamingToolCalls[index].liveOutput.removeFirst(
                    message.streamingToolCalls[index].liveOutput.count - maxLines
                )
            }
        }
    }

    /// Complete a tool call with its result.
    func completeToolCall(messageID: UUID, callID: String, result: String, isError: Bool) {
        updateMessage(id: messageID) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].status  = isError ? .failed : .completed
            message.streamingToolCalls[index].result  = result
            message.streamingToolCalls[index].isError = isError
        }
    }

    /// Finalize a streaming message: copy streamingText into text, clear streaming state.
    func finalizeStreaming(
        messageID: UUID,
        finalKind: ChatMessage.Kind = .assistant,
        fallbackText: String? = nil
    ) {
        updateMessage(id: messageID) { message in
            let finalizedText = ChatTextSanitizer.clean(
                StreamingNarrativePartitioner.join(
                    stable: message.text,
                    live: message.streamingText
                )
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            message.text = finalizedText.isEmpty ? (fallbackText ?? "") : finalizedText
            message.streamingText = ""
            message.isStreaming = false
            message.kind = finalKind
        }
    }

    func failStreaming(messageID: UUID, errorText: String) {
        updateMessage(id: messageID) { message in
            let visibleText = StreamingNarrativePartitioner.join(
                stable: message.text,
                live: message.streamingText
            )

            if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleanedError = ChatTextSanitizer.clean(errorText)
                message.text = cleanedError
                message.streamingText = cleanedError
            }
            message.isStreaming = false
            message.kind = .error
        }
    }

    /// Update token usage on a streaming message.
    func updateTokenUsage(messageID: UUID, input: Int, output: Int) {
        updateMessage(id: messageID) { message in
            if let existing = message.tokenUsage {
                message.tokenUsage = (input: existing.input + input, output: existing.output + output)
            } else {
                message.tokenUsage = (input: input, output: output)
            }
        }
    }

    func visibleContentState(forMessageID id: UUID) -> (hasText: Bool, hasThinking: Bool, hasToolCalls: Bool) {
        guard let message = messages.first(where: { $0.id == id }) else {
            return (false, false, false)
        }
        return (
            !message.streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !(message.thinkingText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            !message.streamingToolCalls.isEmpty
        )
    }

    func recordTurn(role: ConversationHistoryTurn.Role, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        completedTurns.append(
            ConversationHistoryTurn(
                role: role,
                text: trimmed,
                timestamp: Date()
            )
        )
    }

    func recordAssistantTurn(text: String, thinking: String?, thinkingSignature: String?) {
        let trimmedText = ChatTextSanitizer.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThinking = thinking.map {
            ChatTextSanitizer.clean($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmedText.isEmpty || !(trimmedThinking?.isEmpty ?? true) else { return }

        var blocks: [ConversationHistoryTurn.HistoryContentBlock] = []
        if let trimmedThinking, !trimmedThinking.isEmpty {
            blocks.append(.thinking(text: trimmedThinking, signature: thinkingSignature))
        }
        if !trimmedText.isEmpty {
            blocks.append(.text(trimmedText))
        }

        completedTurns.append(
            ConversationHistoryTurn(
                role: .assistant,
                text: trimmedText,
                contentBlocks: blocks.isEmpty ? nil : blocks,
                timestamp: Date()
            )
        )
    }
}

// MARK: - PacketSummary

/// Lightweight Codable mirror of the builder telemetry payload.
/// Decodes the same JSON without importing the package target.
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
struct PipelineError: Error {
    let message: String
}

// MARK: - PipelineRunner

/// Drives the Dark Factory pipeline via Process.
/// Surfaces status + blockers only — no log storage.
@Observable
final class PipelineRunner: @unchecked Sendable {

    private static let orchestrationEscalationSignals = [
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

    private struct CouncilEvent {
        let role: String
        let step: String
        let outcome: String
    }

    private final class ExecutionState {
        var specialist = StepStatus.pending
        var critic = StepStatus.pending
        var architect = StepStatus.pending
        var weaver = StepStatus.pending
        var verify: StepStatus?
        var executor: StepStatus?

        var specialistTitle = "Specialist proposal"
        var criticTitle = "Critic review"
        var architectTitle = "Architect merge"
        var weaverTitle = "Apply approved changes"

        var councilTool: ToolCall?
        var weaverTool: ToolCall?
        var executorTool: ToolCall?
        var webSearchTool: ToolCall?
        var webFetchTool: ToolCall?
    }

    var stage: PipelineStage = .idle
    var statusMessage: String = "Ready"
    var criticVerdict: String?
    var errorMessage: String?
    var approvedPacketJSON: String?
    var elapsedSeconds: Int = 0
    var chatThread = ChatThread()
    var deploymentState = DeploymentState()
    var activeGoal: String?
    var activeDisplayGoal: String?
    var goalHistory: [String] = {
        UserDefaults.standard.stringArray(forKey: "goalHistory") ?? []
    }()

    var isRunning: Bool {
        switch stage {
        case .researching, .specialistProposing, .criticAuditing, .architectMerging, .weaving, .verifying, .executorFixing:
            return true
        default:
            return false
        }
    }

    var packageRoot: String

    private var activeProcess: Process?
    private var elapsedTimer: Timer?
    private var currentExecutionState = ExecutionState()
    private var currentRunMessageIDs: [UUID] = []
    private var currentExecutionTreeMessageID: UUID?
    private var currentCompletionMessageID: UUID?
    private var currentStreamingMessageID: UUID?
    private var currentPacketID: UUID?
    private var emittedNarrativeKeys: Set<String> = []
    private var currentRunNarrativeCount = 0
    private let maxToolOutputLines = 160
    private var activeAgenticTask: Task<Void, Never>?

    init(packageRoot: String) {
        self.packageRoot = packageRoot
    }

    @MainActor
    func updatePackageRoot(_ newValue: String) {
        let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != packageRoot else { return }

        if isRunning {
            cancel()
        }

        packageRoot = normalized
        stage = .idle
        statusMessage = "Workspace ready"
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        activeGoal = nil
        activeDisplayGoal = nil
        deploymentState = DeploymentState()
        activeProcess = nil
        activeAgenticTask = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        currentPacketID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        chatThread = ChatThread()
        stopElapsedTimer()
        elapsedSeconds = 0
    }

    // MARK: - Run

    @MainActor
    func run(
        goal: String,
        displayGoal: String? = nil,
        attachments: [ChatAttachment] = [],
        apiKey: String? = nil,
        openAIKey: String? = nil,
        autonomyMode: AutonomyMode = .review
    ) async {
        guard !isRunning else { return } // Hard run lock

        let historyValue = (displayGoal ?? goal).trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationHistory = chatThread.completedTurns
        let resolvedAnthropicKey = StudioModelStrategy.credential(provider: .anthropic, storedValue: apiKey)
        let resolvedOpenAIKey = StudioModelStrategy.credential(provider: .openAI, storedValue: openAIKey)
        let selectedModel = StudioModelStrategy.primaryModel(for: autonomyMode)

        // Save to history
        goalHistory.removeAll { $0 == historyValue }
        goalHistory.insert(historyValue, at: 0)
        if goalHistory.count > 5 { goalHistory = Array(goalHistory.prefix(5)) }
        UserDefaults.standard.set(goalHistory, forKey: "goalHistory")

        if selectedModel.isConfigured(
            anthropicKey: resolvedAnthropicKey,
            openAIKey: resolvedOpenAIKey
        ) {
            beginAgenticPresentation(for: goal, displayGoal: displayGoal, attachments: attachments)
            chatThread.recordTurn(role: .user, text: displayGoal ?? goal)
            startElapsedTimer()

            let task = Task { [weak self] in
                guard let self else { return }
                await self.runAgentic(
                    goal: goal,
                    attachments: attachments,
                    anthropicAPIKey: resolvedAnthropicKey,
                    openAIKey: resolvedOpenAIKey,
                    selectedModel: selectedModel,
                    conversationHistory: conversationHistory,
                    autonomyMode: autonomyMode
                )
            }
            activeAgenticTask = task
            await task.value
            if activeAgenticTask?.isCancelled == false {
                activeAgenticTask = nil
            }
            stopElapsedTimer()
            return
        }

        let configurationMessage = Self.missingModelCredentialMessage(
            for: selectedModel,
            autonomyMode: autonomyMode
        )

        activeGoal = goal
        activeDisplayGoal = displayGoal ?? goal
        stage = .failed
        statusMessage = "Configure model access"
        criticVerdict = nil
        errorMessage = configurationMessage
        approvedPacketJSON = nil
        elapsedSeconds = 0
        currentPacketID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deploymentState = DeploymentState()

        _ = postRunMessage(
            kind: .userGoal,
            goal: goal,
            text: displayGoal ?? goal,
            attachments: attachments
        )
        _ = postRunMessage(
            kind: .error,
            goal: goal,
            text: configurationMessage
        )
        chatThread.recordTurn(role: .user, text: displayGoal ?? goal)
        chatThread.recordAssistantTurn(text: configurationMessage, thinking: nil, thinkingSignature: nil)
        chatThread.setThinking(false)
        stopElapsedTimer()
        return
    }

    @MainActor
    func attachCompletionIfMatching(epoch: Epoch, goal: String) {
        guard let completionID = currentCompletionMessageID else { return }
        guard goal == activeGoal else { return }
        if let currentPacketID, currentPacketID != epoch.packetID {
            return
        }

        let existingMessage = chatThread.messages.first(where: { $0.id == completionID })
        let existingElapsed = existingMessage?.metrics?.elapsedSeconds ?? elapsedSeconds
        let existingScreenshotPath = existingMessage?.screenshotPath
        let metrics = MessageMetrics(
            higScore: Int((epoch.higScore * 100).rounded()),
            archetype: epoch.archetype ?? "",
            targetFile: epoch.targetFile,
            deviationCost: epoch.deviationCost,
            elapsedSeconds: existingElapsed
        )

        chatThread.updateMessage(id: completionID) { message in
            message.text = Self.completionText(
                targetFile: epoch.targetFile,
                archetype: epoch.archetype,
                higScore: metrics.higScore,
                elapsedSeconds: existingElapsed
            )
            message.detailText = epoch.summary
            message.screenshotPath = epoch.screenshotPath ?? existingScreenshotPath
            message.metrics = metrics
            message.epochID = epoch.id
            message.packetID = epoch.packetID
        }
    }

    @MainActor
    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
        activeAgenticTask?.cancel()
        activeAgenticTask = nil
        Task {
            await StatefulTerminalEngine.shared.interruptActiveCommand()
            await FastlaneDeploymentRunner.shared.cancel()
        }
        stage = .idle
        statusMessage = "Cancelled"
        errorMessage = nil
        activeDisplayGoal = nil
        currentExecutionState = ExecutionState()
        deploymentState = DeploymentState()
        chatThread.setThinking(false)
        stopElapsedTimer()
    }

    @MainActor
    func reset() {
        stage = .idle
        statusMessage = "Ready"
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        elapsedSeconds = 0
        activeDisplayGoal = nil
        currentExecutionState = ExecutionState()
        currentStreamingMessageID = nil
        deploymentState = DeploymentState()
        chatThread.setThinking(false)
    }

    // MARK: - Private

    private func runCouncil(goal: String, apiKey: String?, openAIKey: String? = nil) async -> Result<String, PipelineError> {
        let pkgRoot = packageRoot

        // Run the blocking Process work off the main actor
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["swift", "run", "council", goal, "--drift-out", "/tmp/studio92_drift.json"]
                process.currentDirectoryURL = URL(fileURLWithPath: pkgRoot)

                var env = ProcessInfo.processInfo.environment
                if let key = apiKey, !key.isEmpty {
                    env["ANTHROPIC_API_KEY"] = key
                }
                if let key = openAIKey, !key.isEmpty {
                    env["OPENAI_API_KEY"] = key
                }
                env["STUDIO92_LATEST_APPLE_API_CONTEXT"] = Self.latestAppleAPIContext()
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stdoutBuffer = Data()
                var stderrLineBuffer = ""

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                    stderrLineBuffer += chunk
                    while let newlineIndex = stderrLineBuffer.firstIndex(of: "\n") {
                        let line = String(stderrLineBuffer[stderrLineBuffer.startIndex..<newlineIndex])
                        stderrLineBuffer = String(stderrLineBuffer[stderrLineBuffer.index(after: newlineIndex)...])

                        Task { @MainActor [weak self] in
                            self?.handleCouncilLine(line)
                        }
                    }
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        stdoutBuffer.append(data)
                    }
                }

                Task { @MainActor [weak self] in
                    self?.activeProcess = process
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(PipelineError(message: "Failed to launch council: \(error.localizedDescription)")))
                    return
                }

                process.waitUntilExit()

                Task { @MainActor [weak self] in
                    self?.activeProcess = nil
                }

                // Clear handlers
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                let trailingLine = stderrLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingLine.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleCouncilLine(trailingLine)
                    }
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: .failure(PipelineError(message: "Council exited with status \(process.terminationStatus)")))
                    return
                }

                guard let stdout = String(data: stdoutBuffer, encoding: .utf8) else {
                    continuation.resume(returning: .failure(PipelineError(message: "Could not decode council stdout")))
                    return
                }

                guard let json = PipelineRunner.extractPacketJSON(from: stdout) else {
                    continuation.resume(returning: .failure(PipelineError(message: "No valid packet JSON found in council output")))
                    return
                }

                continuation.resume(returning: .success(json))
            }
        }
    }

    private func runWeaver(packetJSON: String, apiKey: String?, openAIKey: String? = nil) async -> Result<Void, PipelineError> {
        let pkgRoot = packageRoot

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["swift", "run", "weaver", "apply"]
                process.currentDirectoryURL = URL(fileURLWithPath: pkgRoot)

                var env = ProcessInfo.processInfo.environment
                if let key = apiKey, !key.isEmpty {
                    env["ANTHROPIC_API_KEY"] = key
                }
                if let key = openAIKey, !key.isEmpty {
                    env["OPENAI_API_KEY"] = key
                }
                process.environment = env

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stderrLineBuffer = ""

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                    stderrLineBuffer += chunk
                    while let newlineIndex = stderrLineBuffer.firstIndex(of: "\n") {
                        let line = String(stderrLineBuffer[stderrLineBuffer.startIndex..<newlineIndex])
                        stderrLineBuffer = String(stderrLineBuffer[stderrLineBuffer.index(after: newlineIndex)...])

                        Task { @MainActor [weak self] in
                            self?.handleWeaverLine(line)
                        }
                    }
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    _ = handle.availableData
                }

                Task { @MainActor [weak self] in
                    self?.activeProcess = process
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(PipelineError(message: "Failed to launch weaver: \(error.localizedDescription)")))
                    return
                }

                // Feed packet JSON to stdin
                if let data = packetJSON.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                    stdinPipe.fileHandleForWriting.closeFile()
                }

                process.waitUntilExit()

                Task { @MainActor [weak self] in
                    self?.activeProcess = nil
                }

                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                let trailingLine = stderrLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingLine.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleWeaverLine(trailingLine)
                    }
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: .failure(PipelineError(message: "Weaver exited with status \(process.terminationStatus)")))
                    return
                }

                continuation.resume(returning: .success(()))
            }
        }
    }

    // MARK: - Parsing

    @MainActor
    private func beginAgenticPresentation(for goal: String, displayGoal: String?, attachments: [ChatAttachment]) {
        activeGoal = goal
        activeDisplayGoal = displayGoal ?? goal
        stage = .specialistProposing
        statusMessage = "Working..."
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        elapsedSeconds = 0
        currentPacketID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deploymentState = DeploymentState()

        _ = postRunMessage(
            kind: .userGoal,
            goal: goal,
            text: displayGoal ?? goal,
            attachments: attachments
        )
        chatThread.setThinking(true)
    }

    @MainActor
    private func beginPresentation(for goal: String, displayGoal: String?, attachments: [ChatAttachment]) {
        activeGoal = goal
        activeDisplayGoal = displayGoal ?? goal
        stage = .specialistProposing
        statusMessage = "Drafting proposal..."
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        elapsedSeconds = 0
        currentPacketID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deploymentState = DeploymentState()
        currentExecutionState.councilTool = ToolCall(
            toolType: .terminal,
            command: "swift run council",
            status: .active
        )

        _ = postRunMessage(
            kind: .userGoal,
            goal: goal,
            text: displayGoal ?? goal,
            attachments: attachments
        )
        _ = postRunMessage(kind: .acknowledgment, goal: goal, text: Self.acknowledgment(for: displayGoal ?? goal))
        chatThread.setThinking(true)
        refreshExecutionTreeMessage(for: goal)
    }

    @MainActor
    private func beginDeployment(toolCallID: String) {
        deploymentState = DeploymentState(
            phase: .running,
            toolCallID: toolCallID,
            lane: "beta",
            command: nil,
            targetDirectory: packageRoot,
            lines: [],
            startedAt: Date(),
            finishedAt: nil,
            summary: "Preparing TestFlight deployment"
        )
    }

    @MainActor
    private func updateDeploymentCommand(toolCallID: String, command: String) {
        guard deploymentState.toolCallID == toolCallID else { return }
        var updated = deploymentState
        updated.command = command
        updated.summary = command
        deploymentState = updated
    }

    @MainActor
    private func appendDeploymentLine(toolCallID: String, line: String, maxLines: Int = 500) {
        guard deploymentState.toolCallID == toolCallID else { return }
        var updated = deploymentState
        updated.lines.append(line)
        if updated.lines.count > maxLines {
            updated.lines.removeFirst(updated.lines.count - maxLines)
        }
        deploymentState = updated
    }

    @MainActor
    private func completeDeployment(toolCallID: String, result: String, isError: Bool) {
        guard deploymentState.toolCallID == toolCallID else { return }
        var updated = deploymentState
        updated.phase = isError ? .failed : .completed
        updated.finishedAt = Date()
        updated.summary = isError ? "TestFlight deployment failed" : "TestFlight deployment complete"
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = result
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty {
                updated.lines = Array((updated.lines + lines).suffix(500))
            }
        }
        deploymentState = updated
    }

    private func runAgentic(
        goal: String,
        attachments: [ChatAttachment],
        anthropicAPIKey: String?,
        openAIKey: String?,
        selectedModel: StudioModelDescriptor,
        conversationHistory: [ConversationHistoryTurn],
        autonomyMode: AutonomyMode
    ) async {
        let client = AgenticClient(
            apiKey: anthropicAPIKey,
            projectRoot: URL(fileURLWithPath: packageRoot, isDirectory: true),
            openAIKey: openAIKey,
            autonomyMode: autonomyMode
        )

        let messageID = await MainActor.run {
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
            currentStreamingMessageID = message.id
            currentRunMessageIDs.append(message.id)
            chatThread.post(message)
            return message.id
        }

        let preparedInput = await Self.prepareAgenticUserInput(
            goal: goal,
            attachments: attachments
        )
        let requestProfile = Self.agenticRequestProfile(
            for: goal,
            attachments: attachments,
            conversationHistory: conversationHistory,
            model: selectedModel,
            autonomyMode: autonomyMode,
            hasVisualReference: preparedInput.hasVisualReference
        )

        let stream = await client.run(
            system: Self.agenticSystemPrompt(
                projectRoot: packageRoot,
                autonomyMode: autonomyMode,
                hasVisualReference: preparedInput.hasVisualReference
            ),
            userMessage: preparedInput.userMessage,
            userContentBlocks: preparedInput.userContentBlocks,
            initialMessages: Self.agenticHistoryPayload(from: conversationHistory),
            model: selectedModel,
            outputEffort: requestProfile.effort,
            tools: DefaultToolSchemas.all,
            thinking: requestProfile.thinking,
            cacheControl: [
                "type": "ephemeral"
            ]
        )

        var completed = false
        let streamBuffer = StreamBuffer()

        func flushBufferedText() async {
            let chunk = await streamBuffer.flush()
            guard !chunk.isEmpty else { return }

            await MainActor.run {
                stage = .specialistProposing
                statusMessage = "Responding..."
                chatThread.setThinking(false)
                chatThread.appendTextDelta(toMessageID: messageID, text: chunk)
            }
        }

        let textFlushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                await flushBufferedText()
            }
        }
        defer { textFlushTask.cancel() }

        for await event in stream {
            if Task.isCancelled { return }

            if case .textDelta(let text) = event {
                await streamBuffer.append(text)
                continue
            }

            await flushBufferedText()

            let didCompleteEvent = await MainActor.run { () -> Bool in
                switch event {
                case .textDelta:
                    return false

                case .thinkingDelta(let text):
                    stage = .specialistProposing
                    statusMessage = "Thinking..."
                    chatThread.setThinking(false)
                    chatThread.appendThinkingDelta(toMessageID: messageID, text: text)
                    return false

                case .thinkingSignature(let signature):
                    chatThread.setThinkingSignature(toMessageID: messageID, signature: signature)
                    return false

                case .toolCallStart(let id, let name):
                    stage = Self.stage(forToolNamed: name)
                    statusMessage = Self.statusMessage(forToolNamed: name)
                    chatThread.setThinking(false)
                    if name == "deploy_to_testflight" {
                        beginDeployment(toolCallID: id)
                    }
                    chatThread.startStreamingToolCall(
                        messageID: messageID,
                        call: StreamingToolCall(id: id, name: name)
                    )
                    return false

                case .toolCallInputDelta(let id, let partialJSON):
                    chatThread.appendToolCallInput(messageID: messageID, callID: id, json: partialJSON)
                    return false

                case .toolCallCommand(let id, let command):
                    updateDeploymentCommand(toolCallID: id, command: command)
                    chatThread.updateToolCallDisplayCommand(
                        messageID: messageID,
                        callID: id,
                        command: command
                    )
                    return false

                case .toolCallOutput(let id, let line):
                    appendDeploymentLine(toolCallID: id, line: line)
                    chatThread.appendToolCallOutput(
                        messageID: messageID,
                        callID: id,
                        line: line
                    )
                    return false

                case .toolCallResult(let id, let output, let isError):
                    if isError {
                        stage = .failed
                        errorMessage = Self.concise(output)
                    } else {
                        stage = .specialistProposing
                        statusMessage = "Continuing..."
                    }
                    chatThread.completeToolCall(
                        messageID: messageID,
                        callID: id,
                        result: output,
                        isError: isError
                    )
                    completeDeployment(toolCallID: id, result: output, isError: isError)
                    return false

                case .usage(let inputTokens, let outputTokens):
                    chatThread.updateTokenUsage(
                        messageID: messageID,
                        input: inputTokens,
                        output: outputTokens
                    )
                    return false

                case .completed:
                    stage = .succeeded
                    statusMessage = "Complete"
                    errorMessage = nil
                    chatThread.setThinking(false)
                    chatThread.finalizeStreaming(
                        messageID: messageID,
                        finalKind: .assistant,
                        fallbackText: "Done."
                    )
                    if let finalizedMessage = chatThread.messages.first(where: { $0.id == messageID }) {
                        chatThread.recordAssistantTurn(
                            text: finalizedMessage.text.isEmpty ? "Done." : finalizedMessage.text,
                            thinking: finalizedMessage.thinkingText,
                            thinkingSignature: finalizedMessage.thinkingSignature
                        )
                    } else {
                        chatThread.recordAssistantTurn(text: "Done.", thinking: nil, thinkingSignature: nil)
                    }
                    return true

                case .error(let message):
                    stage = .failed
                    statusMessage = "Failed"
                    errorMessage = Self.concise(message)
                    chatThread.setThinking(false)

                    let contentState = chatThread.visibleContentState(forMessageID: messageID)
                    if contentState.hasText || contentState.hasThinking || contentState.hasToolCalls {
                        chatThread.finalizeStreaming(messageID: messageID, finalKind: .assistant)
                        if let finalizedMessage = chatThread.messages.first(where: { $0.id == messageID }) {
                            chatThread.recordAssistantTurn(
                                text: finalizedMessage.text,
                                thinking: finalizedMessage.thinkingText,
                                thinkingSignature: finalizedMessage.thinkingSignature
                            )
                        }
                        _ = postRunMessage(
                            kind: .error,
                            goal: goal,
                            text: "The request failed: \(Self.concise(message))."
                        )
                        chatThread.recordAssistantTurn(
                            text: "The request failed: \(Self.concise(message)).",
                            thinking: nil,
                            thinkingSignature: nil
                        )
                    } else {
                        chatThread.failStreaming(
                            messageID: messageID,
                            errorText: "The request failed: \(Self.concise(message))."
                        )
                        chatThread.recordAssistantTurn(
                            text: "The request failed: \(Self.concise(message)).",
                            thinking: nil,
                            thinkingSignature: nil
                        )
                    }
                    return false
                }
            }

            if didCompleteEvent {
                completed = true
            }
        }

        if Task.isCancelled { return }
        await flushBufferedText()

        let didComplete = completed
        await MainActor.run {
            if !didComplete && stage != .failed {
                stage = .succeeded
                statusMessage = "Complete"
                chatThread.setThinking(false)
                chatThread.finalizeStreaming(
                    messageID: messageID,
                    finalKind: .assistant,
                    fallbackText: "Done."
                )
            }
            activeAgenticTask = nil
        }
    }

    @MainActor
    private func handleCouncilLine(_ line: String) {
        recordCouncilToolOutput(line)
        defer { refreshExecutionTreeMessageIfPossible() }

        if let toolMessage = Self.parseBracketMessage(prefix: "executor", from: line) {
            stage = .executorFixing
            statusMessage = "Repairing the build..."
            currentExecutionState.executor = toolMessage.lowercased().contains("failed after")
                ? .failed
                : toolMessage.lowercased().contains("build fixed")
                    ? .completed
                    : .active
            if currentExecutionState.executorTool == nil {
                currentExecutionState.executorTool = ToolCall(
                    toolType: .terminal,
                    command: "swift run executor",
                    status: .active
                )
            }
            let fallbackStatus = currentExecutionState.executorTool?.status ?? .active
            currentExecutionState.executorTool?.status = Self.inferredToolStatus(
                from: toolMessage,
                fallback: fallbackStatus
            )
            if currentRunNarrativeCount == 0 {
                postNarrativeMessage(
                    kind: .stageUpdate,
                    key: "executor-running",
                    text: "Build failed — fixing it automatically."
                )
            }
            return
        }

        guard let event = Self.parseCouncilEvent(from: line) else { return }

        switch event.role.lowercased() {
        case "specialist":
            stage = .specialistProposing
            switch event.step {
            case "SPECIALIST_CALL":
                statusMessage = "Drafting proposal..."
                currentExecutionState.specialist = .active
            case "BUS_ACCEPTED":
                statusMessage = "Proposal passed safety checks."
                currentExecutionState.specialist = .completed
            case "BUS_REJECTED":
                statusMessage = "Proposal needs another pass."
                currentExecutionState.specialist = .warning
            case "SPECIALIST_PARSE_FAIL", "SPECIALIST_API_ERROR":
                statusMessage = "Refining the proposal..."
                currentExecutionState.specialist = .warning
            case "ABORT":
                statusMessage = "Stopping the run..."
                currentExecutionState.specialist = .failed
            default:
                statusMessage = "Drafting proposal..."
                currentExecutionState.specialist = .active
            }

        case "critic":
            stage = .criticAuditing
            switch event.step {
            case "CRITIC_CALL":
                statusMessage = "The Critic is reviewing the design."
                if currentExecutionState.specialist == .active {
                    currentExecutionState.specialist = .completed
                }
                currentExecutionState.critic = .active
                postNarrativeMessage(
                    kind: .stageUpdate,
                    key: "critic-review",
                    text: "The Critic is reviewing the design."
                )

            case "CRITIC_VERDICT":
                let verdict = Self.criticFeedbackText(from: event.outcome)
                criticVerdict = verdict
                statusMessage = verdict

                switch Self.parseIntentAndScore(from: event.outcome).intent {
                case "approve":
                    currentExecutionState.critic = .completed
                    postNarrativeMessage(
                        kind: .criticFeedback,
                        key: "critic-approve",
                        text: verdict
                    )
                case "amend":
                    currentExecutionState.critic = .warning
                    currentExecutionState.specialist = .active
                    postNarrativeMessage(
                        kind: .criticFeedback,
                        key: "critic-amend",
                        text: verdict
                    )
                case "reject":
                    currentExecutionState.critic = .failed
                    postNarrativeMessage(
                        kind: .criticFeedback,
                        key: "critic-reject",
                        text: verdict,
                        force: true
                    )
                default:
                    currentExecutionState.critic = .active
                }

            case "CRITIC_AMEND":
                statusMessage = "Revising the proposal."
                currentExecutionState.critic = .warning
                currentExecutionState.specialist = .active

            case "CRITIC_PARSE_FAIL", "CRITIC_API_ERROR":
                statusMessage = "Rechecking the review..."
                currentExecutionState.critic = .warning

            default:
                statusMessage = "The Critic is reviewing the design."
                currentExecutionState.critic = .active
            }

        case "architect":
            stage = .architectMerging
            switch event.step {
            case "ARCHITECT_CALL":
                statusMessage = "Locking this direction in."
                if currentExecutionState.critic == .active {
                    currentExecutionState.critic = .completed
                }
                currentExecutionState.architect = .active

            case "ARCHITECT_VERDICT":
                let intent = Self.parseIntentAndScore(from: event.outcome).intent
                if intent == "reject" {
                    statusMessage = "The Architect blocked this direction."
                    currentExecutionState.architect = .failed
                } else {
                    statusMessage = "Direction approved."
                    currentExecutionState.architect = .completed
                }

            case "ARCHITECT_PARSE_FAIL":
                statusMessage = "Architect output needed recovery."
                currentExecutionState.architect = .warning

            case "ARCHITECT_API_ERROR":
                statusMessage = "The Architect could not complete the merge."
                currentExecutionState.architect = .failed

            default:
                statusMessage = "Locking this direction in."
                if currentExecutionState.architect == .pending {
                    currentExecutionState.architect = .active
                }
            }

        default:
            break
        }

        currentExecutionState.councilTool?.status = aggregateStatus(
            for: [
                currentExecutionState.specialist,
                currentExecutionState.critic,
                currentExecutionState.architect
            ]
        )
    }

    @MainActor
    private func handleWeaverLine(_ line: String) {
        recordWeaverToolOutput(line)
        defer { refreshExecutionTreeMessageIfPossible() }

        if let verifyMessage = Self.parseBracketMessage(prefix: "verify", from: line) {
            stage = .verifying
            statusMessage = "Verifying the build..."
            currentExecutionState.verify = verifyMessage.lowercased().contains("failed")
                ? .failed
                : verifyMessage.lowercased().contains("passed")
                    ? .completed
                    : .active
            if currentRunNarrativeCount == 0 {
                postNarrativeMessage(
                    kind: .stageUpdate,
                    key: "verify-build",
                    text: "I’m verifying the build now."
                )
            }
            return
        }

        guard let message = Self.parseBracketMessage(prefix: "weaver", from: line) else { return }

        stage = .weaving
        if currentExecutionState.architect == .active {
            currentExecutionState.architect = .completed
        }

        let lowercased = message.lowercased()
        switch true {
        case lowercased.hasPrefix("fatal:"):
            statusMessage = "Applying changes failed."
            currentExecutionState.weaver = .failed

        case lowercased.hasPrefix("applying packet"):
            statusMessage = "Applying approved changes..."
            currentExecutionState.weaver = .active

        case lowercased.hasPrefix("created:"):
            statusMessage = "Applying approved changes..."
            currentExecutionState.weaver = .active
            currentExecutionState.weaverTitle = "Create \(Self.trailingPathComponent(from: message))"

        case lowercased.hasPrefix("replaced"):
            statusMessage = "Applying approved changes..."
            currentExecutionState.weaver = .active
            currentExecutionState.weaverTitle = "Replace \(Self.trailingPathComponent(from: message))"

        case lowercased.hasPrefix("patched"):
            statusMessage = "Applying approved changes..."
            currentExecutionState.weaver = .active
            currentExecutionState.weaverTitle = "Patch \(Self.trailingPathComponent(from: message))"

        case lowercased.contains("weave complete"):
            statusMessage = "Changes applied."
            currentExecutionState.weaver = .completed

        default:
            statusMessage = "Applying approved changes..."
        }

        currentExecutionState.weaverTool?.status = currentExecutionState.weaver
    }

    @MainActor
    private func finishRunSuccessfully(goal: String, packet: PacketSummary) {
        stage = .succeeded
        statusMessage = "Complete"
        errorMessage = nil
        chatThread.setThinking(false)

        currentExecutionState.specialist = .completed
        currentExecutionState.critic = .completed
        currentExecutionState.architect = .completed
        currentExecutionState.weaver = .completed
        if currentExecutionState.verify == .active {
            currentExecutionState.verify = .completed
        }
        if currentExecutionState.executor == .active {
            currentExecutionState.executor = .completed
        }
        let finalizedCouncilTool = Self.finalizedToolCallIfNeeded(currentExecutionState.councilTool)
        let finalizedWeaverTool = Self.finalizedToolCallIfNeeded(currentExecutionState.weaverTool)
        let finalizedExecutorTool = Self.finalizedToolCallIfNeeded(currentExecutionState.executorTool)
        let finalizedWebSearchTool = Self.finalizedToolCallIfNeeded(currentExecutionState.webSearchTool)
        let finalizedWebFetchTool = Self.finalizedToolCallIfNeeded(currentExecutionState.webFetchTool)
        currentExecutionState.councilTool = finalizedCouncilTool
        currentExecutionState.weaverTool = finalizedWeaverTool
        currentExecutionState.executorTool = finalizedExecutorTool
        currentExecutionState.webSearchTool = finalizedWebSearchTool
        currentExecutionState.webFetchTool = finalizedWebFetchTool
        refreshExecutionTreeMessage(for: goal)

        let message = ChatMessage(
            kind: .completion,
            goal: goal,
            text: Self.completionText(
                targetFile: packet.payload.targetFile,
                archetype: packet.payload.archetypeClassification?.dominant,
                higScore: Int((packet.metrics.higComplianceScore * 100).rounded()),
                elapsedSeconds: elapsedSeconds
            ),
            detailText: packet.payload.rationale,
            timestamp: Date(),
            screenshotPath: Self.resolveScreenshotPath(for: packet.packetID),
            metrics: MessageMetrics(
                higScore: Int((packet.metrics.higComplianceScore * 100).rounded()),
                archetype: packet.payload.archetypeClassification?.dominant ?? "",
                targetFile: packet.payload.targetFile,
                deviationCost: packet.metrics.deviationBudgetCost,
                elapsedSeconds: elapsedSeconds
            ),
            executionTree: nil,
            epochID: nil,
            packetID: packet.packetID
        )

        currentCompletionMessageID = message.id
        chatThread.post(message)
        chatThread.recordTurn(role: .assistant, text: message.text)
    }

    @MainActor
    private func failRun(goal: String, message: String) {
        stage = .failed
        errorMessage = Self.concise(message)
        chatThread.setThinking(false)
        markFailureInExecutionTree()
        markToolCallsFailed()
        refreshExecutionTreeMessage(for: goal)

        let errorText = "The run stopped before completion: \(Self.concise(message))."
        _ = postRunMessage(kind: .error, goal: goal, text: errorText)
        chatThread.recordTurn(role: .assistant, text: errorText)
    }

    @MainActor
    private func markFailureInExecutionTree() {
        switch stage {
        case .specialistProposing, .idle:
            currentExecutionState.specialist = .failed
        case .researching:
            currentExecutionState.webSearchTool?.status = .failed
        case .criticAuditing:
            currentExecutionState.critic = .failed
        case .architectMerging:
            currentExecutionState.architect = .failed
        case .weaving:
            currentExecutionState.weaver = .failed
        case .verifying:
            currentExecutionState.verify = .failed
        case .executorFixing:
            currentExecutionState.executor = .failed
        case .succeeded, .failed:
            if currentExecutionState.weaver == .active {
                currentExecutionState.weaver = .failed
            } else if currentExecutionState.architect == .active {
                currentExecutionState.architect = .failed
            } else if currentExecutionState.critic == .active {
                currentExecutionState.critic = .failed
            } else {
                currentExecutionState.specialist = .failed
            }
        }
    }

    @MainActor
    private func postNarrativeMessage(
        kind: ChatMessage.Kind,
        key: String,
        text: String,
        force: Bool = false
    ) {
        guard !emittedNarrativeKeys.contains(key) else { return }
        guard force || currentRunNarrativeCount < 2 else { return }

        emittedNarrativeKeys.insert(key)
        currentRunNarrativeCount += 1
        _ = postRunMessage(kind: kind, goal: activeGoal ?? "", text: text)
    }

    @MainActor
    @discardableResult
    private func postRunMessage(
        kind: ChatMessage.Kind,
        goal: String,
        text: String,
        detailText: String? = nil,
        screenshotPath: String? = nil,
        metrics: MessageMetrics? = nil,
        executionTree: [ExecutionStep]? = nil,
        attachments: [ChatAttachment] = []
    ) -> UUID {
        let message = ChatMessage(
            kind: kind,
            goal: goal,
            text: text,
            detailText: detailText,
            timestamp: Date(),
            screenshotPath: screenshotPath,
            metrics: metrics,
            executionTree: executionTree,
            attachments: attachments,
            epochID: nil,
            packetID: currentPacketID
        )
        currentRunMessageIDs.append(message.id)
        chatThread.post(message)
        return message.id
    }

    @MainActor
    private func refreshExecutionTreeMessage(for goal: String) {
        let tree = makeExecutionTree()
        if let messageID = currentExecutionTreeMessageID {
            chatThread.updateMessage(id: messageID) { message in
                message.executionTree = tree
            }
        } else {
            currentExecutionTreeMessageID = postRunMessage(
                kind: .executionTree,
                goal: goal,
                text: "Execution",
                executionTree: tree
            )
        }
    }

    @MainActor
    private func refreshExecutionTreeMessageIfPossible() {
        guard let activeGoal else { return }
        refreshExecutionTreeMessage(for: activeGoal)
    }

    @MainActor
    private func assignPacketIDToCurrentRun(_ packetID: UUID) {
        for messageID in currentRunMessageIDs {
            chatThread.updateMessage(id: messageID) { message in
                message.packetID = packetID
            }
        }
    }

    @MainActor
    private func ensureCouncilTool() {
        if currentExecutionState.councilTool == nil {
            currentExecutionState.councilTool = ToolCall(
                toolType: .terminal,
                command: "swift run council",
                status: .active
            )
        }
    }

    private func runResearcher(goal: String, openAIKey: String? = nil) async -> Result<Void, PipelineError> {
        let pkgRoot = packageRoot

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                Self.writeContextPack("")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", "Factory/researcher.py", goal]
                process.currentDirectoryURL = URL(fileURLWithPath: pkgRoot)

                var env = ProcessInfo.processInfo.environment
                if let key = openAIKey, !key.isEmpty {
                    env["OPENAI_API_KEY"] = key
                }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stdoutLineBuffer = ""
                var stderrLineBuffer = ""

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    stdoutLineBuffer += chunk
                    while let newlineIndex = stdoutLineBuffer.firstIndex(of: "\n") {
                        let line = String(stdoutLineBuffer[stdoutLineBuffer.startIndex..<newlineIndex])
                        stdoutLineBuffer = String(stdoutLineBuffer[stdoutLineBuffer.index(after: newlineIndex)...])

                        Task { @MainActor [weak self] in
                            self?.handleResearcherLine(line)
                        }
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    stderrLineBuffer += chunk
                    while let newlineIndex = stderrLineBuffer.firstIndex(of: "\n") {
                        let line = String(stderrLineBuffer[stderrLineBuffer.startIndex..<newlineIndex])
                        stderrLineBuffer = String(stderrLineBuffer[stderrLineBuffer.index(after: newlineIndex)...])

                        Task { @MainActor [weak self] in
                            self?.handleResearcherLine(line)
                        }
                    }
                }

                Task { @MainActor [weak self] in
                    self?.stage = .researching
                    self?.statusMessage = "Fetching latest Apple docs..."
                    self?.currentExecutionState.webSearchTool = ToolCall(
                        toolType: .webSearch,
                        command: "Fetching Latest Apple Docs",
                        status: .active
                    )
                    self?.refreshExecutionTreeMessageIfPossible()
                    self?.activeProcess = process
                }

                do {
                    try process.run()
                } catch {
                    Self.writeContextPack("")
                    Task { @MainActor [weak self] in
                        self?.handleResearcherLaunchFailure(error)
                    }
                    continuation.resume(returning: .failure(PipelineError(message: "Failed to launch researcher: \(error.localizedDescription)")))
                    return
                }

                process.waitUntilExit()

                Task { @MainActor [weak self] in
                    self?.activeProcess = nil
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let trailingStdout = stdoutLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingStdout.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleResearcherLine(trailingStdout)
                    }
                }

                let trailingStderr = stderrLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingStderr.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.handleResearcherLine(trailingStderr)
                    }
                }

                guard process.terminationStatus == 0 else {
                    Self.writeContextPack("")
                    continuation.resume(returning: .failure(PipelineError(message: "Researcher exited with status \(process.terminationStatus)")))
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.currentExecutionState.webSearchTool?.status == .active {
                        self.currentExecutionState.webSearchTool?.status = .completed
                        self.refreshExecutionTreeMessageIfPossible()
                    }
                }

                continuation.resume(returning: .success(()))
            }
        }
    }

    @MainActor
    private func handleResearcherLine(_ line: String) {
        guard let normalizedLine = Self.normalizedToolOutput(line) else { return }

        if currentExecutionState.webSearchTool == nil {
            currentExecutionState.webSearchTool = ToolCall(
                toolType: .webSearch,
                command: "Fetching Latest Apple Docs",
                status: .active
            )
        }

        let updatedWebSearchTool = Self.appendingToolLine(
            normalizedLine,
            to: currentExecutionState.webSearchTool,
            maxLines: maxToolOutputLines
        )
        currentExecutionState.webSearchTool = updatedWebSearchTool

        if normalizedLine == "[Researcher] Context pack built." {
            statusMessage = "Latest Apple API context ready."
            currentExecutionState.webSearchTool?.status = .completed
        } else if let message = Self.parseBracketMessage(prefix: "web-search", from: normalizedLine) {
            statusMessage = "Fetching latest Apple docs..."
            let fallbackStatus = currentExecutionState.webSearchTool?.status ?? .active
            currentExecutionState.webSearchTool?.status = Self.inferredToolStatus(
                from: message,
                fallback: fallbackStatus
            )
        }

        refreshExecutionTreeMessageIfPossible()
    }

    @MainActor
    private func handleResearcherLaunchFailure(_ error: Error) {
        statusMessage = "Researcher unavailable."
        currentExecutionState.webSearchTool = ToolCall(
            toolType: .webSearch,
            command: "Fetching Latest Apple Docs",
            status: .warning,
            liveOutput: ["Failed to launch researcher: \(error.localizedDescription)"]
        )
        refreshExecutionTreeMessageIfPossible()
    }

    @MainActor
    private func recordCouncilToolOutput(_ line: String) {
        guard let normalizedLine = Self.normalizedToolOutput(line) else { return }

        if let executorMessage = Self.parseBracketMessage(prefix: "executor", from: normalizedLine) {
            if currentExecutionState.executorTool == nil {
                currentExecutionState.executorTool = ToolCall(
                    toolType: .terminal,
                    command: "swift run executor",
                    status: .active
                )
            }
            let updatedExecutorTool = Self.appendingToolLine(
                normalizedLine,
                to: currentExecutionState.executorTool,
                maxLines: maxToolOutputLines
            )
            currentExecutionState.executorTool = updatedExecutorTool
            let fallbackStatus = currentExecutionState.executorTool?.status ?? .active
            currentExecutionState.executorTool?.status = Self.inferredToolStatus(
                from: executorMessage,
                fallback: fallbackStatus
            )
            return
        }

        if routeWebToolOutput(from: normalizedLine) {
            return
        }

        ensureCouncilTool()
        let updatedCouncilTool = Self.appendingToolLine(
            normalizedLine,
            to: currentExecutionState.councilTool,
            maxLines: maxToolOutputLines
        )
        currentExecutionState.councilTool = updatedCouncilTool
    }

    @MainActor
    private func recordWeaverToolOutput(_ line: String) {
        guard let normalizedLine = Self.normalizedToolOutput(line) else { return }

        if routeWebToolOutput(from: normalizedLine) {
            return
        }

        if currentExecutionState.weaverTool == nil {
            currentExecutionState.weaverTool = ToolCall(
                toolType: .terminal,
                command: "swift run weaver apply",
                status: .active
            )
        }
        let updatedWeaverTool = Self.appendingToolLine(
            normalizedLine,
            to: currentExecutionState.weaverTool,
            maxLines: maxToolOutputLines
        )
        currentExecutionState.weaverTool = updatedWeaverTool
    }

    @MainActor
    @discardableResult
    private func routeWebToolOutput(from line: String) -> Bool {
        let searchPrefixes = ["web-search", "web_search"]
        let fetchPrefixes = ["web-fetch", "web_fetch"]

        for prefix in searchPrefixes {
            if let message = Self.parseBracketMessage(prefix: prefix, from: line) {
                upsertWebTool(type: .webSearch, command: message, rawLine: line)
                return true
            }
        }

        for prefix in fetchPrefixes {
            if let message = Self.parseBracketMessage(prefix: prefix, from: line) {
                upsertWebTool(type: .webFetch, command: message, rawLine: line)
                return true
            }
        }

        return false
    }

    @MainActor
    private func upsertWebTool(type: ToolType, command: String, rawLine: String) {
        switch type {
        case .webSearch:
            if currentExecutionState.webSearchTool == nil {
                currentExecutionState.webSearchTool = ToolCall(
                    toolType: .webSearch,
                    command: command,
                    status: .active
                )
            }
            let fallbackStatus = currentExecutionState.webSearchTool?.status ?? .active
            currentExecutionState.webSearchTool?.status = Self.inferredToolStatus(
                from: command,
                fallback: fallbackStatus
            )
            let updatedWebSearchTool = Self.appendingToolLine(
                rawLine,
                to: currentExecutionState.webSearchTool,
                maxLines: maxToolOutputLines
            )
            currentExecutionState.webSearchTool = updatedWebSearchTool

        case .webFetch:
            if currentExecutionState.webFetchTool == nil {
                currentExecutionState.webFetchTool = ToolCall(
                    toolType: .webFetch,
                    command: command,
                    status: .active
                )
            }
            let fallbackStatus = currentExecutionState.webFetchTool?.status ?? .active
            currentExecutionState.webFetchTool?.status = Self.inferredToolStatus(
                from: command,
                fallback: fallbackStatus
            )
            let updatedWebFetchTool = Self.appendingToolLine(
                rawLine,
                to: currentExecutionState.webFetchTool,
                maxLines: maxToolOutputLines
            )
            currentExecutionState.webFetchTool = updatedWebFetchTool

        case .terminal, .fileRead, .fileWrite, .filePatch, .listFiles:
            break
        }
    }

    private static func appendingToolLine(
        _ line: String,
        to toolCall: ToolCall?,
        maxLines: Int
    ) -> ToolCall? {
        guard let normalizedLine = normalizedToolOutput(line) else { return toolCall }
        guard var toolCall else { return nil }

        toolCall.liveOutput.append(normalizedLine)
        if toolCall.liveOutput.count > maxLines {
            toolCall.liveOutput.removeFirst(toolCall.liveOutput.count - maxLines)
        }
        return toolCall
    }

    private static func finalizedToolCallIfNeeded(_ toolCall: ToolCall?) -> ToolCall? {
        guard var toolCall else { return nil }
        switch toolCall.status {
        case .pending, .active, .warning:
            toolCall.status = .completed
        case .completed, .failed:
            break
        }
        return toolCall
    }

    private static func failedToolCallIfNeeded(_ toolCall: ToolCall?) -> ToolCall? {
        guard var toolCall else { return nil }
        switch toolCall.status {
        case .pending, .active, .warning:
            toolCall.status = .failed
        case .completed, .failed:
            break
        }
        return toolCall
    }

    @MainActor
    private func markToolCallsFailed() {
        let failedCouncilTool = Self.failedToolCallIfNeeded(currentExecutionState.councilTool)
        let failedWeaverTool = Self.failedToolCallIfNeeded(currentExecutionState.weaverTool)
        let failedExecutorTool = Self.failedToolCallIfNeeded(currentExecutionState.executorTool)
        let failedWebSearchTool = Self.failedToolCallIfNeeded(currentExecutionState.webSearchTool)
        let failedWebFetchTool = Self.failedToolCallIfNeeded(currentExecutionState.webFetchTool)
        currentExecutionState.councilTool = failedCouncilTool
        currentExecutionState.weaverTool = failedWeaverTool
        currentExecutionState.executorTool = failedExecutorTool
        currentExecutionState.webSearchTool = failedWebSearchTool
        currentExecutionState.webFetchTool = failedWebFetchTool
    }

    private func makeExecutionTree() -> [ExecutionStep] {
        let councilChildren = [
            ExecutionStep(
                id: "specialist",
                title: currentExecutionState.specialistTitle,
                role: "Specialist",
                status: currentExecutionState.specialist
            ),
            ExecutionStep(
                id: "critic",
                title: currentExecutionState.criticTitle,
                role: "Critic",
                status: currentExecutionState.critic
            ),
            ExecutionStep(
                id: "architect",
                title: currentExecutionState.architectTitle,
                role: "Architect",
                status: currentExecutionState.architect
            )
        ]

        var pipelineChildren: [ExecutionStep] = [
            ExecutionStep(
                id: "researcher",
                title: "Live Apple API context",
                role: "Researcher",
                status: currentExecutionState.webSearchTool?.status ?? .pending,
                toolCall: currentExecutionState.webSearchTool
            ),
            ExecutionStep(
                id: "council",
                title: "Council review",
                role: "Council",
                status: aggregateStatus(for: councilChildren.map(\.status)),
                toolCall: currentExecutionState.councilTool,
                children: councilChildren
            ),
            ExecutionStep(
                id: "weaver",
                title: currentExecutionState.weaverTitle,
                role: "Weaver",
                status: currentExecutionState.weaver,
                toolCall: currentExecutionState.weaverTool
            )
        ]

        if let webFetchTool = currentExecutionState.webFetchTool {
            pipelineChildren.append(
                ExecutionStep(
                    id: "web-fetch",
                    title: "Web fetch",
                    role: "Web",
                    status: webFetchTool.status,
                    toolCall: webFetchTool
                )
            )
        }

        if let verify = currentExecutionState.verify {
            pipelineChildren.append(
                ExecutionStep(
                    id: "verify",
                    title: "Verify build",
                    role: "Verifier",
                    status: verify
                )
            )
        }

        if let executor = currentExecutionState.executor {
            pipelineChildren.append(
                ExecutionStep(
                    id: "executor",
                    title: "Automatic repair",
                    role: "Executor",
                    status: executor,
                    toolCall: currentExecutionState.executorTool
                )
            )
        }

        return [
            ExecutionStep(
                id: "pipeline",
                title: "Pipeline run",
                role: "Pipeline",
                status: aggregateStatus(for: pipelineChildren.map(\.status)),
                children: pipelineChildren
            )
        ]
    }

    private func aggregateStatus(for statuses: [StepStatus]) -> StepStatus {
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.active) { return .active }
        if statuses.allSatisfy({ $0 == .completed }) { return .completed }
        if statuses.contains(.warning) { return .warning }
        if statuses.contains(.completed) { return .active }
        return .pending
    }

    private static func normalizedToolOutput(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func inferredToolStatus(from message: String, fallback: StepStatus) -> StepStatus {
        let lowercased = message.lowercased()

        if lowercased.contains("starting") ||
            lowercased.contains("running") ||
            lowercased.contains("reading") ||
            lowercased.contains("applying") ||
            lowercased.contains("fetching") ||
            lowercased.contains("searching") {
            return .active
        }

        if lowercased.contains("fatal") ||
            lowercased.contains("failed") ||
            lowercased.contains("error") {
            return .failed
        }

        if lowercased.contains("fixed") ||
            lowercased.contains("complete") ||
            lowercased.contains("completed") ||
            lowercased.contains("passed") ||
            lowercased.contains("succeeded") ||
            lowercased.contains("success") {
            return .completed
        }

        if lowercased.contains("warning") {
            return .warning
        }

        switch fallback {
        case .completed, .failed:
            return fallback
        case .pending, .active, .warning:
            return .active
        }
    }

    private static func latestAppleAPIContext() -> String {
        let path = NSString(string: "~/.darkfactory/context_pack.txt").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeContextPack(_ contents: String) {
        let path = NSString(string: "~/.darkfactory/context_pack.txt").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func agenticSystemPrompt(
        projectRoot: String,
        autonomyMode: AutonomyMode,
        hasVisualReference: Bool = false
    ) -> String {
        let latestContext = latestAppleAPIContext()
        let temporalContext = currentTemporalContext()
        let latestContextSection = latestContext.isEmpty
            ? ""
            : """

            ### LATEST APPLE API CONTEXT (USE THIS STRICTLY) ###
            \(latestContext)
            """

        let autonomySection: String = {
            switch autonomyMode {
            case .plan:
                return """

                ### AUTONOMY MODE: PLAN ###
                - You are in read-only planning mode.
                - You may use `list_files`, `file_read`, and `web_search`.
                - Do not attempt `file_write`, `file_patch`, or `terminal`.
                - Deliver plans, grounded analysis, and proposed code in the conversation only.
                """
            case .review:
                return """

                ### AUTONOMY MODE: REVIEW ###
                - You may inspect files, search, and use the terminal when verification reduces guesswork.
                - Do not directly modify files with `file_write` or `file_patch`.
                - When proposing code changes, present complete code blocks in the conversation so the user can review and approve the diff.
                """
            case .fullSend:
                return """

                ### AUTONOMY MODE: FULLSEND ###
                - You may inspect, edit, verify, and use the terminal autonomously.
                - Prefer grounded tool use and keep the user informed concisely.
                - If you present code blocks in the conversation, they will be auto-applied.
                """
            }
        }()

        let visionDirective = hasVisualReference
            ? """

            ### VISION DIRECTIVE ###
            You have been provided with a visual reference. You are a master Apple HIG UI/UX engineer. Analyze the attached interface. Recreate this exact visual hierarchy, layout, and aesthetic using native SwiftUI. Infer paddings, corner radii, and semantic colors (using Apple standard gray/system colors where appropriate). Do not use placeholder geometry; write the production-ready view structure.
            """
            : ""

        return """
        You are Studio.92, a senior Apple platforms engineer working directly inside a real local workspace at \(projectRoot).
        \(temporalContext)

        The user is collaborating with you inside a native macOS command center. Think and communicate like a calm senior engineer shipping real product work with a peer.

        Working style:
        - Use tools when they reduce guesswork.
        - Speak naturally, but concisely.
        - The UI already shows file operations and terminal activity, so you usually do not need to announce routine reads, scans, or commands.
        - Use text for architectural decisions, trade-offs, milestone summaries, and clarifying questions.
        - Start your first visible response with one short natural sentence. Do not restate the full user prompt back verbatim.
        - When asked to build or change a feature, begin with a concise markdown checklist plan using standard syntax like `- [ ] Task`.
        - Keep the plan to 2-4 high-signal tasks maximum.
        - Do not include routine inspection, file discovery, or workspace scanning as plan items.
        - Start narrow. Do not scan or read the whole repository by default.
        - Before editing existing files, inspect only the most relevant entry points, target files, or directories tied to the request.
        - Limit initial inspection to a small focused set unless the first pass proves insufficient.
        - Use `list_files` and `file_read` surgically; broaden outward only when a tool result shows you still lack needed context.
        - Do not inspect unrelated shared libraries, design systems, or framework folders unless the request clearly depends on them or the first pass fails to reveal what you need.
        - Use `delegate_to_explorer` when you need broad read-only context across multiple files or directories before writing.
        - Use `delegate_to_reviewer` when you want a terse second-pass audit on specific files for bugs, performance, or HIG issues.
        - Delegated workers are internal specialists. Use them when they materially reduce main-context noise, then absorb their findings and summarize them in your own voice.
        - Use `file_patch` for focused changes and `file_write` when creating or replacing files intentionally.
        - Use `terminal` when shell inspection, builds, tests, or project verification would reduce guesswork. Provide the outcome you want; the terminal executor will choose the exact commands.
        - Never claim you changed, verified, or inspected something unless a tool result proves it.
        - Keep replies calm and product-focused. Do not mention hidden orchestration, councils, or internal agent roles.
        - Let the UI carry routine process. Use prose when it helps the user understand why something matters.
        - After tool work, summarize what changed, what you verified, and any meaningful caveats.
        - Do not dump raw file inventories, path lists, or verification transcripts unless the user explicitly asks for them.
        - Final summaries should be compact and readable.
        - Do not use Markdown tables. Use short paragraphs, bullets, or numbered lists instead.
        - Use Markdown when it improves scanability.
        \(autonomySection)
        \(visionDirective)
        \(latestContextSection)
        """
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

    private static func missingModelCredentialMessage(
        for model: StudioModelDescriptor,
        autonomyMode: AutonomyMode
    ) -> String {
        let modeLine = "\(autonomyMode.title) mode is routed to \(model.displayName)."
        let providerLine = "Add \(model.provider.environmentVariableName) in Settings, or export it in the app environment."

        switch autonomyMode {
        case .plan, .review:
            return "\(modeLine) \(providerLine)"
        case .fullSend:
            return "\(modeLine) \(providerLine) Full Send relies on GPT-5.4 as the primary operator."
        }
    }

    private struct PreparedAgenticUserInput {
        let userMessage: String
        let userContentBlocks: [[String: Any]]?
        let hasVisualReference: Bool
    }

    private struct AgenticRequestProfile {
        let effort: String
        let thinking: [String: Any]?
    }

    private static func agenticRequestProfile(
        for goal: String,
        attachments: [ChatAttachment],
        conversationHistory: [ConversationHistoryTurn],
        model: StudioModelDescriptor,
        autonomyMode: AutonomyMode,
        hasVisualReference: Bool
    ) -> AgenticRequestProfile {
        let normalizedGoal = goal.lowercased()
        let referencesFileCount = attachments.filter { !$0.isImage }.count
        let imageReferenceCount = attachments.filter(\.isImage).count
        let hasEscalationSignal = Self.orchestrationEscalationSignals.contains { normalizedGoal.contains($0) }
        let hasWideContext = referencesFileCount >= 3 || imageReferenceCount >= 2 || conversationHistory.count >= 8
        let isLongDirective = normalizedGoal.count >= 280
        let isFirstTurn = conversationHistory.isEmpty

        let shouldFavorSpeed = model.role == .review
            && isFirstTurn
            && !hasVisualReference
            && referencesFileCount == 0
            && imageReferenceCount == 0
            && !hasEscalationSignal
            && !isLongDirective
            && autonomyMode != .fullSend

        let shouldUseAdaptiveThinking = model.provider == .anthropic
            && (
                model.role == .escalation
            || hasEscalationSignal
            || hasWideContext
            || hasVisualReference
            || referencesFileCount > 0
            || imageReferenceCount > 0
            )

        let effort: String = {
            switch model.provider {
            case .anthropic:
                if model.role == .escalation {
                    return "high"
                }
                return shouldFavorSpeed ? "low" : "medium"
            case .openAI:
                if hasEscalationSignal || hasWideContext || hasVisualReference || referencesFileCount >= 2 {
                    return "high"
                }
                if autonomyMode == .fullSend && isLongDirective {
                    return "xhigh"
                }
                return model.defaultReasoningEffort ?? "medium"
            }
        }()

        return AgenticRequestProfile(
            effort: effort,
            thinking: shouldUseAdaptiveThinking ? ["type": "adaptive"] : nil
        )
    }

    private static func prepareAgenticUserInput(
        goal: String,
        attachments: [ChatAttachment]
    ) async -> PreparedAgenticUserInput {
        guard let imageAttachment = attachments.first(where: { $0.isImage }),
              let imageBlock = await VisionPayloadBuilder.imageContentBlock(from: imageAttachment.url) else {
            return PreparedAgenticUserInput(
                userMessage: goal,
                userContentBlocks: nil,
                hasVisualReference: false
            )
        }

        return PreparedAgenticUserInput(
            userMessage: goal,
            userContentBlocks: [
                [
                    "type": "text",
                    "text": goal
                ],
                imageBlock
            ],
            hasVisualReference: true
        )
    }

    private static func stage(forToolNamed name: String) -> PipelineStage {
        switch name {
        case "terminal", "deploy_to_testflight":
            return .executorFixing
        case "web_search":
            return .researching
        case "delegate_to_explorer":
            return .researching
        case "delegate_to_reviewer":
            return .criticAuditing
        case "delegate_to_worktree":
            return .architectMerging
        case "file_write", "file_patch":
            return .weaving
        default:
            return .specialistProposing
        }
    }

    private static func statusMessage(forToolNamed name: String) -> String {
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

    private static func agenticHistoryPayload(from turns: [ConversationHistoryTurn]) -> [[String: Any]] {
        turns.map { turn in
            let role = turn.role == .user ? "user" : "assistant"

            if let contentBlocks = turn.contentBlocks, !contentBlocks.isEmpty {
                let encodedBlocks: [[String: Any]] = contentBlocks.compactMap { block in
                    switch block {
                    case .text(let text):
                        return [
                            "type": "text",
                            "text": text
                        ]
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

    func executePersistentShellCommand(
        _ command: String,
        displayCommand: String? = nil
    ) async -> StepStatus {
        let presentedCommand = (displayCommand ?? command).trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run {
            stage = .executorFixing
            statusMessage = "Running \(presentedCommand)..."
            currentExecutionState.executor = .active
            currentExecutionState.executorTool = ToolCall(
                toolType: .terminal,
                command: presentedCommand,
                status: .active
            )
            refreshExecutionTreeMessageIfPossible()
        }

        let stream = await StatefulTerminalEngine.shared.execute(command)

        for await line in stream {
            await MainActor.run {
                let updatedExecutorTool = Self.appendingToolLine(
                    line,
                    to: currentExecutionState.executorTool,
                    maxLines: maxToolOutputLines
                )
                currentExecutionState.executorTool = updatedExecutorTool
                refreshExecutionTreeMessageIfPossible()
            }
        }

        let exitStatus = await StatefulTerminalEngine.shared.lastExitStatus()
        let finalStatus: StepStatus = exitStatus == 0 ? .completed : .failed

        await MainActor.run {
            currentExecutionState.executor = finalStatus
            currentExecutionState.executorTool?.status = finalStatus

            if finalStatus == .completed {
                statusMessage = "Command finished."
            } else {
                statusMessage = "Command failed."
                errorMessage = "Command exited with status \(exitStatus ?? -1)."
            }

            refreshExecutionTreeMessageIfPossible()
        }

        return finalStatus
    }

    private static func parseCouncilEvent(from line: String) -> CouncilEvent? {
        let pattern = #"\[[^\]]+\]\s+\[(\w+)\]\s+([A-Z_]+):\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 4,
              let roleRange = Range(match.range(at: 1), in: line),
              let stepRange = Range(match.range(at: 2), in: line),
              let outcomeRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        return CouncilEvent(
            role: String(line[roleRange]),
            step: String(line[stepRange]),
            outcome: String(line[outcomeRange])
        )
    }

    private static func parseBracketMessage(prefix: String, from line: String) -> String? {
        let marker = "[\(prefix.lowercased())]"
        let lowercased = line.lowercased()
        guard let range = lowercased.range(of: marker) else { return nil }
        let sourceRange = line.index(line.startIndex, offsetBy: lowercased.distance(from: lowercased.startIndex, to: range.upperBound))..<line.endIndex
        return line[sourceRange].trimmingCharacters(in: .whitespaces)
    }

    private static func parseIntentAndScore(from outcome: String) -> (intent: String?, score: Int?) {
        let lowercased = outcome.lowercased()
        let intent: String?
        if lowercased.contains("intent=approve") {
            intent = "approve"
        } else if lowercased.contains("intent=amend") {
            intent = "amend"
        } else if lowercased.contains("intent=reject") {
            intent = "reject"
        } else {
            intent = nil
        }

        let scorePattern = #"score=([0-9]*\.?[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: scorePattern),
              let match = regex.firstMatch(in: outcome, range: NSRange(outcome.startIndex..., in: outcome)),
              let scoreRange = Range(match.range(at: 1), in: outcome),
              let value = Double(outcome[scoreRange]) else {
            return (intent, nil)
        }

        return (intent, Int((value * 100).rounded()))
    }

    private static func criticFeedbackText(from outcome: String) -> String {
        let parsed = parseIntentAndScore(from: outcome)
        switch parsed.intent {
        case "approve":
            if let score = parsed.score {
                return "Critic approved — \(score)% HIG alignment."
            }
            return "Critic approved the direction."
        case "amend":
            if let score = parsed.score {
                return "The Critic flagged an issue and asked for a revision — \(score)% HIG alignment so far."
            }
            return "The Critic flagged an issue and asked for a revision."
        case "reject":
            return "The Critic rejected the proposal and sent it back for revision."
        default:
            return "The Critic is reviewing the design."
        }
    }

    private static func acknowledgment(for goal: String) -> String {
        let lowercased = goal.lowercased()
        let topic = topicFragment(from: goal)

        if lowercased.contains("fix") || lowercased.contains("repair") {
            return "I’m fixing \(topic)."
        }

        if lowercased.contains("flow") || lowercased.contains("onboarding") {
            return "I’m working through \(topic)."
        }

        if lowercased.contains("view") || lowercased.contains("screen") {
            return "I’m shaping \(topic)."
        }

        return "I’m on it: \(topic)."
    }

    private static func topicFragment(from goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let removablePrefixes = [
            "design ",
            "build ",
            "create ",
            "make ",
            "fix ",
            "update ",
            "improve ",
            "add "
        ]

        let lowered = trimmed.lowercased()
        for prefix in removablePrefixes where lowered.hasPrefix(prefix) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private static func completionText(
        targetFile: String,
        archetype: String?,
        higScore: Int,
        elapsedSeconds: Int
    ) -> String {
        let fileName = (targetFile as NSString).lastPathComponent
        let designDirection = designDirectionText(for: archetype)
        return "Done — I built \(fileName) with \(designDirection). HIG alignment is \(higScore)%. Took \(elapsedDurationText(from: elapsedSeconds))."
    }

    private static func designDirectionText(for archetype: String?) -> String {
        switch archetype?.lowercased() {
        case "athletic":
            return "an energetic, performance-led direction"
        case "financial":
            return "a sober, trust-first direction"
        case "socialreactive":
            return "a lively, reactive direction"
        case "tactical":
            return "a precise, information-forward direction"
        case "utilityminimal":
            return "a minimal, distraction-free direction"
        default:
            return "a focused, native direction"
        }
    }

    private static func elapsedDurationText(from elapsedSeconds: Int) -> String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        if minutes == 0 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
        return "\(minutes)m \(seconds)s"
    }

    private static func concise(_ message: String) -> String {
        message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? message
    }

    private static func trailingPathComponent(from message: String) -> String {
        if let range = message.range(of: ":") {
            let suffix = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return (suffix as NSString).lastPathComponent
        }
        return message
    }

    /// Extract JSON packet from stdout. Finds balanced braces after "APPROVED PACKET:" marker.
    private static func extractPacketJSON(from stdout: String) -> String? {
        // Look for marker first
        let searchText: String
        if let markerRange = stdout.range(of: "APPROVED PACKET:") {
            searchText = String(stdout[markerRange.upperBound...])
        } else {
            // Fallback: try to find top-level JSON object
            searchText = stdout
        }

        guard let firstBrace = searchText.firstIndex(of: "{") else { return nil }

        var depth = 0
        var endIndex = firstBrace
        for i in searchText[firstBrace...].indices {
            switch searchText[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    endIndex = searchText.index(after: i)
                    return String(searchText[firstBrace..<endIndex])
                }
            default: break
            }
        }
        return nil
    }

    // MARK: - Telemetry Drop

    static func resolveScreenshotPath(for packetID: UUID) -> String? {
        let telemetryDir = FactoryObserver.telemetryDir
        let candidates = [
            telemetryDir.appendingPathComponent("\(packetID.uuidString).png"),
            telemetryDir.appendingPathComponent("processed", isDirectory: true)
                .appendingPathComponent("\(packetID.uuidString).png")
        ]

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path
    }

    private func dropTelemetryPacket(goal: String) {
        guard let json = approvedPacketJSON,
              let data = json.data(using: .utf8),
              let packet = try? JSONDecoder().decode(PacketSummary.self, from: data) else { return }

        // Build a TelemetryPacket with the goal context
        let telemetry = TelemetryPacket(
            goal: goal,
            displayGoal: activeDisplayGoal,
            projectName: nil,
            packetID: packet.packetID,
            sender: packet.sender,
            intent: packet.intent,
            scope: packet.scope,
            payload: TelemetryPacket.Payload(
                rationale: packet.payload.rationale,
                targetFile: packet.payload.targetFile,
                isNewFile: packet.payload.isNewFile,
                diffText: packet.payload.diffText,
                affectedTypes: packet.payload.affectedTypes,
                archetypeClassification: packet.payload.archetypeClassification.map {
                    TelemetryPacket.Payload.ArchetypeInfo(dominant: $0.dominant, confidence: $0.confidence)
                }
            ),
            metrics: TelemetryPacket.Metrics(
                higComplianceScore: packet.metrics.higComplianceScore,
                deviationBudgetCost: packet.metrics.deviationBudgetCost
            ),
            driftScore: nil,
            driftMode: nil
        )

        guard let telemetryData = try? JSONEncoder().encode(telemetry),
              let telemetryJSON = String(data: telemetryData, encoding: .utf8) else { return }

        FactoryObserver.dropTelemetry(packetJSON: telemetryJSON, packetID: packet.packetID.uuidString)
    }

    // MARK: - Timer

    @MainActor
    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds += 1
            }
        }
    }

    @MainActor
    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

// MARK: - LiveStateEngine

/// In-memory cache that drives the UI.
/// Fetches from SwiftData on load and on pipeline events.
/// The UI reads from this — never from @Query directly.
@Observable
final class LiveStateEngine {

    /// The current set of active projects. Sorted in the View layer, not here.
    var projects: [AppProject] = []

    /// Load all projects from the SwiftData store.
    func load(from context: ModelContext) {
        let descriptor = FetchDescriptor<AppProject>(
            sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)]
        )
        do {
            projects = try context.fetch(descriptor)
        } catch {
            projects = []
        }
    }

    /// Find a project by ID.
    func project(for id: UUID) -> AppProject? {
        projects.first { $0.id == id }
    }

    /// Find an epoch by ID within a project.
    func epoch(for epochID: UUID, in projectID: UUID) -> Epoch? {
        project(for: projectID)?.epochs.first { $0.id == epochID }
    }

    /// Ingest a pipeline result into SwiftData.
    /// Returns the project ID on success, or an error string on failure.
    @discardableResult
    func ingestPipelineResult(
        goal: String,
        displayGoal: String? = nil,
        packet: PacketSummary,
        context: ModelContext
    ) -> Result<UUID, PipelineError> {
        // Validate
        if let err = packet.validate() {
            return .failure(PipelineError(message: err))
        }

        let packetID = packet.packetID
        let duplicateDescriptor = FetchDescriptor<Epoch>(
            predicate: #Predicate { $0.packetID == packetID }
        )
        if let existingEpoch = try? context.fetch(duplicateDescriptor).first,
           let projectID = existingEpoch.project?.id {
            load(from: context)
            return .success(projectID)
        }

        // Find existing project by goal or create new
        let project: AppProject
        if let existing = projects.first(where: { $0.goal == goal }) {
            project = existing
        } else {
            let name = goal.prefix(40).trimmingCharacters(in: .whitespaces)
            project = AppProject(name: String(name), goal: goal)
            context.insert(project)
        }
        project.displayGoal = displayGoal ?? project.displayGoal ?? goal

        // Create epoch
        let epochIndex = project.epochs.count
        let epoch = Epoch(
            index: epochIndex,
            summary: packet.payload.rationale,
            archetype: packet.payload.archetypeClassification?.dominant,
            higScore: packet.metrics.higComplianceScore,
            deviationCost: packet.metrics.deviationBudgetCost,
            targetFile: packet.payload.targetFile,
            isNewFile: packet.payload.isNewFile,
            packetID: packet.packetID,
            diffText: packet.payload.diffText,
            componentsBuilt: max(packet.payload.affectedTypes.count, packet.payload.diffText == nil ? 0 : 1)
        )
        epoch.screenshotPath = PipelineRunner.resolveScreenshotPath(for: packet.packetID)
        epoch.project = project
        context.insert(epoch)
        project.epochs.append(epoch)

        // Update project metrics
        project.dominantArchetype = packet.payload.archetypeClassification?.dominant
        project.confidenceScore = Int(packet.metrics.higComplianceScore * 100)
        project.deviationBudgetRemaining = max(0, project.deviationBudgetRemaining - packet.metrics.deviationBudgetCost)
        project.latestCriticVerdict = "Critic approved — \(Int((packet.metrics.higComplianceScore * 100).rounded()))% HIG alignment."
        project.lastActivityAt = Date()

        do {
            try context.save()
        } catch {
            return .failure(PipelineError(message: "Failed to save: \(error.localizedDescription)"))
        }

        load(from: context)
        return .success(project.id)
    }
}
