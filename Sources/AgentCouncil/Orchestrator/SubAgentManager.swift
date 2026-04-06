// SubAgentManager.swift
// Studio.92 — Agent Council
// Runs focused read-heavy worker agents in isolated Claude contexts.

import Foundation

public actor SubAgentManager {

    public struct Spec: Sendable {
        public let systemPrompt: String
        public let userPrompt: String
        public let model: ClaudeModel
        public let tools: [ToolDefinition]
        public let maxIterations: Int
        public let maxTokens: Int

        public init(
            systemPrompt: String,
            userPrompt: String,
            model: ClaudeModel,
            tools: [ToolDefinition],
            maxIterations: Int = 12,
            maxTokens: Int = 8192
        ) {
            self.systemPrompt = systemPrompt
            self.userPrompt = userPrompt
            self.model = model
            self.tools = tools
            self.maxIterations = maxIterations
            self.maxTokens = maxTokens
        }
    }

    private let client: ClaudeAPIClient
    private let tracer: TraceCollector?
    private let parentSpanID: UUID?

    public init(client: ClaudeAPIClient, tracer: TraceCollector? = nil, parentSpanID: UUID? = nil) {
        self.client = client
        self.tracer = tracer
        self.parentSpanID = parentSpanID
    }

    /// Result from a sub-agent run, including the summary and iteration count.
    public struct RunResult: Sendable {
        public let summary: String
        public let iterations: Int
    }

    public func run(
        spec: Spec,
        toolHandler: @escaping @Sendable (String, [String: AnyCodableValue]) async -> ToolExecutionOutcome
    ) async throws -> RunResult {
        let subagentSpanID = await tracer?.begin(
            kind: .subagent,
            name: "subagent_run",
            parentID: parentSpanID,
            attributes: ["model": spec.model.rawValue, "maxIterations": "\(spec.maxIterations)"]
        )

        var messages: [ClaudeMessage] = [.user(spec.userPrompt)]

        for iteration in 0..<spec.maxIterations {
            let llmSpanID = await tracer?.begin(
                kind: .llmCall,
                name: "subagent_llm_call",
                parentID: subagentSpanID,
                attributes: ["iteration": "\(iteration)", "model": spec.model.rawValue]
            )

            let response = try await client.complete(
                system: spec.systemPrompt,
                messages: messages,
                model: spec.model,
                maxTokens: spec.maxTokens,
                temperature: 0.2,
                cacheControl: CacheControl()
            )

            let responseBlocks = messageBlocks(from: response.content)
            let summaryText = summarizedText(from: response.content)
            let toolUses = toolUses(from: response.content)

            if let llmSpanID { await tracer?.end(llmSpanID) }

            if responseBlocks.isEmpty {
                messages.append(.assistant(summaryText))
            } else {
                messages.append(.init(role: .assistant, content: .blocks(responseBlocks)))
            }

            guard !toolUses.isEmpty else {
                if let subagentSpanID {
                    await tracer?.setAttribute("iterations", value: "\(iteration + 1)", on: subagentSpanID)
                    await tracer?.end(subagentSpanID)
                }
                return RunResult(summary: summaryText, iterations: iteration + 1)
            }

            // Partition tool calls: reads run in parallel, writes run sequentially.
            let partitioned = ToolParallelism.partition(
                toolUses,
                name: { $0.name },
                inputJSON: { toolUse in
                    guard let data = try? JSONEncoder().encode(toolUse.input),
                          let json = String(data: data, encoding: .utf8) else { return "" }
                    return json
                }
            )

            var indexedResults: [Int: MessageBlock] = [:]

            // Run parallel-safe tools concurrently.
            if !partitioned.parallel.isEmpty {
                let parallelResults = await withTaskGroup(of: (Int, MessageBlock).self) { group in
                    for (originalIndex, toolUse) in partitioned.parallel {
                        group.addTask {
                            let outcome = await toolHandler(toolUse.name, toolUse.input)
                            return (
                                originalIndex,
                                .toolResult(
                                    ToolResultBlock(
                                        toolUseId: toolUse.id,
                                        content: outcome.toolResultContent,
                                        isError: outcome.isError
                                    )
                                )
                            )
                        }
                    }
                    var results: [Int: MessageBlock] = [:]
                    for await (index, block) in group {
                        results[index] = block
                    }
                    return results
                }
                indexedResults.merge(parallelResults) { _, new in new }
            }

            // Run sequential tools (writes, path-conflicting reads) one at a time.
            for (originalIndex, toolUse) in partitioned.sequential {
                let outcome = await toolHandler(toolUse.name, toolUse.input)
                indexedResults[originalIndex] = .toolResult(
                    ToolResultBlock(
                        toolUseId: toolUse.id,
                        content: outcome.toolResultContent,
                        isError: outcome.isError
                    )
                )
            }

            let toolResults: [MessageBlock] = toolUses.indices.compactMap { indexedResults[$0] }

            messages.append(.init(role: .user, content: .blocks(toolResults)))
        }

        if let subagentSpanID { await tracer?.end(subagentSpanID, error: "iteration_limit") }
        return RunResult(
            summary: "Sub-agent reached its iteration limit before producing a final summary.",
            iterations: spec.maxIterations
        )
    }

    private func toolUses(from blocks: [ContentBlock]) -> [ToolUseBlock] {
        blocks.compactMap { block in
            guard block.type == "tool_use",
                  let id = block.id,
                  let name = block.name,
                  let input = block.input else {
                return nil
            }
            return ToolUseBlock(id: id, name: name, input: input)
        }
    }

    private func summarizedText(from blocks: [ContentBlock]) -> String {
        let text = blocks
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if !text.isEmpty {
            return text
        }

        return "Sub-agent completed without a textual summary."
    }

    private func messageBlocks(from blocks: [ContentBlock]) -> [MessageBlock] {
        blocks.compactMap { block in
            switch block.type {
            case "text":
                guard let text = block.text else { return nil }
                return .text(text)
            case "thinking":
                guard let thinking = block.thinking else { return nil }
                return .thinking(ThinkingBlock(thinking: thinking, signature: block.signature))
            case "tool_use":
                guard let id = block.id, let name = block.name, let input = block.input else { return nil }
                return .toolUse(ToolUseBlock(id: id, name: name, input: input))
            default:
                return nil
            }
        }
    }
}
