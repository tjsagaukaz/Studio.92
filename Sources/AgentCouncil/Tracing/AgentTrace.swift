// AgentTrace.swift
// Studio.92 — Agent Council
// Framework-agnostic span models for structured agent observability.
// Used by both the CLI and CommandCenter for tracing LLM calls, tool executions,
// subagent delegations, and phase transitions.

import Foundation

// MARK: - Span Kind

/// Discriminates the category of work a span represents.
public enum SpanKind: String, Codable, Sendable {
    case llmCall
    case toolExecution
    case subagent
    case permissionCheck
    case retry
    case compaction
    case architectureViolation
    case session
}

// MARK: - Span Status

/// Terminal status of a completed span.
public enum SpanStatus: Codable, Sendable, Equatable {
    case ok
    case error(String)

    // Custom coding so JSON stays clean: "ok" or {"error": "msg"}
    private enum CodingKeys: String, CodingKey { case ok, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self), str == "ok" {
            self = .ok
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let message = try keyed.decode(String.self, forKey: .error)
        self = .error(message)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ok:
            var container = encoder.singleValueContainer()
            try container.encode("ok")
        case .error(let message):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .error)
        }
    }
}

// MARK: - Span

/// A single unit of traced work within an agent session.
public struct Span: Codable, Sendable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let traceID: UUID
    public let kind: SpanKind
    public let name: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: SpanStatus?
    public var attributes: [String: String]
    /// Raw tool input payload for replay / inspection.
    public var inputPayload: Data?
    /// Raw tool output payload for inspection.
    public var outputPayload: Data?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        traceID: UUID,
        kind: SpanKind,
        name: String,
        startedAt: Date = Date(),
        attributes: [String: String] = [:],
        inputPayload: Data? = nil,
        outputPayload: Data? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.traceID = traceID
        self.kind = kind
        self.name = name
        self.startedAt = startedAt
        self.attributes = attributes
        self.inputPayload = inputPayload
        self.outputPayload = outputPayload
    }

    /// Duration if the span has ended.
    public var duration: TimeInterval? {
        guard let end = endedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }

    /// Mark the span as completed successfully.
    public mutating func finish() {
        endedAt = Date()
        if status == nil { status = .ok }
    }

    /// Mark the span as failed with a message.
    public mutating func fail(_ message: String) {
        endedAt = Date()
        status = .error(message)
    }
}

// MARK: - Trace Collector

/// Thread-safe accumulator for spans within a single agent session.
/// Actors are lightweight — one per session is fine.
public actor TraceCollector {

    public let traceID: UUID
    public let sessionID: UUID?
    private var spans: [UUID: Span] = [:]
    private var completedSpans: [Span] = []
    private var continuations: [UUID: AsyncStream<Span>.Continuation] = [:]
    private static let maxCompletedSpans = 5000

    public init(traceID: UUID = UUID(), sessionID: UUID? = nil) {
        self.traceID = traceID
        self.sessionID = sessionID
    }

    // MARK: - Span Lifecycle

    /// Begin a new span. Returns the span ID for later completion.
    @discardableResult
    public func begin(
        kind: SpanKind,
        name: String,
        parentID: UUID? = nil,
        attributes: [String: String] = [:]
    ) -> UUID {
        let span = Span(
            parentID: parentID,
            traceID: traceID,
            kind: kind,
            name: name,
            attributes: attributes
        )
        spans[span.id] = span
        return span.id
    }

    /// Add an attribute to an in-flight span.
    public func setAttribute(_ key: String, value: String, on spanID: UUID) {
        spans[spanID]?.attributes[key] = value
    }

    /// Attach raw input payload to an in-flight span.
    public func setInputPayload(_ data: Data, on spanID: UUID) {
        spans[spanID]?.inputPayload = data
    }

    /// Attach raw output payload to an in-flight span.
    public func setOutputPayload(_ data: Data, on spanID: UUID) {
        spans[spanID]?.outputPayload = data
    }

    /// End a span successfully.
    public func end(_ spanID: UUID) {
        guard var span = spans.removeValue(forKey: spanID) else { return }
        span.finish()
        appendCompleted(span)
        for continuation in continuations.values {
            continuation.yield(span)
        }
    }

    /// End a span with an error.
    public func end(_ spanID: UUID, error message: String) {
        guard var span = spans.removeValue(forKey: spanID) else { return }
        span.fail(message)
        appendCompleted(span)
        for continuation in continuations.values {
            continuation.yield(span)
        }
    }

    private func appendCompleted(_ span: Span) {
        completedSpans.append(span)
        if completedSpans.count > Self.maxCompletedSpans {
            completedSpans.removeFirst(completedSpans.count - Self.maxCompletedSpans)
        }
    }

    // MARK: - Queries

    /// All completed spans, ordered by start time.
    public func allSpans() -> [Span] {
        completedSpans.sorted { $0.startedAt < $1.startedAt }
    }

    /// Live stream of completed spans.
    public func spanStream() -> AsyncStream<Span> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Span>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        // Replay existing spans.
        for span in completedSpans {
            continuation.yield(span)
        }
        return stream
    }

    /// Finish all active span streams. Call when the session ends.
    public func finishAllStreams() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Number of spans that have started but have not yet ended.
    public func activeSpanCount() -> Int {
        spans.count
    }

    /// Summary stats for the trace.
    public func summary() -> TraceSummary {
        let all = completedSpans
        let llmCalls = all.filter { $0.kind == .llmCall }
        let toolExecs = all.filter { $0.kind == .toolExecution }
        let errors = all.filter { if case .error = $0.status { return true }; return false }
        let totalDuration = all.compactMap(\.duration).reduce(0, +)

        return TraceSummary(
            traceID: traceID,
            spanCount: all.count,
            llmCallCount: llmCalls.count,
            toolExecutionCount: toolExecs.count,
            errorCount: errors.count,
            totalDurationSeconds: totalDuration,
            inputTokens: all.compactMap { Int($0.attributes["inputTokens"] ?? "") }.reduce(0, +),
            outputTokens: all.compactMap { Int($0.attributes["outputTokens"] ?? "") }.reduce(0, +)
        )
    }
}

// MARK: - Trace Summary

/// Aggregate stats for a completed trace.
public struct TraceSummary: Codable, Sendable {
    public let traceID: UUID
    public let spanCount: Int
    public let llmCallCount: Int
    public let toolExecutionCount: Int
    public let errorCount: Int
    public let totalDurationSeconds: TimeInterval
    public let inputTokens: Int
    public let outputTokens: Int
}
