// AgentCouncil.swift
// Studio.92 — Agent Builder
// Module umbrella.

/// Import `AgentCouncil` to get the direct agentic app-builder stack:
///
///   # API
///   ClaudeModel            — opus | sonnet | haiku model IDs
///   ClaudeAPIClient        — actor; URLSession wrapper for Anthropic Messages API
///   ClaudeRequest/Response — Codable API models
///
///   # Prompting
///   BuilderSystemPrompt    — system prompt generator for the autonomous app builder
///
///   # Orchestrator
///   AgenticOrchestrator    — streaming model → tool-use → model loop
///   AgenticConfig          — model, tool, and iteration limits
///   ToolExecutor           — file, terminal, web, delegation, and deployment tools
///   AutonomyMode           — plan | review | fullSend execution guardrails
///
///   # Errors
///   OrchestratorError      — typed API and loop failures
///
/// Quick start:
/// ```swift
/// import AgentCouncil
/// import Foundation
///
/// let api = try ClaudeAPIClient() // reads ANTHROPIC_API_KEY from env
/// let tools = ToolExecutor(
///     projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
///     autonomyMode: .review
/// )
/// let orchestrator = AgenticOrchestrator(client: api, toolExecutor: tools)
/// let system = BuilderSystemPrompt.make(
///     autonomyMode: .review,
///     projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
/// )
/// let events = await orchestrator.run(system: system, messages: [.user("Build an iOS app shell for a live NRL scoreboard.")])
/// ```
