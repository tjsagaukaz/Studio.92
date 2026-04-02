// AgenticOrchestrator.swift
// Studio.92 — Agent Council
// Streaming agentic loop: stream model response → execute tool calls → loop.
// This is the primary orchestration path for the autonomous app builder.

import Foundation

// MARK: - Agent Event

/// Events emitted by the agentic loop, consumed by the UI layer.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallInputDelta(id: String, partialJSON: String)
    case toolCallResult(id: String, output: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int)
    case completed(stopReason: String)
    case error(String)
}

// MARK: - Agentic Configuration

public struct AgenticConfig: Sendable {
    public let model:         ClaudeModel
    public let maxTokens:     Int
    public let temperature:   Double?
    public let tools:         [ToolDefinition]
    public let thinking:      ThinkingConfig?
    public let cacheControl:  CacheControl?
    /// Maximum agentic loop iterations (tool-use round-trips). Safety valve.
    public let maxIterations: Int

    public static let `default` = AgenticConfig(
        model:         .sonnet,
        maxTokens:     4096,
        temperature:   0.2,
        tools:         AgentTools.all,
        thinking:      nil,
        cacheControl:  CacheControl(),
        maxIterations: 25
    )

    public init(
        model:         ClaudeModel       = .sonnet,
        maxTokens:     Int               = 4096,
        temperature:   Double?           = 0.2,
        tools:         [ToolDefinition]  = AgentTools.all,
        thinking:      ThinkingConfig?   = nil,
        cacheControl:  CacheControl?     = CacheControl(),
        maxIterations: Int               = 25
    ) {
        self.model         = model
        self.maxTokens     = maxTokens
        self.temperature   = temperature
        self.tools         = tools
        self.thinking      = thinking
        self.cacheControl  = cacheControl
        self.maxIterations = maxIterations
    }
}

// MARK: - Orchestrator

