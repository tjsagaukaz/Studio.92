// ExecutionLoopEngine.swift
// Studio.92 — Command Center
// Protocol for provider-specific agentic execution loops.

import Foundation

/// A provider-specific execution loop that drives an agentic conversation:
/// streams model output, dispatches tool calls, feeds results back, and iterates
/// until the model stops or a limit is reached.
///
/// Implementations own the iteration lifecycle, event streaming, tool dispatch,
/// and result integration. ``AgenticClient/run(…)`` creates the appropriate engine
/// and delegates to ``execute()``.
protocol ExecutionLoopEngine: Sendable {
    /// Run the full agentic loop and return a stream of events for real-time UI updates.
    /// Cancelling the consuming Task tears down the entire loop.
    func execute() -> AsyncStream<AgenticEvent>
}
