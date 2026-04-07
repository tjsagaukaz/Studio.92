// ConversationModels.swift
// CommandCenter
//
// Chat, conversation, and streaming types.
// Extracted from Models.swift during structural decomposition.

import Foundation
import Combine
import Observation
import UniformTypeIdentifiers

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
    case screenshotSimulator
    case xcodeBuild
    case xcodeTest
    case xcodePreview
    case multimodalAnalyze
    case gitStatus
    case gitDiff
    case gitCommit
    case simulatorLaunchApp
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

    /// Multimodal analysis preset (nil = text-only or default image handling).
    var multimodalPreset: MultimodalPreset?
    /// Structured extraction schema (nil = freeform response).
    var extractorSchema: ExtractorSchema?

    var isImage: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    var isPDF: Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    var isDocument: Bool {
        isImage || isPDF
    }
}

/// Token usage for a single message. Named struct so ChatMessage can synthesize Equatable.
struct TokenCount: Equatable {
    var input: Int
    var output: Int
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
        case streaming          // A message whose text is being streamed token-by-token.
        case planViewportCard   // Replaces plan text in chat — plan lives in the Viewport.
        case compactionDivider  // Full-width "Memory Optimized" divider. Always stays in chat.
        case timelineFracture   // Full-bleed revert marker injected after a workspace revert.
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
    var tokenUsage: TokenCount?
    /// Whether this message was finalized by cancellation and may be incomplete.
    var isPartial: Bool = false

    // Synthesized by the compiler now that all fields conform to Equatable.
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
    /// Character offset into `streamingText` at the moment this tool call started.
    var textOffset: Int = 0
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

private enum ChatTextSanitizer {

    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
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
    /// Structured intent — describes *what part* or *why* (e.g., "AgentSession structure", "lines 50-120").
    var intent: String?
    var filePath: String?
    var relatedFilePaths: [String] = []
    var linesAdded: Int?
    var linesRemoved: Int?
    var liveOutput: [String] = []
    var timestamp: Date
    /// Character offset into the turn's accumulated text at the moment this trace started.
    var textOffset: Int = 0
    /// Links this tool activity to a plan step for execution tracking.
    var planStepID: String?

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

// MARK: - Interleaved Content Blocks

enum TurnContentBlock: Identifiable, Equatable {
    case text(id: String, text: String)
    case toolActivity(id: String, traces: [ToolTrace])

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .toolActivity(let id, _): return id
        }
    }
}

extension ConversationTurn {

