// SessionInspectorModel.swift
// Studio.92 — Command Center
// Observable view model for the Session Inspector.
// Dual-source: live TraceCollector stream for active sessions,
// SwiftData @Query for historical sessions.

import Foundation
import SwiftData
import AgentCouncil

// MARK: - Inspector Source

/// Determines whether the inspector is showing the live session or a historical one.
enum InspectorSource: Equatable {
    /// Real-time stream from the active TraceCollector.
    case live
    /// Historical session identified by trace ID.
    case historical(traceID: UUID)
}

// MARK: - Span Tree Node

/// A span with its resolved children, forming a causal tree.
struct SpanTreeNode: Identifiable {
    let span: InspectorSpan
    var children: [SpanTreeNode]
    var id: UUID { span.id }
}

// MARK: - Inspector Span

/// Unified span representation used by the inspector UI.
/// Bridges both live `Span` objects and persisted `PersistedSpan` records.
struct InspectorSpan: Identifiable, Equatable {
    let id: UUID
    let parentID: UUID?
    let traceID: UUID
    let kind: String
    let name: String
    let startedAt: Date
    let endedAt: Date?
    let statusText: String?
    let isError: Bool
    let attributes: [String: String]
    let inputPayload: Data?
    let outputPayload: Data?

    var durationSeconds: Double? {
        guard let end = endedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }

    /// Time-to-first-meaningful-output in milliseconds (tool spans only).
    var ttfmoMs: Int? {
        guard let raw = attributes["latency.ttfmo_ms"] else { return nil }
        return Int(raw)
    }

    /// Total execution time in milliseconds (tool spans only).
    var totalMs: Int? {
        guard let raw = attributes["latency.total_ms"] else { return nil }
        return Int(raw)
    }

    var ambientContextID: String? {
        guard let raw = attributes["ambient.context_id"], !raw.isEmpty, raw != "none" else { return nil }
        return raw
    }

    var ambientSelectionFreshnessMs: Int? {
        guard let raw = attributes["ambient.selection_freshness_ms"], raw != "none" else { return nil }
        return Int(raw)
    }

    var ambientCurrentFile: String? {
        guard let raw = attributes["ambient.current_file"], !raw.isEmpty else { return nil }
        return raw
    }

    var displayName: String {
        switch name {
        case "claude_stream": return "Claude Stream"
        case "subagent_run": return "Subagent"
        case "subagent_llm_call": return "Subagent LLM"
        case "agentic_loop": return "Agent Session"
        case "context_compaction": return "Context Compaction"
        case "architecture_violation": return "Architecture Violation"
        case "permission_blocked": return "Permission Blocked"
        case "agents_md_model_validation": return "Model Validation"
        case "read_file": return "Read File"
        case "file_read": return "Read File"
        case "create_file", "write_file": return "Write File"
        case "file_write": return "Write File"
        case "apply_patch": return "Patch File"
        case "file_patch": return "Patch File"
        case "list_dir": return "List Files"
        case "list_files": return "List Files"
        case "run_in_terminal": return "Terminal"
        case "terminal": return "Terminal"
        case "fetch_webpage": return "Fetch Page"
        case "web_search": return "Web Search"
        case "delegate_to_explorer": return "Explorer"
        case "delegate_to_reviewer": return "Reviewer"
        case "deploy_to_testflight": return "Deploy"
        default: return name
        }
    }

    var kindLabel: String {
        switch kind {
        case "llmCall": return "LLM"
        case "toolExecution": return "Tool"
        case "subagent": return "Subagent"
        case "permissionCheck": return "Permission"
        case "retry": return "Retry"
        case "compaction": return "Compaction"
        case "architectureViolation": return "Architecture"
        case "session": return "Session"
        default: return kind
        }
    }

    var kindSymbol: String {
        switch kind {
        case "llmCall": return "brain"
        case "toolExecution": return "wrench.and.screwdriver"
        case "subagent": return "person.2"
        case "permissionCheck": return "lock.shield"
        case "retry": return "arrow.counterclockwise"
        case "compaction": return "memorychip"
        case "architectureViolation": return "exclamationmark.octagon"
        case "session": return "play.circle"
        default: return "questionmark.circle"
        }
    }

