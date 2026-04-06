// HandoffTypes.swift
// Studio.92 — Agent Council
// Compile-time safe types for agent-to-agent delegation.
// Replaces string-based context passing with structured state transfers.

import Foundation

// MARK: - Agent Role

/// The persona a subagent adopts during a handoff.
public enum AgentRole: String, Sendable {
    case explorer
    case reviewer
}

// MARK: - Handoff Context

/// Everything a subagent needs to begin work.
/// The caller resolves model selection; the library stays agnostic.
public struct HandoffContext: Sendable {
    public let role: AgentRole
    public let guardrails: SubagentGuardrails
    public let tracer: TraceCollector?
    public let parentSpanID: UUID?
    public let apiKey: String?

    public init(
        role: AgentRole,
        guardrails: SubagentGuardrails,
        tracer: TraceCollector? = nil,
        parentSpanID: UUID? = nil,
        apiKey: String? = nil
    ) {
        self.role = role
        self.guardrails = guardrails
        self.tracer = tracer
        self.parentSpanID = parentSpanID
        self.apiKey = apiKey
    }
}

// MARK: - Handoff Result

/// Structured output from a completed subagent run.
public struct HandoffResult: Sendable {
    /// The subagent's final textual summary.
    public let summary: String
    /// File paths the subagent read during execution.
    public let filesExamined: [String]
    /// File paths the subagent wrote (worktree only; empty for explorers/reviewers).
    public let filesModified: [String]
    /// Trace ID for linking into the span tree.
    public let traceID: UUID?
    /// Number of LLM iterations the subagent consumed.
    public let iterationCount: Int

    public init(
        summary: String,
        filesExamined: [String] = [],
        filesModified: [String] = [],
        traceID: UUID? = nil,
        iterationCount: Int = 0
    ) {
        self.summary = summary
        self.filesExamined = filesExamined
        self.filesModified = filesModified
        self.traceID = traceID
        self.iterationCount = iterationCount
    }
}

// MARK: - Handoff Outcome

/// The three possible outcomes of a handoff.
public enum HandoffOutcome: Sendable {
    /// Subagent completed its task normally.
    case completed(HandoffResult)
    /// Subagent hit its iteration cap or stalled — partial work preserved.
    case escalated(reason: String, partialResult: HandoffResult)
    /// Subagent failed outright.
    case failed(error: String)

    /// Convenience: the result regardless of completion state, if any.
    public var result: HandoffResult? {
        switch self {
        case .completed(let r): return r
        case .escalated(_, let r): return r
        case .failed: return nil
        }
    }

    /// The summary text, suitable for returning as a tool result.
    public var summary: String {
        switch self {
        case .completed(let r):
            return r.summary
        case .escalated(let reason, let r):
            return "\(r.summary)\n\n[Escalated: \(reason)]"
        case .failed(let error):
            return "Handoff failed: \(error)"
        }
    }

    public var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}
