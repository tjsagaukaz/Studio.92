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
            maxIterations: Int = 8,
            maxTokens: Int = 3072
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

    public init(client: ClaudeAPIClient) {
        self.client = client
    }

    public func run(
        spec: Spec,
        toolHandler: @escaping @Sendable (String, [String: AnyCodableValue]) async -> ToolExecutionOutcome
    ) async throws -> String {
        var messages: [ClaudeMessage] = [.user(spec.userPrompt)]

        for _ in 0..<spec.maxIterations {
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

            if responseBlocks.isEmpty {
                messages.append(.assistant(summaryText))
            } else {
                messages.append(.init(role: .assistant, content: .blocks(responseBlocks)))
            }

            guard !toolUses.isEmpty else {
                return summaryText
            }

            let toolResults: [MessageBlock] = await withTaskGroup(of: MessageBlock.self) { group in
                for toolUse in toolUses {
                    group.addTask {
                        let outcome = await toolHandler(toolUse.name, toolUse.input)
                        return .toolResult(
                            ToolResultBlock(
                                toolUseId: toolUse.id,
                                content: outcome.toolResultContent,
                                isError: outcome.isError
                            )
                        )
                    }
                }

                var results: [MessageBlock] = []
                for await block in group {
                    results.append(block)
                }
                return results
            }

            messages.append(.init(role: .user, content: .blocks(toolResults)))
        }

        return "Sub-agent reached its iteration limit before producing a final summary."
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