    /// Pretty-printed input payload string.
    var inputPayloadString: String? {
        guard let data = inputPayload else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: formatted, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Pretty-printed output payload string.
    var outputPayloadString: String? {
        guard let data = outputPayload else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: formatted, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Whether this span can be rerun (failed tool executions only).
    var isRerunnable: Bool {
        isError && kind == "toolExecution" && inputPayload != nil
    }

    static func == (lhs: InspectorSpan, rhs: InspectorSpan) -> Bool {
        lhs.id == rhs.id && lhs.endedAt == rhs.endedAt && lhs.statusText == rhs.statusText
    }

    // MARK: - Factories

    static func from(span: Span) -> InspectorSpan {
        let statusText: String?
        let isError: Bool
        switch span.status {
        case .ok:
            statusText = "ok"
            isError = false
        case .error(let msg):
            statusText = msg
            isError = true
        case nil:
            statusText = nil
            isError = false
        }
        return InspectorSpan(
            id: span.id,
            parentID: span.parentID,
            traceID: span.traceID,
            kind: span.kind.rawValue,
            name: span.name,
            startedAt: span.startedAt,
            endedAt: span.endedAt,
            statusText: statusText,
            isError: isError,
            attributes: span.attributes,
            inputPayload: span.inputPayload,
            outputPayload: span.outputPayload
        )
    }

    static func from(persisted: PersistedSpan) -> InspectorSpan {
        InspectorSpan(
            id: persisted.id,
            parentID: persisted.parentID,
            traceID: persisted.traceID,
            kind: persisted.kind,
            name: persisted.name,
            startedAt: persisted.startedAt,
            endedAt: persisted.endedAt,
            statusText: persisted.statusText,
            isError: persisted.isError,
            attributes: persisted.attributes,
            inputPayload: persisted.inputPayloadJSON,
            outputPayload: persisted.outputPayloadJSON
        )
    }
}

// MARK: - Session Inspector Model

@Observable
final class SessionInspectorModel {

    // MARK: - State

    var source: InspectorSource = .live
    var isVisible: Bool = false
    var expandedSpanIDs: Set<UUID> = []
    var focusedSpanID: UUID?
    private var pendingFocusedSpanID: UUID?

    /// Flat list of spans for the current source — built into a tree by the view.
    private(set) var spans: [InspectorSpan] = []

    /// Summary stats for the current trace.
    private(set) var summary: InspectorSummary?

    // MARK: - Incremental Summary Counters (live path)
    private var _nonSessionCount = 0
    private var _llmCallCount = 0
    private var _toolExecutionCount = 0
    private var _errorCount = 0
    private var _totalDuration: TimeInterval = 0
    private var _inputTokens = 0
    private var _outputTokens = 0

    /// Whether the inspector is currently streaming live data.
    var isLive: Bool { source == .live }

    // MARK: - Live Observation

    private var liveObservationTask: Task<Void, Never>?

    /// Begin streaming spans from a live TraceCollector.
    func observeLive(_ collector: TraceCollector) {
        source = .live
        spans = []
        summary = nil
        resetCounters()
        liveObservationTask?.cancel()
        liveObservationTask = Task { @MainActor [weak self] in
            let stream = await collector.spanStream()
            for await span in stream {
                guard !Task.isCancelled else { break }
                self?.appendLiveSpan(span)
                if self?.spans.count ?? 0 > 5000 {
                    self?.spans.removeFirst()
                }
            }
        }
    }

    /// Stop live observation.
    func stopLive() {
        liveObservationTask?.cancel()
        liveObservationTask = nil
    }

    /// Update summary after live session completes.
    func finalizeLive(summary: TraceSummary) {
        self.summary = InspectorSummary.from(summary, sessionSpan: spans.first(where: { $0.kind == "session" }))
    }

    // MARK: - Historical Loading

    /// Load spans from SwiftData for a completed session.
    func loadHistorical(traceID: UUID, persistedSpans: [PersistedSpan]) {
        source = .historical(traceID: traceID)
        spans = persistedSpans
            .sorted { $0.startedAt < $1.startedAt }
            .map(InspectorSpan.from(persisted:))
        rebuildSummary()
    }

    // MARK: - Expansion

    func toggleExpanded(_ spanID: UUID) {
        if expandedSpanIDs.contains(spanID) {
            expandedSpanIDs.remove(spanID)
        } else {
            expandedSpanIDs.insert(spanID)
        }
    }

    func isExpanded(_ spanID: UUID) -> Bool {
        expandedSpanIDs.contains(spanID)
    }

    func focus(spanID: UUID?) {
        guard let spanID else {
            focusedSpanID = nil
            pendingFocusedSpanID = nil
            return
        }

        guard spans.contains(where: { $0.id == spanID }) else {
            pendingFocusedSpanID = spanID
            focusedSpanID = nil
            return
        }

        pendingFocusedSpanID = nil
        focusedSpanID = spanID
        expandAncestors(of: spanID)
    }

    // MARK: - Tree Building

    /// Build the span causal tree from the flat span list.
    /// Root spans (session-level or parentless) appear at top level.
    var spanTree: [SpanTreeNode] {
        let byParent = Dictionary(grouping: spans, by: { $0.parentID })
        let roots = spans.filter { $0.parentID == nil || $0.kind == "session" }
        return roots.map { buildNode($0, children: byParent) }
    }

    /// Flat list of non-session spans for timeline display, preserving hierarchy via indentation level.
    var timelineNodes: [(span: InspectorSpan, depth: Int)] {
        var result: [(InspectorSpan, Int)] = []
        let byParent = Dictionary(grouping: spans.filter { $0.kind != "session" }, by: { $0.parentID })
        // Find the session span ID if any.
        let sessionSpanID = spans.first(where: { $0.kind == "session" })?.id
        // Root tool spans are those whose parent is the session span or nil.
        let roots = spans.filter { s in
            s.kind != "session" && (s.parentID == nil || s.parentID == sessionSpanID)
        }
        for root in roots {
            flattenNode(root, depth: 0, children: byParent, into: &result)
        }
        return result
    }

    // MARK: - Private

    @MainActor
    private func appendLiveSpan(_ span: Span) {
        let inspectorSpan = InspectorSpan.from(span: span)
        // Skip session-level spans from timeline count but still track them.
        spans.append(inspectorSpan)
        if pendingFocusedSpanID == inspectorSpan.id {
            focus(spanID: inspectorSpan.id)
        }
        if inspectorSpan.kind == "session" {
            summary = summaryFromCounters()
            return
        }
        updateCounters(for: inspectorSpan)
    }

    private func expandAncestors(of spanID: UUID) {
        var currentParentID = spans.first(where: { $0.id == spanID })?.parentID
        while let parentID = currentParentID {
            expandedSpanIDs.insert(parentID)
            currentParentID = spans.first(where: { $0.id == parentID })?.parentID
        }
    }

    private func rebuildSummary() {
        resetCounters()
        for span in spans where span.kind != "session" {
            _nonSessionCount += 1
            if span.kind == "llmCall" { _llmCallCount += 1 }
            if span.kind == "toolExecution" { _toolExecutionCount += 1 }
            if span.isError { _errorCount += 1 }
            _totalDuration += span.durationSeconds ?? 0
            _inputTokens += Int(span.attributes["inputTokens"] ?? "") ?? 0
            _outputTokens += Int(span.attributes["outputTokens"] ?? "") ?? 0
        }
        summary = summaryFromCounters()
    }

    private func resetCounters() {
        _nonSessionCount = 0
        _llmCallCount = 0
        _toolExecutionCount = 0
        _errorCount = 0
        _totalDuration = 0
        _inputTokens = 0
        _outputTokens = 0
    }

    /// Incremental O(1) update for a single span — used by the live path.
    private func updateCounters(for span: InspectorSpan) {
        guard span.kind != "session" else { return }
        _nonSessionCount += 1
        if span.kind == "llmCall" { _llmCallCount += 1 }
        if span.kind == "toolExecution" { _toolExecutionCount += 1 }
        if span.isError { _errorCount += 1 }
        _totalDuration += span.durationSeconds ?? 0
        _inputTokens += Int(span.attributes["inputTokens"] ?? "") ?? 0
        _outputTokens += Int(span.attributes["outputTokens"] ?? "") ?? 0
        summary = summaryFromCounters()
    }

    private func summaryFromCounters() -> InspectorSummary {
        let sessionSpan = spans.first(where: { $0.kind == "session" })
        return InspectorSummary(
            spanCount: _nonSessionCount,
            llmCallCount: _llmCallCount,
            toolExecutionCount: _toolExecutionCount,
            errorCount: _errorCount,
            totalDurationSeconds: _totalDuration,
            inputTokens: _inputTokens,
            outputTokens: _outputTokens,
            ambientContextID: sessionSpan?.ambientContextID,
            ambientSelectionFreshnessMs: sessionSpan?.ambientSelectionFreshnessMs,
            ambientCurrentFile: sessionSpan?.ambientCurrentFile
        )
    }

    private func buildNode(_ span: InspectorSpan, children: [UUID?: [InspectorSpan]]) -> SpanTreeNode {
        let childSpans = children[span.id] ?? []
        return SpanTreeNode(
            span: span,
            children: childSpans.map { buildNode($0, children: children) }
        )
    }

    private func flattenNode(
        _ span: InspectorSpan,
        depth: Int,
        children: [UUID?: [InspectorSpan]],
        into result: inout [(InspectorSpan, Int)]
    ) {
        result.append((span, depth))
        if expandedSpanIDs.contains(span.id) {
            for child in children[span.id] ?? [] {
                flattenNode(child, depth: depth + 1, children: children, into: &result)
            }
        }
    }
}

// MARK: - Inspector Summary

struct InspectorSummary {
    let spanCount: Int
    let llmCallCount: Int
    let toolExecutionCount: Int
    let errorCount: Int
    let totalDurationSeconds: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
    let ambientContextID: String?
    let ambientSelectionFreshnessMs: Int?
    let ambientCurrentFile: String?

    static func from(_ ts: TraceSummary, sessionSpan: InspectorSpan? = nil) -> InspectorSummary {
        InspectorSummary(
            spanCount: ts.spanCount,
            llmCallCount: ts.llmCallCount,
            toolExecutionCount: ts.toolExecutionCount,
            errorCount: ts.errorCount,
            totalDurationSeconds: ts.totalDurationSeconds,
            inputTokens: ts.inputTokens,
            outputTokens: ts.outputTokens,
            ambientContextID: sessionSpan?.ambientContextID,
            ambientSelectionFreshnessMs: sessionSpan?.ambientSelectionFreshnessMs,
            ambientCurrentFile: sessionSpan?.ambientCurrentFile
        )
    }
}