public actor AgenticOrchestrator {

    private let client:       ClaudeAPIClient
    private let toolExecutor: ToolExecutor
    private let config:       AgenticConfig

    public init(
        client:       ClaudeAPIClient,
        toolExecutor: ToolExecutor,
        config:       AgenticConfig = .default
    ) {
        self.client       = client
        self.toolExecutor = toolExecutor
        self.config       = config
    }

    /// Run the agentic loop for a conversation.
    ///
    /// Returns an `AsyncStream<AgentEvent>` that the UI can consume for real-time updates.
    /// The loop streams the model response, executes any tool_use calls, appends tool
    /// results, and re-sends — until the model emits `end_turn` or the iteration cap is hit.
    ///
    /// Cancelling the consuming Task tears down the entire loop.
    public func run(
        system:   String,
        messages: [ClaudeMessage]
    ) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()

        let task = Task { [client, toolExecutor, config] in
            var conversationMessages = messages
            var iteration = 0

            do {
                while iteration < config.maxIterations {
                    iteration += 1

                    // Accumulate the full assistant turn from streaming deltas.
                    var assistantText     = ""
                    var assistantBlocksByIndex: [Int: AssistantBlockAccumulator] = [:]
                    var stopReason: String?

                    // Stream one model turn.
                    let events = await client.stream(
                        system:      system,
                        messages:    conversationMessages,
                        model:       config.model,
                        maxTokens:   config.maxTokens,
                        temperature: config.temperature,
                        tools:       config.tools.isEmpty ? nil : config.tools,
                        thinking:    config.thinking,
                        cacheControl: config.cacheControl
                    )

                    for try await event in events {
                        if Task.isCancelled { break }

                        switch event {
                        case .messageStart(let msg):
                            if let usage = msg.usage {
                                continuation.yield(.usage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens))
                            }

                        case .contentBlockStart(let index, let block):
                            switch block.type {
                            case "tool_use":
                                let id   = block.id ?? UUID().uuidString
                                let name = block.name ?? "unknown"
                                assistantBlocksByIndex[index] = .toolUse(id: id, name: name, inputJSON: "")
                                continuation.yield(.toolCallStart(id: id, name: name))
                            case "thinking":
                                assistantBlocksByIndex[index] = .thinking(text: block.thinking ?? "", signature: block.signature)
                            case "text":
                                assistantBlocksByIndex[index] = .text(block.text ?? "")
                            default:
                                break
                            }

                        case .contentBlockDelta(let index, let delta):
                            switch delta {
                            case .textDelta(let text):
                                assistantText += text
                                assistantBlocksByIndex[index]?.appendTextDelta(text)
                                continuation.yield(.textDelta(text))
                            case .inputJSONDelta(let json):
                                if let toolID = assistantBlocksByIndex[index]?.appendInputJSONDelta(json) {
                                    continuation.yield(.toolCallInputDelta(id: toolID, partialJSON: json))
                                }
                            case .thinkingDelta(let text):
                                assistantBlocksByIndex[index]?.appendThinkingDelta(text)
                                continuation.yield(.thinkingDelta(text))
                            case .signatureDelta(let signature):
                                assistantBlocksByIndex[index]?.setThinkingSignature(signature)
                            }

                        case .contentBlockStop:
                            break

                        case .messageDelta(let delta):
                            stopReason = delta.stopReason
                            if let usage = delta.usage {
                                continuation.yield(.usage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens))
                            }

                        case .messageStop:
                            break

                        case .ping:
                            break

                        case .error(let err):
                            continuation.yield(.error("Stream error: \(err.message)"))
                            continuation.finish()
                            return
                        }
                    }

                    if Task.isCancelled { break }

                    // Build the assistant message to append to history.
                    let assistantBlocks = assistantBlocksByIndex
                        .keys
                        .sorted()
                        .compactMap { assistantBlocksByIndex[$0]?.messageBlock }
                    conversationMessages.append(ClaudeMessage(
                        role: .assistant,
                        content: assistantBlocks.isEmpty ? .text(assistantText) : .blocks(assistantBlocks)
                    ))

                    let pendingToolCalls = assistantBlocksByIndex
                        .keys
                        .sorted()
                        .compactMap { assistantBlocksByIndex[$0]?.pendingToolCall }

                    // If the model finished without requesting tools, we're done.
                    if pendingToolCalls.isEmpty || stopReason == "end_turn" {
                        continuation.yield(.completed(stopReason: stopReason ?? "end_turn"))
                        continuation.finish()
                        return
                    }

                    // Execute each tool call and send results back.
                    var toolResultBlocks: [MessageBlock] = []
                    for tc in pendingToolCalls {
                        let parsedInput = Self.parseToolInput(tc.inputJSON)
                        let outcome = await toolExecutor.execute(
                            toolCallID: tc.id,
                            name:       tc.name,
                            input:      parsedInput
                        )
                        continuation.yield(.toolCallResult(id: tc.id, output: outcome.displayText, isError: outcome.isError))
                        toolResultBlocks.append(.toolResult(ToolResultBlock(
                            toolUseId: tc.id,
                            content:   outcome.toolResultContent,
                            isError:   outcome.isError
                        )))
                    }
                    conversationMessages.append(ClaudeMessage(
                        role: .user,
                        content: .blocks(toolResultBlocks)
                    ))
                }

                // Hit iteration cap.
                continuation.yield(.error("Reached maximum agentic iterations (\(config.maxIterations))."))
                continuation.finish()

            } catch {
                continuation.yield(.error("Agentic loop error: \(error.localizedDescription)"))
                continuation.finish()
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }

        return stream
    }

    // MARK: - Helpers

    private struct PendingToolCall {
        let id:       String
        let name:     String
        var inputJSON: String
    }

    private enum AssistantBlockAccumulator {
        case text(String)
        case thinking(text: String, signature: String?)
        case toolUse(id: String, name: String, inputJSON: String)

        mutating func appendTextDelta(_ text: String) {
            guard case .text(let current) = self else { return }
            self = .text(current + text)
        }

        mutating func appendThinkingDelta(_ text: String) {
            guard case .thinking(let current, let signature) = self else { return }
            self = .thinking(text: current + text, signature: signature)
        }

        mutating func setThinkingSignature(_ signature: String) {
            guard case .thinking(let text, _) = self else { return }
            self = .thinking(text: text, signature: signature)
        }

        mutating func appendInputJSONDelta(_ json: String) -> String? {
            guard case .toolUse(let id, let name, let inputJSON) = self else { return nil }
            self = .toolUse(id: id, name: name, inputJSON: inputJSON + json)
            return id
        }

        var pendingToolCall: PendingToolCall? {
            guard case .toolUse(let id, let name, let inputJSON) = self else { return nil }
            return PendingToolCall(id: id, name: name, inputJSON: inputJSON)
        }

        var messageBlock: MessageBlock? {
            switch self {
            case .text(let text):
                return .text(text)
            case .thinking(let text, let signature):
                return .thinking(ThinkingBlock(thinking: text, signature: signature))
            case .toolUse(let id, let name, let inputJSON):
                return .toolUse(ToolUseBlock(id: id, name: name, input: AgenticOrchestrator.parseToolInput(inputJSON)))
            }
        }
    }

    private static func parseToolInput(_ json: String) -> [String: AnyCodableValue] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) else {
            return [:]
        }
        return dict
    }
}