    /// Builds an interleaved sequence of text segments and tool trace groups,
    /// ordered by `textOffset`. This preserves the chronological order:
    /// text → tool calls → more text → more tool calls.
    var interleavedBlocks: [TurnContentBlock] {
        let fullText = response.renderedText
        guard !fullText.isEmpty || !toolTraces.isEmpty else { return [] }

        // Sort non-console, non-delegation traces by textOffset then timestamp.
        let inlineTraces = toolTraces
            .filter { !$0.isConsoleTrace && !$0.isDelegationTrace }
            .sorted { ($0.textOffset, $0.timestamp) < ($1.textOffset, $1.timestamp) }

        // If no traces have offset info, decide based on turn state:
        // - Completed/historical turns: tools already ran, just show text.
        // - Live turns: show tools so user sees activity.
        let hasOffsets = inlineTraces.contains { $0.textOffset > 0 }
        if !hasOffsets && !inlineTraces.isEmpty {
            let isSettled = state == .completed || state == .failed || isHistorical
            var blocks: [TurnContentBlock] = []
            if !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(id: "text-full", text: fullText))
            }
            if !isSettled {
                blocks.append(.toolActivity(id: "tools-all", traces: inlineTraces))
            }
            let delegations = toolTraces.filter(\.isDelegationTrace)
            if !delegations.isEmpty && !isSettled {
                blocks.append(.toolActivity(id: "tools-delegation", traces: delegations))
            }
            return blocks
        }

        // During streaming, offsets are into streamingText. When stable text exists,
        // renderedText prepends it with "\n\n", so shift offsets accordingly.
        let stablePrefix = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixShift: Int
        if response.isStreaming && !stablePrefix.isEmpty {
            // renderedText = "\(stable)\n\n\(live)" — shift by stable length + 2
            prefixShift = stablePrefix.count + 2
        } else {
            prefixShift = 0
        }

        var blocks: [TurnContentBlock] = []
        var cursor = fullText.startIndex
        var blockIndex = 0

        var traceIndex = 0
        while traceIndex < inlineTraces.count {
            let trace = inlineTraces[traceIndex]
            let adjustedOffset = min(trace.textOffset + prefixShift, fullText.count)
            let targetIndex = fullText.index(
                fullText.startIndex,
                offsetBy: adjustedOffset,
                limitedBy: fullText.endIndex
            ) ?? fullText.endIndex

            // Emit text segment before this tool group.
            if targetIndex > cursor {
                let segment = String(fullText[cursor..<targetIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    blocks.append(.text(id: "text-\(blockIndex)", text: segment))
                    blockIndex += 1
                }
                cursor = targetIndex
            }

            // Collect all traces at the same offset.
            var group: [ToolTrace] = [trace]
            while traceIndex + 1 < inlineTraces.count
                    && inlineTraces[traceIndex + 1].textOffset == trace.textOffset {
                traceIndex += 1
                group.append(inlineTraces[traceIndex])
            }
            blocks.append(.toolActivity(id: "tools-\(blockIndex)", traces: group))
            blockIndex += 1
            traceIndex += 1
        }

        // Emit any remaining text after the last tool group.
        if cursor < fullText.endIndex {
            let remaining = String(fullText[cursor...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                blocks.append(.text(id: "text-\(blockIndex)", text: remaining))
                blockIndex += 1
            }
        }

        // Fallback: no traces matched — emit the full text.
        if blocks.isEmpty && !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(id: "text-full", text: fullText))
        }

        // For settled turns, strip tool activity blocks — only show text.
        let isSettled = state == .completed || state == .failed || isHistorical
        if isSettled {
            return blocks.filter {
                if case .toolActivity = $0 { return false }
                return true
            }
        }

        // Append delegation traces as a final group (live turns only).
        let delegations = toolTraces.filter(\.isDelegationTrace)
        if !delegations.isEmpty {
            blocks.append(.toolActivity(id: "tools-delegation", traces: delegations))
        }

        return blocks
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    private(set) var turns: [ConversationTurn] = []
    private(set) var activeTurnID: UUID?
    private(set) var structureVersion = 0
    private(set) var contentVersion = 0

    func reset() {
        guard !turns.isEmpty || activeTurnID != nil || structureVersion != 0 || contentVersion != 0 else { return }

        objectWillChange.send()
        turns = []
        activeTurnID = nil
        structureVersion &+= 1
        contentVersion &+= 1
    }

    func rebuild(from messages: [ChatMessage], isPipelineRunning: Bool) {
        objectWillChange.send()
        turns = Self.buildTurns(from: messages, isPipelineRunning: isPipelineRunning)
        refreshActiveTurnID()
        structureVersion &+= 1
        contentVersion &+= 1
    }

    /// Mark every turn as historical so live pipeline won't collide.
    func markAllHistorical() {
        guard turns.contains(where: { !$0.isHistorical }) else { return }
        objectWillChange.send()
        for i in turns.indices {
            turns[i].isHistorical = true
        }
        contentVersion &+= 1
    }

    func applyLiveMessage(_ message: ChatMessage, isPipelineRunning: Bool) {
        objectWillChange.send()

        if let index = liveTurnIndex(for: message) {
            var updatedTurn = turns[index]
            Self.absorb(message, into: &updatedTurn)
            updatedTurn = Self.finalized(updatedTurn, isPipelineRunning: isPipelineRunning)
            turns[index] = updatedTurn
            contentVersion &+= 1
        } else {
            turns.append(
                Self.liveTurn(from: message, isPipelineRunning: isPipelineRunning)
            )
            structureVersion &+= 1
            contentVersion &+= 1
        }

        refreshActiveTurnID()
    }

    func refreshPipelineState(isPipelineRunning: Bool) {
        var updatedTurns = turns
        var didMutate = false

        for index in updatedTurns.indices {
            let finalizedTurn = Self.finalized(updatedTurns[index], isPipelineRunning: isPipelineRunning)
            if finalizedTurn != updatedTurns[index] {
                updatedTurns[index] = finalizedTurn
                didMutate = true
            }
        }

        guard didMutate else { return }

        objectWillChange.send()
        turns = updatedTurns
        refreshActiveTurnID()
        contentVersion &+= 1
    }

    private func refreshActiveTurnID() {
        activeTurnID = turns.last(where: {
            $0.state == .streaming || $0.state == .executing || $0.state == .finalizing
        })?.id
    }

    private func liveTurnIndex(for message: ChatMessage) -> Int? {
        if let packetID = message.packetID,
           let index = turns.lastIndex(where: { !$0.isHistorical && $0.packetID == packetID }) {
            return index
        }

        if let index = turns.lastIndex(where: { !$0.isHistorical && $0.userGoal == message.goal }) {
            return index
        }

        return turns.lastIndex(where: { !$0.isHistorical })
    }

    private static func buildTurns(from messages: [ChatMessage], isPipelineRunning: Bool) -> [ConversationTurn] {
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
        return builtTurns
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

    private static func liveTurn(from message: ChatMessage, isPipelineRunning: Bool) -> ConversationTurn {
        var turn = ConversationTurn(
            id: message.epochID ?? message.id,
            userGoal: message.goal,
            userAttachments: message.kind == .userGoal ? message.attachments : [],
            response: AssistantResponse(),
            toolTraces: [],
            state: message.kind == .error ? .failed : .executing,
            timestamp: message.timestamp,
            epochID: message.epochID,
            packetID: message.packetID,
            screenshotPath: message.screenshotPath,
            metrics: message.metrics,
            isHistorical: false
        )
        absorb(message, into: &turn)
        return finalized(turn, isPipelineRunning: isPipelineRunning)
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
        case .userGoal, .stageUpdate, .criticFeedback, .executionTree, .thinking, .streaming, .planViewportCard, .compactionDivider, .timelineFracture:
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
        let hasResponseText = !turn.response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if turn.state == .failed || turn.toolTraces.contains(where: { $0.status == .error }) {
            turn.state = .failed
            return turn
        }

        if turn.response.isStreaming {
            // If the pipeline has stopped but isStreaming was never cleared,
            // treat as finalizing rather than perpetually stuck in .streaming.
            turn.state = isPipelineRunning ? .streaming : .finalizing
            if !isPipelineRunning {
                turn.response.isStreaming = false
            }
            return turn
        }

        if turn.toolTraces.contains(where: { $0.status == .running }) {
            turn.state = isPipelineRunning ? .executing : .finalizing
            return turn
        }

        if turn.epochID != nil || hasResponseText {
            turn.state = .completed
            return turn
        }

        if !isPipelineRunning {
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
            intent: traceIntent(
                toolName: call.name,
                inputJSON: call.inputJSON,
                displayCommand: call.displayCommand
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
            timestamp: timestamp,
            textOffset: call.textOffset
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
        let normalizedToolName = normalizedTraceToolName(toolName)

        switch normalizedToolName {
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
            return titledFileAction(verb: "Reading", path: tracePath(from: input, displayCommand: displayCommand), fallback: "file")
        case "file_write":
            return titledFileAction(verb: "Writing", path: tracePath(from: input, displayCommand: displayCommand), fallback: "file")
        case "file_patch":
            return titledFileAction(verb: "Patching", path: tracePath(from: input, displayCommand: displayCommand), fallback: "file")
        case "list_files":
            return "Inspecting \(tracePath(from: input, displayCommand: displayCommand) ?? ".")"
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
        let normalizedToolName = normalizedTraceToolName(toolName)
        let combinedContext = [
            displayCommand,
            input?["objective"] as? String,
            input?["starting_command"] as? String,
            input?["command"] as? String,
            input?["context"] as? String
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: "\n")

        switch normalizedToolName {
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
        let normalizedToolName = normalizedTraceToolName(toolName)

        switch normalizedToolName {
        case "file_read", "file_write", "file_patch":
            return tracePath(from: input, displayCommand: displayCommand)
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
        case .webSearch, .webFetch, .terminal, .listFiles,
             .screenshotSimulator, .xcodeBuild, .xcodeTest, .xcodePreview,
             .multimodalAnalyze, .gitStatus, .gitDiff, .gitCommit, .simulatorLaunchApp:
            return nil
        }
    }

    private static func traceRelatedFilePaths(
        toolName: String,
        inputJSON: String,
        displayCommand: String?
    ) -> [String] {
        let input = parsedJSON(from: inputJSON)
        let normalizedToolName = normalizedTraceToolName(toolName)

        switch normalizedToolName {
        case "delegate_to_reviewer":
            return stringArray(from: input?["files_to_review"])
        case "delegate_to_worktree":
            if let targetDirectory = input?["target_directory"] as? String {
                return [".studio92/worktrees/\(targetDirectory)"]
            }
            return []
        case "file_read", "file_write", "file_patch":
            if let path = tracePath(from: input, displayCommand: displayCommand) {
                return [path]
            }
            return []
        case "terminal":
            if let filePath = traceFilePath(toolName: normalizedToolName, inputJSON: inputJSON, displayCommand: displayCommand) {
                return [filePath]
            }
            return []
        default:
            return []
        }
    }

    private static func normalizedTraceToolName(_ toolName: String) -> String {
        switch toolName {
        case "read_file":
            return "file_read"
        case "create_file", "write_file":
            return "file_write"
        case "apply_patch":
            return "file_patch"
        case "list_dir":
            return "list_files"
        case "fetch_webpage":
            return "web_fetch"
        case "run_in_terminal":
            return "terminal"
        default:
            return toolName
        }
    }

    private static func tracePath(from input: [String: Any]?, displayCommand: String?) -> String? {
        if let path = (input?["path"] as? String) ?? (input?["filePath"] as? String) ?? (input?["file_path"] as? String) {
            return path
        }
        guard let displayCommand else { return nil }
        return extractPath(from: displayCommand)
    }

    private static func titledFileAction(verb: String, path: String?, fallback: String) -> String {
        let display = traceDisplayName(for: path) ?? fallback
        return "\(verb) \(display)"
    }

    private static func traceDisplayName(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }

    private static func traceRelatedFilePaths(for toolCall: ToolCall) -> [String] {
        switch toolCall.toolType {
        case .fileRead, .fileWrite, .filePatch:
            if let path = traceFilePath(for: toolCall) {
                return [path]
            }
            return []
        case .terminal, .listFiles, .webSearch, .webFetch,
             .screenshotSimulator, .xcodeBuild, .xcodeTest, .xcodePreview,
             .multimodalAnalyze, .gitStatus, .gitDiff, .gitCommit, .simulatorLaunchApp:
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
        case .webSearch:            return toolCall.command.isEmpty ? "Searching the web" : toolCall.command
        case .webFetch:             return toolCall.command.isEmpty ? "Fetching resource" : toolCall.command
        case .terminal:             return toolCall.command.isEmpty ? fallback : toolCall.command
        case .fileRead:             return toolCall.command.isEmpty ? "Reading file" : toolCall.command
        case .fileWrite:            return toolCall.command.isEmpty ? "Writing file" : toolCall.command
        case .filePatch:            return toolCall.command.isEmpty ? "Patching file" : toolCall.command
        case .listFiles:            return toolCall.command.isEmpty ? "Inspecting files" : toolCall.command
        case .screenshotSimulator:  return "Capturing screenshot"
        case .xcodeBuild:           return toolCall.command.isEmpty ? "Building project" : toolCall.command
        case .xcodeTest:            return toolCall.command.isEmpty ? "Running tests" : toolCall.command
        case .xcodePreview:         return "Build, launch & screenshot"
        case .multimodalAnalyze:    return toolCall.command.isEmpty ? "Analyzing image" : toolCall.command
        case .gitStatus:            return "Checking git status"
        case .gitDiff:              return toolCall.command.isEmpty ? "Viewing diff" : toolCall.command
        case .gitCommit:            return toolCall.command.isEmpty ? "Committing changes" : toolCall.command
        case .simulatorLaunchApp:   return toolCall.command.isEmpty ? "Launching app" : toolCall.command
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
        case .screenshotSimulator:
            return .screenshot
        case .xcodeBuild, .xcodeTest, .xcodePreview:
            return .build
        case .multimodalAnalyze:
            return .read
        case .gitStatus, .gitDiff:
            return .read
        case .gitCommit:
            return .write
        case .simulatorLaunchApp:
            return .terminal
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

    /// Extracts a structured intent string describing *what part* of a file
    /// or *why* a tool is being called. Shown as secondary line in ToolTraceRow.
    private static func traceIntent(
        toolName: String,
        inputJSON: String,
        displayCommand: String?
    ) -> String? {
        let input = parsedJSON(from: inputJSON)
        let normalized = normalizedTraceToolName(toolName)

        switch normalized {
        case "file_read":
            var parts: [String] = []
            if let startLine = input?["startLine"] as? Int,
               let endLine = input?["endLine"] as? Int {
                parts.append("lines \(startLine)–\(endLine)")
            } else if let startLine = input?["start_line"] as? Int,
                      let endLine = input?["end_line"] as? Int {
                parts.append("lines \(startLine)–\(endLine)")
            }
            if let context = input?["context"] as? String, !context.isEmpty {
                parts.append(truncate(context, limit: 50))
            } else if let objective = input?["objective"] as? String, !objective.isEmpty {
                parts.append(truncate(objective, limit: 50))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")

        case "file_patch":
            if let oldStr = input?["old_string"] as? String ?? input?["oldString"] as? String {
                let firstLine = oldStr.components(separatedBy: .newlines).first ?? ""
                let hint = truncate(firstLine.trimmingCharacters(in: .whitespaces), limit: 50)
                return hint.isEmpty ? nil : "near: \(hint)"
            }
            return nil

        case "file_write":
            if let context = input?["context"] as? String, !context.isEmpty {
                return truncate(context, limit: 50)
            }
            return nil

        case "list_files":
            if let path = input?["path"] as? String {
                return truncate(path, limit: 50)
            }
            return nil

        case "web_search":
            if let query = input?["query"] as? String {
                return truncate(query, limit: 60)
            }
            return nil

        case "delegate_to_explorer":
            if let objective = input?["objective"] as? String {
                return truncate(objective, limit: 60)
            }
            return nil

        case "delegate_to_reviewer":
            if let focus = input?["focus_area"] as? String {
                return truncate(focus, limit: 60)
            }
            return nil

        default:
            return nil
        }
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

@MainActor
@Observable
final class ChatThread {
    enum RebuildBoundary {
        case none
        case messageCompleted
    }

    var messages: [ChatMessage] = []
    var isThinking = false
    var completedTurns: [ConversationHistoryTurn] = []
    var structureVersion = 0
    var contentVersion = 0
    var lastUpdatedMessageID: UUID?

    @ObservationIgnored private var messageIndexByID: [UUID: Int] = [:]
    @ObservationIgnored private var pendingRebuildBoundary: RebuildBoundary = .none

    func post(_ message: ChatMessage) {
        messages.append(message)
        messageIndexByID[message.id] = messages.endIndex - 1
        lastUpdatedMessageID = message.id
        structureVersion &+= 1
    }

    func updateMessage(id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        mutateMessage(id: id, marksStructureChange: true, mutate)
    }

    func updateMessageContent(id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        mutateMessage(id: id, marksStructureChange: false, mutate)
    }

    func message(withID id: UUID?) -> ChatMessage? {
        guard let id,
              let index = messageIndexByID[id],
              messages.indices.contains(index) else { return nil }
        return messages[index]
    }

    func consumePendingRebuildBoundary() -> RebuildBoundary {
        let boundary = pendingRebuildBoundary
        pendingRebuildBoundary = .none
        return boundary
    }

    func liveMessages(forGoal goal: String?) -> [ChatMessage] {
        guard let goal else { return [] }
        return messages.filter { $0.goal == goal }
    }

    private func mutateMessage(
        id: UUID,
        marksStructureChange: Bool,
        rebuildBoundary: RebuildBoundary = .none,
        _ mutate: (inout ChatMessage) -> Void
    ) {
        guard let index = messageIndexByID[id], messages.indices.contains(index) else { return }
        var message = messages[index]
        mutate(&message)
        messages[index] = message
        lastUpdatedMessageID = id
        if rebuildBoundary != .none {
            pendingRebuildBoundary = rebuildBoundary
        }
        if marksStructureChange {
            structureVersion &+= 1
        } else {
            contentVersion &+= 1
        }
    }

    func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        rebuildMessageIndex()
        lastUpdatedMessageID = id
        structureVersion &+= 1
    }

    func setThinking(_ thinking: Bool) {
        isThinking = thinking
    }

    func clear() {
        messages.removeAll()
        messageIndexByID.removeAll()
        isThinking = false
        completedTurns.removeAll()
        lastUpdatedMessageID = nil
        structureVersion &+= 1
    }

    private func rebuildMessageIndex() {
        messageIndexByID = Dictionary(
            uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    // MARK: - Streaming Support

    /// Append a text delta to a streaming message.
    func appendTextDelta(toMessageID id: UUID, text: String) {
        mutateMessage(id: id, marksStructureChange: false) { message in
            message.streamingText += ChatTextSanitizer.clean(text)
        }
    }

    /// Append a thinking delta to a streaming message.
    func appendThinkingDelta(toMessageID id: UUID, text: String) {
        let cleaned = ChatTextSanitizer.clean(text)
        guard !cleaned.isEmpty else { return }

        mutateMessage(id: id, marksStructureChange: false) { message in
            if message.thinkingText == nil {
                message.thinkingText = cleaned
            } else {
                message.thinkingText! += cleaned
            }
        }
    }

    func setThinkingSignature(toMessageID id: UUID, signature: String) {
        mutateMessage(id: id, marksStructureChange: false) { message in
            message.thinkingSignature = signature
        }
    }

    /// Register a new tool call on a streaming message.
    func startStreamingToolCall(messageID: UUID, call: StreamingToolCall) {
        mutateMessage(id: messageID, marksStructureChange: false) { message in
            var tracked = call
            tracked.textOffset = message.streamingText.count
            message.streamingToolCalls.append(tracked)
        }
    }

    /// Append partial JSON input to a tool call being assembled.
    func appendToolCallInput(messageID: UUID, callID: String, json: String) {
        mutateMessage(id: messageID, marksStructureChange: false) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].inputJSON += json
        }
    }

    func updateToolCallDisplayCommand(messageID: UUID, callID: String, command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        mutateMessage(id: messageID, marksStructureChange: false) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].displayCommand = trimmed
        }
    }

    func appendToolCallOutput(messageID: UUID, callID: String, line: String, maxLines: Int = 200) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }

        mutateMessage(id: messageID, marksStructureChange: false) { message in
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
        mutateMessage(id: messageID, marksStructureChange: false) { message in
            guard let index = message.streamingToolCalls.firstIndex(where: { $0.id == callID }) else { return }
            message.streamingToolCalls[index].status  = isError ? .failed : .completed
            message.streamingToolCalls[index].result  = result
            message.streamingToolCalls[index].isError = isError
        }
    }

    /// Mark a message as partial (cancelled mid-stream).
    func markPartial(messageID: UUID) {
        mutateMessage(id: messageID, marksStructureChange: false) { message in
            message.isPartial = true
        }
    }

    /// Finalize a streaming message: copy streamingText into text, clear streaming state.
    func finalizeStreaming(
        messageID: UUID,
        finalKind: ChatMessage.Kind = .assistant,
        fallbackText: String? = nil
    ) {
        mutateMessage(
            id: messageID,
            marksStructureChange: false,
            rebuildBoundary: .messageCompleted
        ) { message in
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
        mutateMessage(
            id: messageID,
            marksStructureChange: false,
            rebuildBoundary: .messageCompleted
        ) { message in
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
        mutateMessage(id: messageID, marksStructureChange: false) { message in
            if let existing = message.tokenUsage {
                message.tokenUsage = TokenCount(input: existing.input + input, output: existing.output + output)
            } else {
                message.tokenUsage = TokenCount(input: input, output: output)
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

    // MARK: - Compaction Support

    /// Replace conversation history with compacted turns from Anthropic summarization.
    func replaceHistory(with compactedTurns: [ConversationHistoryTurn]) {
        completedTurns = compactedTurns
    }

    /// Replace conversation history for OpenAI — store the opaque compacted items
    /// alongside retained recent turns. The opaque items are stored as a single
    /// synthetic turn whose text carries a marker; the actual API payload uses
    /// the raw items array stored externally by CompactionCoordinator.
    func replaceHistoryWithCompactionMarker(retainedTurns: [ConversationHistoryTurn]) {
        var result: [ConversationHistoryTurn] = [
            ConversationHistoryTurn(
                role: .assistant,
                text: "[compacted context — opaque items carried forward by the system]",
                timestamp: Date()
            )
        ]
        result.append(contentsOf: retainedTurns)
        completedTurns = result
    }

    /// Post a compaction divider message into the visible chat stream.
    func postCompactionDivider(text: String = "Memory Optimized") {
        let divider = ChatMessage(
            kind: .compactionDivider,
            goal: "",
            text: text,
            timestamp: Date()
        )
        post(divider)
    }

    /// Post a timeline fracture row after a workspace revert.
    /// - Parameter label: Short display label, e.g. "Workspace reverted to 14:32:01"
    func postTimelineFracture(label: String) {
        let fracture = ChatMessage(
            kind: .timelineFracture,
            goal: "",
            text: label,
            timestamp: Date()
        )
        post(fracture)
    }
}

